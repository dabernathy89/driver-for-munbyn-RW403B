// SPDX-License-Identifier: MIT
#import "Raster.h"
#import "Protocol.h"
#include <cups/raster.h>
#include <poll.h>
#include <unistd.h>

typedef struct {const uint8_t *data; size_t size,offset;} Reader;
static ssize_t readMemory(void *context, unsigned char *buffer, size_t length) {
    Reader *r=context; size_t n=MIN(length,r->size-r->offset);
    memcpy(buffer,r->data+r->offset,n); r->offset+=n; return n;
}
NSArray<NSDictionary *> *RWReadRaster(int fd,unsigned copies,NSString **error) {
    if(!copies || copies>20) {*error=@"Copies must be between 1 and 20";return nil;}
    // Validate the complete job before opening Bluetooth; bound memory and input wait.
    NSMutableData *input=[NSMutableData new]; uint8_t buffer[32768];
    double deadline=NSProcessInfo.processInfo.systemUptime+90;
    for(;;) {
        double remaining=deadline-NSProcessInfo.processInfo.systemUptime;
        struct pollfd p={fd,POLLIN,0};
        if(remaining<=0 || poll(&p,1,(int)(remaining*1000))<=0) {*error=@"Raster input timed out";return nil;}
        ssize_t n=read(fd,buffer,sizeof buffer);
        if(n<0) {*error=@"Cannot read raster input";return nil;}
        if(!n) break;
        [input appendBytes:buffer length:n];
        if(input.length>32*1024*1024) {*error=@"Raster job exceeds 32 MiB";return nil;}
    }
    return RWReadRasterData(input,copies,error);
}
NSArray<NSDictionary *> *RWReadRasterData(NSData *input,unsigned copies,NSString **error) {
    if(!copies || copies>20 || input.length>32*1024*1024) {*error=@"Raster size or copy count exceeds limit";return nil;}
    if(input.length<4 || (memcmp(input.bytes,"RaS3",4) && memcmp(input.bytes,"3SaR",4))) {
        *error=@"Expected uncompressed CUPS raster v3 from the macOS raster filter";return nil;
    }
    size_t expectedLength=4;
    Reader reader={input.bytes,input.length,0};
    cups_raster_t *ras=cupsRasterOpenIO(readMemory,&reader,CUPS_RASTER_READ);
    if(!ras) {*error=@"Invalid CUPS raster stream";return nil;}
    NSMutableArray *pages=[NSMutableArray new]; cups_page_header2_t h;
    while(cupsRasterReadHeader2(ras,&h)) {
        NSUInteger w=h.cupsWidth,height=h.cupsHeight,bits=h.cupsBitsPerPixel;
        // PPD custom range: 40-104 mm across the head, 25.4-200 mm feed length.
        // Allow the rounding used by macOS's 203 dpi rasterizer at each edge.
        BOOL paper=(w>=319 && w<=832 && height>=202 && height<=1600);
        if(!paper || h.HWResolution[0]!=203 || h.HWResolution[1]!=203 ||
           h.cupsColorOrder!=CUPS_ORDER_CHUNKED || h.cupsNumColors!=1 ||
           !(h.cupsColorSpace==CUPS_CSPACE_K || h.cupsColorSpace==CUPS_CSPACE_W || h.cupsColorSpace==CUPS_CSPACE_SW) ||
           (bits!=1 && bits!=8) || h.cupsBitsPerColor!=bits || h.cupsBytesPerLine!=(w*bits+7)/8 || h.NumCopies>20) {
            *error=[NSString stringWithFormat:@"Unsupported raster: %lux%lu, %u dpi, %lu bits, color space %u; use 40-104 mm width and 25.4-200 mm feed length at 203 dpi",(unsigned long)w,(unsigned long)height,h.HWResolution[0],(unsigned long)bits,h.cupsColorSpace];break;
        }
        NSUInteger stride=(w+7)/8;
        NSMutableData *pixels=[NSMutableData dataWithLength:stride*height];
        NSMutableData *row=[NSMutableData dataWithLength:h.cupsBytesPerLine];
        uint8_t *out=pixels.mutableBytes; const uint8_t *in=row.bytes;
        for(NSUInteger y=0;y<height;y++) {
            if(cupsRasterReadPixels(ras,row.mutableBytes,h.cupsBytesPerLine)!=h.cupsBytesPerLine) {*error=@"Truncated raster pixels";break;}
            for(NSUInteger x=0;x<w;x++) {
                unsigned value=bits==1?((in[x/8]>>(7-x%8))&1)*255:in[x];
                BOOL black=h.cupsColorSpace==CUPS_CSPACE_K ? value>=128 : value<128;
                if(black) out[y*stride+x/8]|=128>>(x%8);
            }
        }
        if(*error) break;
        expectedLength+=sizeof(cups_page_header2_t)+(size_t)h.cupsBytesPerLine*h.cupsHeight;
        // The printer gap-feeds after the bitmap. Do not physically advance through
        // trailing white rows as well: a full stock-height image can cross the gap
        // and cause an extra blank label. Keep the top origin and all ink unchanged.
        NSUInteger renderedHeight=height;
        while(renderedHeight>1) {
            BOOL white=YES;
            for(NSUInteger x=0;x<stride;x++) if(out[(renderedHeight-1)*stride+x]) {white=NO;break;}
            if(!white) break;
            renderedHeight--;
        }
        [pixels setLength:stride*renderedHeight];
        fprintf(stderr,"INFO: Raster %lux%lu; sending %lu rows after removing trailing white rows\n",(unsigned long)w,(unsigned long)height,(unsigned long)renderedHeight);
        NSArray *sections=RWEncode(pixels,stride);
        if(!sections) {*error=@"Raster compression failed";break;}
        unsigned pageCopies=copies>1?1:MAX(1,h.NumCopies);
        NSDictionary *page=@{@"pixels":pixels,@"rowBytes":@(stride),@"height":@(renderedHeight),@"sections":sections};
        for(unsigned i=0;i<pageCopies;i++) [pages addObject:page];
        if(pages.count*copies>100) {*error=@"Job exceeds 100 labels";break;}
    }
    const char *rasterError=cupsRasterErrorString();
    if(!*error && rasterError && *rasterError) *error=[NSString stringWithFormat:@"Raster decoder: %s",rasterError];
    cupsRasterClose(ras);
    if(!*error && expectedLength!=input.length) *error=@"Truncated header or trailing data in raster stream";
    if(!*error && !pages.count) *error=@"Empty raster job";
    if(*error) return nil;
    NSArray *original=[pages copy];
    for(unsigned i=1;i<copies;i++) [pages addObjectsFromArray:original];
    fprintf(stderr,"INFO: Validated %lu label(s) before Bluetooth connection\n",(unsigned long)pages.count);
    return pages;
}
