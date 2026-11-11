// SPDX-License-Identifier: MIT
#import "Protocol.h"
#include "heatshrink_encoder.h"

static void varint(NSMutableData *out, uint64_t value) {
    do { uint8_t b=value&127; value>>=7; b|=value?128:0; [out appendBytes:&b length:1]; } while(value);
}
static void number(NSMutableData *out, unsigned field, uint64_t value) {
    if(value) { varint(out, field<<3); varint(out,value); }
}
static void bytes(NSMutableData *out, unsigned field, NSData *value) {
    varint(out,(field<<3)|2); varint(out,value.length); [out appendData:value];
}
NSData *RWFrame(NSData *body) {
    if(!body.length || body.length>1156) return nil;
    uint8_t lo=body.length&255, hi=body.length>>8, check=0x55^lo^hi;
    uint8_t h[]={0x55,lo,hi|((check&12)<<4),(check>>4)&3};
    const uint8_t *p=body.bytes;
    for(NSUInteger i=0;i<body.length;i++) check^=p[i];
    h[3]|=check&252;
    NSMutableData *out=[NSMutableData dataWithBytes:h length:4]; [out appendData:body]; return out;
}
static BOOL readVar(NSData *data, NSUInteger *pos, uint64_t *value) {
    const uint8_t *p=data.bytes; *value=0;
    for(unsigned shift=0;shift<64 && *pos<data.length;shift+=7) {
        uint8_t b=p[(*pos)++]; if(shift==63 && (b&254)) return NO;
        *value|=(uint64_t)(b&127)<<shift; if(!(b&128)) return YES;
    }
    return NO;
}
NSDictionary *RWFields(NSData *data) {
    if(![data isKindOfClass:NSData.class]) return nil;
    NSMutableDictionary *out=[NSMutableDictionary new]; NSUInteger pos=0;
    while(pos<data.length) {
        uint64_t key,n; if(!readVar(data,&pos,&key) || key<8 || key>>3>0x1fffffff) return nil;
        NSNumber *field=@(key>>3); if(out[field]) return nil;
        switch(key&7) {
        case 0: if(!readVar(data,&pos,&n)) return nil; out[field]=@(n); break;
        case 2:
            if(!readVar(data,&pos,&n) || n>data.length-pos) return nil;
            out[field]=[data subdataWithRange:NSMakeRange(pos,n)]; pos+=n; break;
        default: return nil;
        }
    }
    return out;
}
NSString *RWString(id value) {
    return [value isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] : nil;
}
NSNumber *RWNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }

static NSData *compress(NSData *raw) {
    // Verified in the vendor codec's compiled print_config: window=11, lookahead=4.
    heatshrink_encoder *enc=heatshrink_encoder_alloc(11,4);
    if(!enc) return nil;
    NSMutableData *out=[NSMutableData new]; size_t pos=0; BOOL ok=YES;
    while(1) {
        if(pos<raw.length) {
            size_t n=0;
            if(heatshrink_encoder_sink(enc,(uint8_t *)raw.bytes+pos,raw.length-pos,&n)<0) {ok=NO;break;}
            pos+=n;
        }
        if(pos==raw.length && heatshrink_encoder_finish(enc)==HSER_FINISH_DONE) break;
        HSE_poll_res state;
        do {
            uint8_t buffer[1024]; size_t n=0;
            state=heatshrink_encoder_poll(enc,buffer,sizeof buffer,&n);
            if(state<0) {ok=NO;break;}
            [out appendBytes:buffer length:n];
        } while(state==HSER_POLL_MORE);
        if(!ok) break;
    }
    heatshrink_encoder_free(enc); return ok?out:nil;
}
NSArray<NSArray<NSData *> *> *RWEncode(NSData *pixels, NSUInteger rowBytes) {
    if(rowBytes<40 || rowBytes>104 || !pixels.length || pixels.length%rowBytes || pixels.length>104*1600) return nil;
    // Align sections to eight complete rows; this matches the verified device protocol.
    NSUInteger sectionBytes=8192-(8192%(rowBytes*8));
    NSUInteger count=(pixels.length+sectionBytes-1)/sectionBytes;
    NSMutableArray *sections=[NSMutableArray new];
    for(NSUInteger section=0;section<count;section++) {
        NSUInteger start=section*sectionBytes;
        NSData *packed=compress([pixels subdataWithRange:NSMakeRange(start,MIN(sectionBytes,pixels.length-start))]);
        if(!packed.length) return nil;
        NSUInteger chunks=(packed.length+399)/400;
        NSMutableArray *packets=[NSMutableArray new];
        for(NSUInteger index=0;index<chunks;index++) {
            NSData *chunk=[packed subdataWithRange:NSMakeRange(index*400,MIN(400,packed.length-index*400))];
            NSMutableData *print=[NSMutableData new];
            number(print,1,1); bytes(print,2,chunk); number(print,3,pixels.length*2); // sint32 zigzag
            number(print,4,chunks); number(print,5,index+1); number(print,6,index?0:rowBytes); // mm at 8 dots/mm
            number(print,7,count); number(print,8,1); number(print,10,packed.length*2); number(print,12,section+1);
            NSMutableData *message=[NSMutableData new]; number(message,1,4); bytes(message,5,print);
            NSData *frame=RWFrame(message); if(!frame) return nil; [packets addObject:frame];
        }
        [sections addObject:packets];
    }
    return sections;
}
