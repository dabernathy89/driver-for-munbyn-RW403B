// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
// Runs until all pages receive printer completion, or returns CUPS_BACKEND_HOLD.
int RWTransmit(NSString *uuid, NSString *mac, NSArray<NSDictionary *> *pages, BOOL queryOnly);
void RWCancelTransmission(void);
void RWResetCancellation(void);
