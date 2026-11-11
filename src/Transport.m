// SPDX-License-Identifier: MIT
#import "Transport.h"
#import "Protocol.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#include <cups/backend.h>
#include <signal.h>
#include <stdatomic.h>
static atomic_bool cancellation=false;
void RWCancelTransmission(void) {atomic_store(&cancellation,true);}
void RWResetCancellation(void) {atomic_store(&cancellation,false);}

@interface RWTransport : NSObject <CBCentralManagerDelegate,CBPeripheralDelegate>
@property CBCentralManager *central;
@property CBPeripheral *printer;
@property CBCharacteristic *command,*notify,*bulk;
@property NSString *uuid,*mac;
@property NSArray<NSDictionary *> *pages;
@property NSMutableData *rx;
@property NSUInteger page,section,packet;
@property BOOL queryOnly,started,waitingAck,waitingCompletion,scheduled,possiblePrint,closing,done;
@property BOOL endPending,endAcknowledged;
@property int result;
@property double deadline,lastWrite;
@property dispatch_source_t timer;
@end
@implementation RWTransport
- (void)finish:(int)result message:(NSString *)message {
    if(self.closing) return;
    self.closing=YES; self.result=result;
    fprintf(stderr,"%s: %s%s\n",result?"ERROR":"INFO",message.UTF8String,
            result && self.possiblePrint ? "; physical outcome may be partial or unknown. No automatic retry." : "");
    [self.central stopScan];
    if(self.printer && self.printer.state!=CBPeripheralStateDisconnected) {
        [self.central cancelPeripheralConnection:self.printer];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{self.done=YES;});
    } else self.done=YES;
}
- (void)fail:(NSString *)message { [self finish:CUPS_BACKEND_HOLD message:message]; }
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if(self.closing) return;
    if(central.state==CBManagerStatePoweredOn) {
        [central scanForPeripheralsWithServices:nil options:nil]; self.deadline=NSProcessInfo.processInfo.systemUptime+20;
        fprintf(stderr,"INFO: Looking for the selected RW403B over Bluetooth LE\n");
    } else if(central.state==CBManagerStateUnauthorized) [self fail:@"Bluetooth permission is denied for this process"];
    else if(central.state==CBManagerStateUnsupported || central.state==CBManagerStatePoweredOff) [self fail:@"Bluetooth is unavailable or turned off"];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary *)data RSSI:(NSNumber *)rssi {
    (void)data; (void)rssi;
    if(self.closing || self.printer || [p.identifier.UUIDString caseInsensitiveCompare:self.uuid]!=NSOrderedSame) return;
    self.printer=p; p.delegate=self; [central stopScan]; [central connectPeripheral:p options:nil];
    self.deadline=NSProcessInfo.processInfo.systemUptime+20;
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)p {
    if(self.closing) return;
    [p discoverServices:@[[CBUUID UUIDWithString:@"ABF0"]]];
    self.deadline=NSProcessInfo.processInfo.systemUptime+15;
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)error {
    [self fail:[NSString stringWithFormat:@"Bluetooth connection failed: %@",error.localizedDescription]];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)error {
    if(self.closing) return;
    if(error || p.services.count!=1) {[self fail:@"Verified ABF0 printer service is unavailable"];return;}
    [p discoverCharacteristics:@[[CBUUID UUIDWithString:@"ABF1"],[CBUUID UUIDWithString:@"ABF3"],[CBUUID UUIDWithString:@"ABF4"]] forService:p.services.firstObject];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(NSError *)error {
    if(self.closing) return;
    if(error) {[self fail:@"Bluetooth characteristic discovery failed"];return;}
    for(CBCharacteristic *c in s.characteristics) {
        if([c.UUID isEqual:[CBUUID UUIDWithString:@"ABF1"]]) self.command=c;
        if([c.UUID isEqual:[CBUUID UUIDWithString:@"ABF3"]]) self.notify=c;
        if([c.UUID isEqual:[CBUUID UUIDWithString:@"ABF4"]]) self.bulk=c;
    }
    if(!(self.command.properties&CBCharacteristicPropertyWrite) || !(self.notify.properties&CBCharacteristicPropertyNotify) || !(self.bulk.properties&CBCharacteristicPropertyWriteWithoutResponse)) {
        [self fail:@"Printer characteristics do not match the verified protocol"];return;
    }
    NSUInteger capacity=[p maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    for(NSDictionary *page in self.pages) for(NSArray *section in page[@"sections"]) for(NSData *packet in section)
        if(packet.length>capacity) {[self fail:@"Bluetooth packet capacity is too small for this protocol"];return;}
    [p setNotifyValue:YES forCharacteristic:self.notify];
}
- (void)peripheral:(CBPeripheral *)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    if(self.closing) return;
    if(error || !c.isNotifying) {[self fail:@"Cannot enable printer responses"];return;}
    const uint8_t query[]={0x08,0x01};
    [p writeValue:RWFrame([NSData dataWithBytes:query length:2]) forCharacteristic:self.command type:CBCharacteristicWriteWithResponse];
    self.deadline=NSProcessInfo.processInfo.systemUptime+10;
}
- (void)peripheral:(CBPeripheral *)p didWriteValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    if(error) {[self fail:@"Printer command write failed"];return;}
    if(self.endPending) {
        self.endPending=NO;self.endAcknowledged=YES;
        if(self.page==self.pages.count) [self finish:0 message:@"All labels acknowledged and reported complete by the printer"];
    }
}
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    if(self.closing) return;
    if(error || ![c.UUID isEqual:self.notify.UUID]) {[self fail:@"Invalid printer notification"];return;}
    [self.rx appendData:c.value];
    if(self.rx.length>8192) {[self fail:@"Printer response exceeds limit"];return;}
    while(self.rx.length>=4 && !self.closing) {
        const uint8_t *b=self.rx.bytes;
        NSUInteger n=b[1]+((b[2]&63)<<8); uint8_t check=0x55^b[1]^(b[2]&63);
        if(b[0]!=0x55 || !n || n>1156 || ((((b[3]&3)<<4)|((b[2]&192)>>4))!=(check&60))) {[self fail:@"Invalid printer response header"];return;}
        if(self.rx.length<n+4) break;
        for(NSUInteger i=4;i<n+4;i++) check^=b[i];
        if((check&252)!=(b[3]&252)) {[self fail:@"Invalid printer response checksum"];return;}
        NSDictionary *message=RWFields([self.rx subdataWithRange:NSMakeRange(4,n)]);
        [self.rx replaceBytesInRange:NSMakeRange(0,n+4) withBytes:NULL length:0];
        if(!message) {[self fail:@"Invalid printer response fields"];return;}
        [self response:message];
    }
}
- (void)response:(NSDictionary *)message {
    unsigned event=[RWNumber(message[@1]) unsignedIntValue],code=[RWNumber(message[@2]) unsignedIntValue];
    NSDictionary *detail=RWFields(message[@3]);
    if(event==1 && !self.started) {
        NSString *status=RWString(detail[@9]),*mac=RWString(detail[@1]);
        if(code!=200 || !mac || [mac caseInsensitiveCompare:self.mac]!=NSOrderedSame) {[self fail:@"Printer identity query did not match the configured MAC address"];return;}
        fprintf(stderr,"INFO: Verified RW403B response; firmware=%s status=%s\n",RWString(detail[@3]).UTF8String,status.UTF8String);
        if(![status isEqualToString:@"0"]) {[self fail:@"Printer is not idle; check paper, cover, and printer status"];return;}
        self.started=YES;
        if(self.queryOnly) {[self finish:0 message:@"Read-only Bluetooth probe succeeded"];return;}
        [self schedule];
    } else if(event==4 && code!=200) [self fail:[NSString stringWithFormat:@"Printer rejected raster data (code %u)",code]];
    else if(event==6) {
        unsigned kind=[RWNumber(detail[@1]) unsignedIntValue]; NSString *info=RWString(detail[@2]);
        if(kind==10 && info && ![info isEqualToString:@"0"]) {[self fail:[NSString stringWithFormat:@"Printer reported error/status bits %@",info]];return;}
        if(kind==13 && [info isEqualToString:@"1"]) {[self fail:@"Printer reported that printing stopped"];return;}
        if(kind==11 && [info isEqualToString:@"2"] && self.waitingAck) {
            self.waitingAck=NO; self.section++; self.packet=0;
            NSArray *sections=self.pages[self.page][@"sections"];
            fprintf(stderr,"INFO: Label %lu: section %lu/%lu accepted\n",self.page+1,self.section,sections.count);
            if(self.section==sections.count) {
                self.waitingCompletion=YES;self.deadline=NSProcessInfo.processInfo.systemUptime+30;
                if(self.page+1==self.pages.count) {
                    const uint8_t end[]={8,10};self.endPending=YES;
                    [self.printer writeValue:RWFrame([NSData dataWithBytes:end length:2]) forCharacteristic:self.command type:CBCharacteristicWriteWithResponse];
                }
            }
            else [self schedule];
        }
        if(kind==10 && [info isEqualToString:@"0"] && self.waitingCompletion) {
            fprintf(stderr,"INFO: Printer reported completion for label %lu\n",self.page+1);
            fprintf(stderr,"PAGE: %lu 1\n",self.page+1);
            self.waitingCompletion=NO; self.page++; self.section=0; self.packet=0;
            if(self.page==self.pages.count) {
                if(self.endAcknowledged) [self finish:0 message:@"All labels acknowledged and reported complete by the printer"];
            }
            else {self.lastWrite=NSProcessInfo.processInfo.systemUptime+0.5;[self schedule];}
        }
    }
}
- (void)schedule {
    if(self.closing || self.scheduled || self.waitingAck || self.waitingCompletion || !self.started || self.page>=self.pages.count) return;
    self.scheduled=YES;
    double delay=MAX(0.010,self.lastWrite+0.010-NSProcessInfo.processInfo.systemUptime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{self.scheduled=NO;[self pump];});
}
- (void)pump {
    if(self.closing || self.waitingAck || self.waitingCompletion || self.page>=self.pages.count || !self.printer.canSendWriteWithoutResponse) return;
    NSArray *packets=self.pages[self.page][@"sections"][self.section]; NSData *data=packets[self.packet];
    self.packet++; self.waitingAck=self.packet==packets.count;
    self.possiblePrint=YES; self.lastWrite=NSProcessInfo.processInfo.systemUptime; self.deadline=self.lastWrite+15;
    [self.printer writeValue:data forCharacteristic:self.bulk type:CBCharacteristicWriteWithoutResponse];
    if(!self.waitingAck) [self schedule];
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)p { [self schedule]; }
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)error {
    if(self.closing) self.done=YES;
    else [self fail:@"Bluetooth disconnected before printer completion"];
}
@end

