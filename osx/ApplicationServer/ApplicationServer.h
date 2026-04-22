#ifndef APPLICATION_SERVER_H
#define APPLICATION_SERVER_H

#import <Cocoa/Cocoa.h>

@interface ApplicationServer : NSObject

- (instancetype)init;
- (BOOL)start;
- (void)stop;

@end

#endif