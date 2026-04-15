#import "FocusSocket.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

@implementation FocusSocket {
    NSString *_socketPath;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverFd = -1;
    }
    return self;
}

- (BOOL)setup:(const char *)path {
    _socketPath = [[NSString stringWithUTF8String:path] retain];
    unlink(path);
    _serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_serverFd < 0) return NO;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (bind(_serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_serverFd);
        _serverFd = -1;
        return NO;
    }

    if (listen(_serverFd, 5) < 0) {
        close(_serverFd);
        _serverFd = -1;
        return NO;
    }

    int flags = fcntl(_serverFd, F_GETFL, 0);
    fcntl(_serverFd, F_SETFL, flags | O_NONBLOCK);
    return YES;
}

- (void)broadcastToClients:(NSString *)message {
    int client_fd;
    while ((client_fd = accept(_serverFd, NULL, NULL)) >= 0) {
        send(client_fd, [message UTF8String], [message length], 0);
        close(client_fd);
    }
}

- (void)updateFocusWithWindow:(xcb_window_t)xWindow nativeWindowId:(uint32_t)nativeWindowId cid:(int)cid {
    if (_serverFd < 0) return;

    if (cid == 0) cid = 333;
    NSString *message = [NSString stringWithFormat:@"%u %u 0 %d\n", nativeWindowId, xWindow, cid];
    NSLog(@"[FocusSocket] Broadcasting focus change: %@", message);
    [self broadcastToClients:message];

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock >= 0) {
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, "/tmp/applicator_loader.sock", sizeof(addr.sun_path) - 1);

        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            send(sock, [message UTF8String], [message length], 0);
        }
        close(sock);
    }
}

- (void)handleIncomingData {
    int client_fd;
    while ((client_fd = accept(_serverFd, NULL, NULL)) >= 0) {
        char buffer[1024];
        recv(client_fd, buffer, sizeof(buffer), 0);
        close(client_fd);
    }
}

- (void)stop {
    if (_serverFd >= 0) {
        close(_serverFd);
        _serverFd = -1;
    }
    if (_socketPath) {
        unlink([_socketPath UTF8String]);
        [_socketPath release];
        _socketPath = nil;
    }
}

- (void)dealloc {
    [self stop];
    [super dealloc];
}

@end