int RWTransmit(NSString *uuid,NSString *mac,NSArray<NSDictionary *> *pages,BOOL queryOnly) {
    if(atomic_load(&cancellation)) return CUPS_BACKEND_CANCEL;
    // This dual-mode device can stop advertising BLE while a classic link remains open.
    // Release only the explicitly selected printer; never toggle global Bluetooth.
    IOBluetoothDevice *classic=[IOBluetoothDevice deviceWithAddressString:mac];
    if(classic.isConnected) {
        IOReturn status=[classic closeConnection];
        if(status) {fprintf(stderr,"ERROR: Cannot release existing printer Bluetooth link (0x%08x)\n",status);return CUPS_BACKEND_HOLD;}
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    }
    RWTransport *t=[RWTransport new]; t.uuid=uuid; t.mac=mac; t.pages=pages; t.queryOnly=queryOnly; t.rx=[NSMutableData new];
    double start=NSProcessInfo.processInfo.systemUptime; t.deadline=start+20;
    t.central=[[CBCentralManager alloc] initWithDelegate:t queue:dispatch_get_main_queue()];
    t.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(t.timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,100*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t.timer,^{
        double now=NSProcessInfo.processInfo.systemUptime;
        if(atomic_load(&cancellation)) [t finish:CUPS_BACKEND_CANCEL message:@"Job canceled; already transmitted data may still print"];
        if(!t.closing && (now>t.deadline || now>start+600)) [t fail:@"Bluetooth connection, transfer, or printer response timed out"];
    }); dispatch_resume(t.timer);
    while(!t.done) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    dispatch_source_cancel(t.timer); t.central.delegate=nil; t.printer.delegate=nil;
    return t.result;
}
