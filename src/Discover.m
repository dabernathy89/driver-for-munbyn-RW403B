// SPDX-License-Identifier: MIT
// Read-only BLE advertisement discovery. Does not connect or send printer commands.
#import <AppKit/AppKit.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface RWDiscovery : NSObject <NSApplicationDelegate, CBCentralManagerDelegate>
@property NSWindow *window;
@property NSTextView *text;
@property CBCentralManager *central;
@property NSMutableSet<NSString *> *seen;
@property NSTimer *timer;
@end
@implementation RWDiscovery
- (void)append:(NSString *)message {
    self.text.string = [self.text.string stringByAppendingString:message];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSMenu *menu=[NSMenu new];
    NSMenuItem *application=[NSMenuItem new];[menu addItem:application];
    NSMenu *applicationMenu=[NSMenu new];application.submenu=applicationMenu;
    [applicationMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *edit=[NSMenuItem new];edit.title=@"Edit";[menu addItem:edit];
    edit.submenu=[[NSMenu alloc] initWithTitle:@"Edit"];
    [edit.submenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit.submenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    NSApp.mainMenu=menu;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,720,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"RW403B Bluetooth discovery";
    self.window.releasedWhenClosed=NO;
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:self.window.contentView.bounds];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;
    self.text=[[NSTextView alloc] initWithFrame:scroll.bounds];
    self.text.editable=NO;self.text.selectable=YES;self.text.richText=NO;
    self.text.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.text.autoresizingMask=NSViewWidthSizable;scroll.documentView=self.text;
    [self.window.contentView addSubview:scroll];
    self.text.string=@"Select and copy the UUID for your RW403B.\nUse the MAC address printed on its self-test label for --mac.\nThis scan does not connect or print. Close and reopen to scan again.\n\n";
    [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    self.seen=[NSMutableSet new];
    self.central=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {(void)sender;return YES;}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self.timer invalidate];
    if(central.state==CBManagerStatePoweredOn) {
        [self append:@"Scanning for 30 seconds…\n"];
        [central scanForPeripheralsWithServices:nil options:nil];
        self.timer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *timer) {
            (void)timer;[self.central stopScan];
            [self append:self.seen.count?@"\nScan complete.\n":@"\nNo RW403B found. Check printer power and disconnect other printing apps.\n"];
        }];
    } else if(central.state==CBManagerStateUnauthorized) [self append:@"Bluetooth permission denied. Allow RW403B Discovery in System Settings.\n"];
    else if(central.state==CBManagerStatePoweredOff) [self append:@"Bluetooth is turned off.\n"];
    else if(central.state==CBManagerStateUnsupported) [self append:@"Bluetooth LE is unavailable.\n"];
}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary *)data RSSI:(NSNumber *)rssi {
    (void)central;(void)rssi;
    NSString *name=data[CBAdvertisementDataLocalNameKey]?:peripheral.name?:@"";
    if([name rangeOfString:@"RW403B" options:NSCaseInsensitiveSearch].location==NSNotFound) return;
    NSString *identifier=peripheral.identifier.UUIDString;
    if([self.seen containsObject:identifier]) return;
    [self.seen addObject:identifier];
    [self append:[NSString stringWithFormat:@"\nName: %@\nUUID: %@\n",name,identifier]];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;[self.timer invalidate];[self.central stopScan];
}
@end
int main(void) {@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    RWDiscovery *delegate=[RWDiscovery new];NSApp.delegate=delegate;[NSApp run];return 0;
}}
