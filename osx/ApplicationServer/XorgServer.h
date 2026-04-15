#ifndef XORG_SERVER_H
#define XORG_SERVER_H

#import <Foundation/Foundation.h>

@interface XorgServer : NSObject

@property (nonatomic, readonly) pid_t xorgPid;
@property (nonatomic, readonly) int displayNumber;
@property (nonatomic, readonly) NSString *configPath;
@property (nonatomic, readonly) NSString *logPath;

- (BOOL)spawnWithWidth:(int)width height:(int)height;
- (void)stop;

@end

#endif
