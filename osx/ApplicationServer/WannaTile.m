#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGGeometry.h>
#import <CoreVideo/CoreVideo.h>
#include <Foundation/Foundation.h>
#include <sys/_types/_pid_t.h>
#include <objc/message.h>
#import "ApplicationServer.h"
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int cid);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetOwner(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern pid_t SLSWindowIteratorGetPID(CFTypeRef iterator);
extern ProcessSerialNumber SLSWindowIteratorGetPSN(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);
extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef windows, uint32_t options);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef window_query);

int g_connection = 0;

CFArrayRef CFNumberArray(void *values, size_t size, int count, CFNumberType type) {
    CFNumberRef temp[count];

    for (int i = 0; i < count; ++i) {
        temp[i] = CFNumberCreate(NULL, type, ((char *)values) + (size * i));
    }

    CFArrayRef result = CFArrayCreate(NULL, (const void **)temp, count, &kCFTypeArrayCallBacks);

    for (int i = 0; i < count; ++i) {
        CFRelease(temp[i]);
    }

    return result; // caller owns
}

Boolean IsWindowSuitable(CFTypeRef iterator) {
    uint64_t tags = SLSWindowIteratorGetTags(iterator);
    uint64_t attributes = SLSWindowIteratorGetAttributes(iterator);
    uint32_t parent_wid = SLSWindowIteratorGetParentID(iterator);

    if ((parent_wid == 0)
        && ((attributes & 0x2) || (tags & 0x400000000000000))
        && ((tags & 0x1) || ((tags & 0x2) && (tags & 0x80000000)))) {
        return true;
    }

    return false;
}

NSArray* GatherWindows(void) {
    NSMutableArray *widList = [[NSMutableArray alloc] init];

    uint64_t sid = SLSGetActiveSpace(g_connection);

    CFArrayRef space_list_ref = CFNumberArray(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);

    uint64_t set_tags = 1;
    uint64_t clear_tags = 0;

    CFArrayRef window_list =
        SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_list_ref, 0x2, &set_tags, &clear_tags);

    if (window_list) {
        if (CFArrayGetCount(window_list) > 0) {

            CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list, 0x0);

            if (query) {
                CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

                if (iterator) {
                    while (SLSWindowIteratorAdvance(iterator)) {
                        if (IsWindowSuitable(iterator)) {
                            uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
                            pid_t pid = SLSWindowIteratorGetPID(iterator);

                            NSNumber *pidNum = [[NSNumber alloc] initWithInt:pid];
                            NSNumber *widNum = [[NSNumber alloc] initWithUnsignedInt:wid];

                            NSDictionary *entry = [[NSDictionary alloc] initWithObjectsAndKeys:
                                pidNum, @"Process",
                                widNum, @"Window",
                                nil];

                            [widList addObject:entry];

                            // balance retains
                            [pidNum release];
                            [widNum release];
                            [entry release];
                        }
                    }
                    CFRelease(iterator);
                }
                CFRelease(query);
            }
        }
        CFRelease(window_list);
    }

    CFRelease(space_list_ref);

    return [widList autorelease];
}

id ProxyFromDict(NSDictionary *ref, pid_t *outPid, uint32_t *outWid) {
    static NSMutableDictionary<NSNumber *, id> *proxyCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxyCache = [NSMutableDictionary new];
    });

    NSNumber *process_id = ref[@"Process"];
    NSNumber *window_id  = ref[@"Window"];

    if (!process_id || !window_id) return nil;

    pid_t pid = [process_id intValue];
    uint32_t wid = [window_id unsignedIntValue];

    if (outPid) *outPid = pid;
    if (outWid) *outWid = wid;

    NSNumber *pidKey = @(pid);

    // ---- cache lookup ----
    id cachedProxy = proxyCache[pidKey];
    if (cachedProxy) {
        return cachedProxy;
    }

    // ---- resolve connection ----
    NSString *connectionName = [NSString stringWithFormat:@"bedtime.wm.%d", pid];

    NSConnection *connection =
        [NSConnection connectionWithRegisteredName:connectionName host:nil];

    if (!connection) {
        NSLog(@"Failed to connect to %@", connectionName);
        return nil;
    }

    id proxy = [connection rootProxy];

    if (proxy) {
        proxyCache[pidKey] = proxy;
    }

    return proxy;
}

CGRect CGRectLerp(CGRect start, CGRect end, double t) {
    return CGRectMake(
        start.origin.x + (end.origin.x - start.origin.x) * t,
        start.origin.y + (end.origin.y - start.origin.y) * t,
        start.size.width + (end.size.width - start.size.width) * t,
        start.size.height + (end.size.height - start.size.height) * t
    );
}

void CommandWindowTo(NSDictionary *ref, CGRect rectangle) {
    uint32_t _wid;
    id proxy = ProxyFromDict(ref, NULL, &_wid);
    CGFloat t = 0.15;

    @try {
        //[proxy setFrame:wid rect:rectangle];

        // 1. Setup the Selector
        SEL getFrameSel = @selector(getFrame:);
        CGRect (*getFrame)(id, SEL, uint32_t) = (CGRect (*)(id, SEL, uint32_t))objc_msgSend;
        CGRect currentRect = getFrame(proxy, getFrameSel, _wid);

        NSLog(@"%@", NSStringFromRect(currentRect));

        CGRect nextRect = CGRectLerp(currentRect, rectangle, t);

        [proxy setFrame:_wid rect:nextRect];

    } @catch (NSException *exception) {
        NSLog(@"IPC call failed: %@", exception);
    }
}

void TileWindows(NSArray *windows) {
    if ([windows count] == 0) return;

    CGRect screenFrame = [[NSScreen mainScreen] frame];

    NSUInteger count = [windows count];

    NSUInteger cols = ceil(sqrt(count));
    NSUInteger rows = ceil((double)count / cols);

    CGFloat tileWidth  = screenFrame.size.width  / cols;
    CGFloat tileHeight = screenFrame.size.height / rows;

    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger row = i / cols;
        NSUInteger col = i % cols;

        CGRect rect = CGRectMake(
            screenFrame.origin.x + col * tileWidth,
            screenFrame.origin.y + row * tileHeight,
            tileWidth,
            tileHeight
        );

        CGRect final = CGRectInset(rect, 64, 64);

        CommandWindowTo(windows[i], final);
    }
}

CVReturn WindowManagerCallback(CVDisplayLinkRef displayLink,
                              const CVTimeStamp* now,
                              const CVTimeStamp* outputTime,
                              CVOptionFlags flagsIn,
                              CVOptionFlags* flagsOut,
                              void* displayLinkContext) {

    if (g_connection == 0) {
        g_connection = SLSMainConnectionID();
    }

    ApplicationServer *server = (ApplicationServer *)displayLinkContext;

    @autoreleasepool {
        NSArray *windows = GatherWindows();
        TileWindows(windows);
        NSLog(@"%d %@", g_connection, windows);
    }

    return kCVReturnSuccess;
}
