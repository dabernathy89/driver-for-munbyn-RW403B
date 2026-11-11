// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
NSData *RWFrame(NSData *body);
NSDictionary *RWFields(NSData *body);
NSString *RWString(id value);
NSNumber *RWNumber(id value);
NSArray<NSArray<NSData *> *> *RWEncode(NSData *pixels, NSUInteger rowBytes);
