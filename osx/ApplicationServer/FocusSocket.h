#ifndef FOCUS_SOCKET_H
#define FOCUS_SOCKET_H

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@interface FocusSocket : NSObject

@property (nonatomic, readonly) int serverFd;

- (BOOL)setup:(const char *)path;
- (void)broadcastToClients:(NSString *)message;
- (void)updateFocusWithWindow:(xcb_window_t)xWindow nativeWindowId:(uint32_t)nativeWindowId cid:(int)cid;
- (void)handleIncomingData;
- (void)stop;

@end

#endif
