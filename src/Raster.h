// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
// Each dictionary holds pixels (MSB-first, black=1), rowBytes, height, and sections.
NSArray<NSDictionary *> *RWReadRaster(int fd, unsigned copies, NSString **error);
NSArray<NSDictionary *> *RWReadRasterData(NSData *input, unsigned copies, NSString **error);
