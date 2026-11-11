// SPDX-License-Identifier: MIT
#import <AppKit/AppKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "IPC.h"
#import "Raster.h"
#import "Transport.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <poll.h>
#include <unistd.h>
#include <stdatomic.h>
#include <cups/backend.h>

static BOOL receiveBytes(int fd,void *bytes,size_t length) {
    size_t pos=0;double deadline=NSProcessInfo.processInfo.systemUptime+90;
    while(pos<length && NSProcessInfo.processInfo.systemUptime<deadline) {
        struct pollfd p={fd,POLLIN,0};int state=poll(&p,1,250);if(state<=0) continue;
        ssize_t n=read(fd,(uint8_t *)bytes+pos,length-pos);if(n<=0) return NO;pos+=n;
    }
    return pos==length;
}
@interface RWApp : NSObject <NSApplicationDelegate,CBCentralManagerDelegate>
@property CBCentralManager *permissionManager;
@property NSString *socketPath;
@property int listener;
@property BOOL printing;
@end
@implementation RWApp
- (void)recordStatus:(NSString *)text {
    fprintf(stderr,"%s %s\n",NSDate.date.description.UTF8String,text.UTF8String);fflush(stderr);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.listener=-1;
    [self recordStatus:@"Starting"];
    self.socketPath=@RW_SOCKET_PATH;
    NSString *directory=self.socketPath.stringByDeletingLastPathComponent;
    struct stat st;
    if(getuid()!=RW_USER_ID || (lstat(directory.fileSystemRepresentation,&st) && mkdir(directory.fileSystemRepresentation,0700))) {
        [self recordStatus:@"Cannot create private print socket"];return;
    }
    if(lstat(directory.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&077)) {[self recordStatus:@"Print socket directory permissions are invalid"];return;}
    struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    if(strlen(self.socketPath.fileSystemRepresentation)>=sizeof address.sun_path) {[self recordStatus:@"Print socket path is too long"];return;}
    strlcpy(address.sun_path,self.socketPath.fileSystemRepresentation,sizeof address.sun_path);
    // Do not replace a live owner. A stale socket from a stopped app is safe to remove.
    int probe=socket(AF_UNIX,SOCK_STREAM,0);
    if(connect(probe,(struct sockaddr *)&address,sizeof address)==0) {close(probe);[NSApp terminate:nil];return;}close(probe);
    if(lstat(address.sun_path,&st)==0 && (!S_ISSOCK(st.st_mode) || st.st_uid!=getuid())) {[self recordStatus:@"Unexpected file at print socket path"];return;}
    unlink(address.sun_path);self.listener=socket(AF_UNIX,SOCK_STREAM,0);umask(0077);
    if(self.listener<0 || bind(self.listener,(struct sockaddr *)&address,sizeof address) || listen(self.listener,4)) {[self recordStatus:@"Cannot listen for print jobs"];return;}
    chmod(address.sun_path,0600);
    self.permissionManager=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    [self recordStatus:@"Waiting for Bluetooth permission"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[self acceptJobs];});
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if(self.printing) return;
    if(central.state==CBManagerStatePoweredOn) [self recordStatus:@"Ready"];
    else if(central.state==CBManagerStateUnauthorized) [self recordStatus:@"Bluetooth permission required"];
    else if(central.state==CBManagerStatePoweredOff) [self recordStatus:@"Bluetooth is turned off"];
}
- (void)acceptJobs {
    for(;;) {@autoreleasepool {
        int fd=accept(self.listener,NULL,NULL);if(fd<0) return;
        int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes);
        uid_t uid;gid_t gid;
        if(getpeereid(fd,&uid,&gid) || (uid!=0 && uid!=getuid())) {close(fd);continue;}
        uint32_t header[3];
        if(!receiveBytes(fd,header,sizeof header)) {close(fd);continue;}
        unsigned magic=ntohl(header[0]),length=ntohl(header[1]),copies=ntohl(header[2]);
        if(magic!=0x52574231 || length<4 || length>RW_MAX_BYTES || copies<1 || copies>20) {
            uint32_t result=htonl(CUPS_BACKEND_CANCEL);write(fd,&result,sizeof result);close(fd);continue;
        }
        NSMutableData *data=[NSMutableData dataWithLength:length];
        if(!receiveBytes(fd,data.mutableBytes,length)) {close(fd);continue;}
        RWResetCancellation();
        atomic_bool *finished=malloc(sizeof *finished);atomic_init(finished,false);
        dispatch_group_t monitor=dispatch_group_create();
        dispatch_group_async(monitor,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            while(!atomic_load(finished)) {
                struct pollfd p={fd,POLLIN,0};if(poll(&p,1,100)<=0) continue;
                char cancel;ssize_t n=recv(fd,&cancel,1,MSG_DONTWAIT);
                if(n==0 || (n>0 && cancel=='C')) {RWCancelTransmission();break;}
            }
        });
        // Keep the main dispatch queue free for CoreBluetooth callbacks and timers.
        // The serialized worker waits for completion; it must not run RWTransmit
        // inside a main-queue block and then try to reenter that same queue.
        dispatch_sync(dispatch_get_main_queue(),^{self.printing=YES;[self recordStatus:@"Validating print job"];});
        NSString *error=nil;NSArray *pages=RWReadRasterData(data,copies,&error);
        int result=CUPS_BACKEND_CANCEL;
        if(!pages) dispatch_sync(dispatch_get_main_queue(),^{[self recordStatus:[@"Rejected: " stringByAppendingString:error?:@"invalid raster"]];});
        else {
            dispatch_sync(dispatch_get_main_queue(),^{[self recordStatus:@"Printing"];});
            result=RWTransmit(@RW_UUID,@RW_MAC,pages,NO);
            dispatch_sync(dispatch_get_main_queue(),^{[self recordStatus:result==0?@"Ready - last job completed":(result==CUPS_BACKEND_CANCEL?@"Canceled - check physical output":@"Job failed - check printer and log")];});
        }
        dispatch_sync(dispatch_get_main_queue(),^{self.printing=NO;});
        atomic_store(finished,true);dispatch_group_wait(monitor,DISPATCH_TIME_FOREVER);free(finished);
        uint32_t reply=htonl(result);write(fd,&reply,sizeof reply);close(fd);
    }}
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    RWCancelTransmission();
    if(self.listener>=0) {close(self.listener);unlink(self.socketPath.fileSystemRepresentation);}
}
@end
int main(void) {@autoreleasepool {
    NSString *logDir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/RW403B"];
    [NSFileManager.defaultManager createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *log=[logDir stringByAppendingPathComponent:@"bridge.log"];
    // Bound retained diagnostics to roughly 1 MiB plus one session's output.
    if([[NSFileManager.defaultManager attributesOfItemAtPath:log error:nil][NSFileSize] unsignedLongLongValue]>1024*1024) {
        [NSFileManager.defaultManager removeItemAtPath:[log stringByAppendingString:@".previous"] error:nil];
        [NSFileManager.defaultManager moveItemAtPath:log toPath:[log stringByAppendingString:@".previous"] error:nil];
    }
    umask(0077);freopen(log.fileSystemRepresentation,"a",stderr);
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    RWApp *delegate=[RWApp new];NSApp.delegate=delegate;[NSApp run];return 0;
}}
