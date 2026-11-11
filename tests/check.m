// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import "Protocol.h"
#import "Raster.h"
#include "heatshrink_decoder.h"
#include <cups/raster.h>
#include <fcntl.h>
#include <unistd.h>

#define REQUIRE(x) do {if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static NSData *unframe(NSData *frame) {
    const uint8_t *p=frame.bytes; REQUIRE(frame.length>=5 && p[0]==0x55);
    REQUIRE((NSUInteger)(p[1]+((p[2]&63)<<8))==frame.length-4);
    NSData *body=[frame subdataWithRange:NSMakeRange(4,frame.length-4)]; REQUIRE([RWFrame(body) isEqual:frame]);return body;
}
static NSData *decode(NSData *data) {
    heatshrink_decoder *d=heatshrink_decoder_alloc(256,11,4); REQUIRE(d);
    size_t pos=0; NSMutableData *result=[NSMutableData new];
    while(1) {
        if(pos<data.length) {size_t n=0; REQUIRE(heatshrink_decoder_sink(d,(uint8_t *)data.bytes+pos,data.length-pos,&n)>=0);pos+=n;}
        HSD_poll_res state;
        do {uint8_t bytes[1024];size_t n=0;state=heatshrink_decoder_poll(d,bytes,sizeof bytes,&n);REQUIRE(state>=0);[result appendBytes:bytes length:n];}while(state==HSDR_POLL_MORE);
        if(pos==data.length && heatshrink_decoder_finish(d)==HSDR_FINISH_DONE) break;
    }
    heatshrink_decoder_free(d);return result;
}
static void checkWire(NSData *pixels,NSUInteger stride) {
    NSArray *sections=RWEncode(pixels,stride);REQUIRE(sections.count);
    NSMutableData *recovered=[NSMutableData new]; NSUInteger sectionIndex=0;
    for(NSArray *packets in sections) {
        sectionIndex++; NSMutableData *compressed=[NSMutableData new];NSUInteger packetIndex=0,sectionSize=0;
        for(NSData *packet in packets) {
            packetIndex++; REQUIRE(packet.length<=509);
            NSDictionary *event=RWFields(unframe(packet));REQUIRE([event[@1] intValue]==4);
            NSDictionary *fields=RWFields(event[@5]);
            REQUIRE([fields[@1] intValue]==1 && [fields[@3] unsignedLongValue]==pixels.length*2);
            REQUIRE([fields[@4] unsignedLongValue]==packets.count && [fields[@5] unsignedLongValue]==packetIndex);
            REQUIRE([fields[@6] unsignedLongValue]==(packetIndex==1?stride:0));
            REQUIRE([fields[@7] unsignedLongValue]==sections.count && [fields[@8] intValue]==1);
            REQUIRE([fields[@12] unsignedLongValue]==sectionIndex);
            sectionSize=[fields[@10] unsignedLongValue]/2; [compressed appendData:fields[@2]];
        }
        REQUIRE(compressed.length==sectionSize);[recovered appendData:decode(compressed)];
    }
    REQUIRE([recovered isEqual:pixels]);
}
static NSString *fixture(NSString *dir,NSString *name,BOOL blackSpace,unsigned bits,unsigned pages,unsigned copies,unsigned width) {
    NSString *path=[dir stringByAppendingPathComponent:name];int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC,0600);REQUIRE(fd>=0);
    cups_raster_t *r=cupsRasterOpen(fd,CUPS_RASTER_WRITE);REQUIRE(r);
    cups_page_header2_t h={0};h.HWResolution[0]=h.HWResolution[1]=203;h.cupsWidth=width;h.cupsHeight=1218;
    h.cupsBitsPerPixel=h.cupsBitsPerColor=bits;h.cupsNumColors=1;h.cupsColorOrder=CUPS_ORDER_CHUNKED;
    h.cupsColorSpace=blackSpace?CUPS_CSPACE_K:CUPS_CSPACE_SW;h.cupsBytesPerLine=(width*bits+7)/8;h.NumCopies=copies;
    for(unsigned page=0;page<pages;page++) {
        REQUIRE(cupsRasterWriteHeader2(r,&h));NSMutableData *row=[NSMutableData dataWithLength:h.cupsBytesPerLine];uint8_t *p=row.mutableBytes;
        for(unsigned y=0;y<h.cupsHeight;y++) {
            memset(p,blackSpace?0:255,row.length);
            for(unsigned x=0;x<width;x++) {
                BOOL black=(x>=31 && x<200 && y>=23 && y<87);unsigned value=blackSpace?black:!black;
                if(bits==8) p[x]=value*255;
                else if(value) p[x/8]|=128>>(x%8);else p[x/8]&=~(128>>(x%8));
            }
            REQUIRE(cupsRasterWritePixels(r,p,h.cupsBytesPerLine)==h.cupsBytesPerLine);
        }
    }
    cupsRasterClose(r);close(fd);return path;
}
static NSArray *readRaster(NSString *path,unsigned copies) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY);REQUIRE(fd>=0);NSString *error=nil;
    NSArray *pages=RWReadRaster(fd,copies,&error);close(fd);return pages;
}
int main(int argc,char **argv) {@autoreleasepool {
    REQUIRE(argc==2);NSString *dir=@(argv[1]);
    REQUIRE([NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    const uint8_t query[]={8,1},expected[]={0x55,2,0x40,0x5d,8,1};
    REQUIRE([RWFrame([NSData dataWithBytes:query length:2]) isEqual:[NSData dataWithBytes:expected length:6]]);
    const uint8_t bad[]={0x0a,0xff,0xff,0xff};REQUIRE(!RWFields([NSData dataWithBytes:bad length:4]));
    NSString *one=fixture(dir,@"gray.ras",NO,8,1,1,812);
    NSArray *gray=readRaster(one,1);REQUIRE(gray.count==1);
    REQUIRE([gray[0][@"height"] unsignedLongValue]==87); // Last ink row, not physical stock height.
    REQUIRE([gray[0][@"pixels"] length]==102*87);
    NSArray *black=readRaster(fixture(dir,@"black.ras",YES,1,1,1,812),1);REQUIRE(black.count==1);
    REQUIRE([gray[0][@"pixels"] isEqual:black[0][@"pixels"]]);
    const uint8_t *p=[gray[0][@"pixels"] bytes];REQUIRE(p[23*102+3]==1 && p[23*102+4]==255 && p[23*102+25]==0);
    REQUIRE(readRaster(one,2).count==2);
    REQUIRE(readRaster(fixture(dir,@"copies.ras",NO,8,2,2,812),1).count==4);
    REQUIRE(readRaster(fixture(dir,@"copies.ras",NO,8,2,2,812),2).count==4);
    REQUIRE(!readRaster(fixture(dir,@"wrong-paper.ras",NO,8,1,1,100),1));
    NSData *valid=[NSData dataWithContentsOfFile:one];NSString *truncated=[dir stringByAppendingPathComponent:@"truncated.ras"];
    REQUIRE([[valid subdataWithRange:NSMakeRange(0,valid.length-100)] writeToFile:truncated atomically:YES]);REQUIRE(!readRaster(truncated,1));
    NSMutableData *trailing=[valid mutableCopy];[trailing appendBytes:"abc" length:3];
    REQUIRE([trailing writeToFile:truncated atomically:YES]);REQUIRE(!readRaster(truncated,1));
    checkWire(gray[0][@"pixels"],102);
    NSMutableData *random=[NSMutableData dataWithLength:102*1218];uint8_t *r=random.mutableBytes;uint32_t seed=7;
    for(NSUInteger i=0;i<random.length;i++) {seed=seed*1664525+1013904223;r[i]=seed>>24;}
    checkWire(random,102);
    puts("PASS: framing, compression roundtrip, packet metadata, pixel polarity, copies, media and truncation checks");return 0;
}}
