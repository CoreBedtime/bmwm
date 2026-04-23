#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGGeometry.h>
#import <CoreVideo/CoreVideo.h>
#include <Foundation/Foundation.h>
#include <sys/_types/_pid_t.h>
#include <objc/message.h>
#import "ApplicationServer.h"
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static lua_State *g_luaState = NULL;
static const char *g_luaLogPrefix = "[WannaTile]";
static BOOL g_luaCallbackDisabled = NO;

static const char *const kWannaTileLuaCallbackName = "WindowManagerCallback";
static const char *const kWannaTileLuaGatherWindowsName = "GatherWindows";
static const char *const kWannaTileLuaMoveWindowName = "MoveWindow";
static const char *const kWannaTileLuaGetFrameName = "GetFrame";
static const char *const kWannaTileLuaSetFrameName = "SetFrame";
static const char *const kWannaTileLuaScreenFrameName = "ScreenFrame";

@protocol WannaTileRemoteManagementProtocol
- (void)setFrame:(uint32_t)windowId rect:(CGRect)rectangle;
- (CGRect)getFrame:(uint32_t)windowId;
@end

static NSDictionary *WannaTileWindowEntryFromLua(lua_State *L, int index);

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

CFArrayRef CFNumberArrayCreate(void *values, size_t size, int count, CFNumberType type) {
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


static NSArray *WannaTileGatherWindows(void) {
    if (g_connection == 0) {
        g_connection = SLSMainConnectionID();
    }

    NSMutableArray *widList = [[NSMutableArray alloc] init];

    uint64_t sid = SLSGetActiveSpace(g_connection);

    CFArrayRef space_list_ref = CFNumberArrayCreate(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);

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
    static NSMutableDictionary<NSNumber *, NSConnection *> *connectionCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxyCache = [NSMutableDictionary new];
        connectionCache = [NSMutableDictionary new];
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
        connectionCache[pidKey] = connection; // retain connection for proxy lifetime
    }

    return proxy;
}

static void WannaTileCommandWindowTo(NSDictionary *ref, CGRect rectangle) {
    uint32_t wid = 0;
    id<WannaTileRemoteManagementProtocol> proxy = (id<WannaTileRemoteManagementProtocol>)ProxyFromDict(ref, NULL, &wid);

    @try {
        [proxy setFrame:wid rect:rectangle];
    } @catch (NSException *exception) {
        NSLog(@"IPC call failed: %@", exception);
    }
}

static BOOL WannaTileWindowFrame(NSDictionary *ref, CGRect *outRect) {
    uint32_t wid = 0;
    id<WannaTileRemoteManagementProtocol> proxy = (id<WannaTileRemoteManagementProtocol>)ProxyFromDict(ref, NULL, &wid);

    if (proxy == nil) {
        return NO;
    }

    @try {
        if (outRect != NULL) {
            *outRect = [proxy getFrame:wid];
        }
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"IPC call failed: %@", exception);
        return NO;
    }
}

static CGRect WannaTileMainScreenFrame(void) {
    return [[NSScreen mainScreen] frame];
}

static void WannaTilePushRect(lua_State *L, CGRect rect) {
    lua_createtable(L, 0, 4);

    lua_pushnumber(L, rect.origin.x);
    lua_setfield(L, -2, "x");

    lua_pushnumber(L, rect.origin.y);
    lua_setfield(L, -2, "y");

    lua_pushnumber(L, rect.size.width);
    lua_setfield(L, -2, "width");

    lua_pushnumber(L, rect.size.height);
    lua_setfield(L, -2, "height");
}

static CGRect WannaTileRectFromLua(lua_State *L, int index) {
    if (index < 0) {
        index = lua_gettop(L) + index + 1;
    }

    lua_getfield(L, index, "x");
    CGFloat x = (CGFloat)luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, index, "y");
    CGFloat y = (CGFloat)luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, index, "width");
    CGFloat width = (CGFloat)luaL_checknumber(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, index, "height");
    CGFloat height = (CGFloat)luaL_checknumber(L, -1);
    lua_pop(L, 1);

    return CGRectMake(x, y, width, height);
}

static int WannaTileLuaMoveWindow(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_Integer fromIndex = luaL_checkinteger(L, 2);
    lua_Integer toIndex = luaL_checkinteger(L, 3);
    if (fromIndex < 1 || toIndex < 1) {
        return luaL_error(L, "MoveWindow indexes must be positive");
    }

    int count = (int)lua_objlen(L, 1);
    if (fromIndex > count || toIndex > count) {
        return luaL_error(L, "MoveWindow indexes out of range");
    }

    if (fromIndex == toIndex) {
        lua_settop(L, 1);
        return 1;
    }

    lua_rawgeti(L, 1, (int)fromIndex);

    if (fromIndex < toIndex) {
        for (int i = (int)fromIndex; i < (int)toIndex; ++i) {
            lua_rawgeti(L, 1, i + 1);
            lua_rawseti(L, 1, i);
        }
    } else {
        for (int i = (int)fromIndex; i > (int)toIndex; --i) {
            lua_rawgeti(L, 1, i - 1);
            lua_rawseti(L, 1, i);
        }
    }

    lua_rawseti(L, 1, (int)toIndex);
    lua_settop(L, 1);
    return 1;
}

static int WannaTileLuaGetFrame(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    NSDictionary *entry = WannaTileWindowEntryFromLua(L, 1);
    if (entry == nil) {
        lua_pushnil(L);
        return 1;
    }

    CGRect rect = CGRectZero;
    if (!WannaTileWindowFrame(entry, &rect)) {
        lua_pushnil(L);
        return 1;
    }

    WannaTilePushRect(L, rect);
    return 1;
}

static int WannaTileLuaSetFrame(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TTABLE);

    NSDictionary *entry = WannaTileWindowEntryFromLua(L, 1);
    if (entry == nil) {
        return luaL_error(L, "SetFrame requires a window table");
    }

    CGRect rect = WannaTileRectFromLua(L, 2);
    WannaTileCommandWindowTo(entry, rect);
    return 0;
}

static int WannaTileLuaScreenFrame(lua_State *L) {
    WannaTilePushRect(L, WannaTileMainScreenFrame());
    return 1;
}

static void WannaTileLogLuaError(lua_State *L, const char *context) {
    const char *message = lua_tostring(L, -1);
    NSLog(@"%s %s: %s", g_luaLogPrefix, context, message != NULL ? message : "unknown error");
    lua_pop(L, 1);
}

static void WannaTilePushWindowEntry(lua_State *L, NSDictionary *entry) {
    NSNumber *pidNum = entry[@"Process"];
    NSNumber *widNum = entry[@"Window"];

    lua_createtable(L, 0, 2);
    lua_pushinteger(L, (lua_Integer)[pidNum longLongValue]);
    lua_setfield(L, -2, "Process");
    lua_pushinteger(L, (lua_Integer)[widNum unsignedLongLongValue]);
    lua_setfield(L, -2, "Window");
}

static NSDictionary *WannaTileWindowEntryFromLua(lua_State *L, int index) {
    if (index < 0) {
        index = lua_gettop(L) + index + 1;
    }

    lua_getfield(L, index, "Process");
    if (!lua_isnumber(L, -1)) {
        lua_pop(L, 1);
        return nil;
    }
    pid_t pid = (pid_t)lua_tointeger(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, index, "Window");
    if (!lua_isnumber(L, -1)) {
        lua_pop(L, 1);
        return nil;
    }
    uint32_t wid = (uint32_t)lua_tointeger(L, -1);
    lua_pop(L, 1);

    NSNumber *pidNum = [[NSNumber alloc] initWithInt:pid];
    NSNumber *widNum = [[NSNumber alloc] initWithUnsignedInt:wid];
    NSDictionary *entry = [[NSDictionary alloc] initWithObjectsAndKeys:
                           pidNum, @"Process",
                           widNum, @"Window",
                           nil];

    [pidNum release];
    [widNum release];

    return [entry autorelease];
}

static int WannaTileLuaGatherWindows(lua_State *L) {
    NSArray *windows = WannaTileGatherWindows();
    NSUInteger count = [windows count];

    lua_createtable(L, (int)count, 0);
    for (NSUInteger i = 0; i < count; ++i) {
        WannaTilePushWindowEntry(L, windows[i]);
        lua_rawseti(L, -2, (int)(i + 1));
    }

    return 1;
}

static void WannaTileRegisterLuaBindings(lua_State *L) {
    lua_register(L, kWannaTileLuaGatherWindowsName, WannaTileLuaGatherWindows);
    lua_register(L, kWannaTileLuaMoveWindowName, WannaTileLuaMoveWindow);
    lua_register(L, kWannaTileLuaGetFrameName, WannaTileLuaGetFrame);
    lua_register(L, kWannaTileLuaSetFrameName, WannaTileLuaSetFrame);
    lua_register(L, kWannaTileLuaScreenFrameName, WannaTileLuaScreenFrame);
}

BOOL WannaTileLoadServerScript(const char *path, const char *logPrefix) {
    if (g_luaState != NULL) {
        lua_close(g_luaState);
        g_luaState = NULL;
    }

    g_luaLogPrefix = (logPrefix != NULL) ? logPrefix : "[WannaTile]";
    g_luaCallbackDisabled = NO;

    if (path == NULL || *path == '\0') {
        return NO;
    }

    g_luaState = luaL_newstate();
    if (g_luaState == NULL) {
        NSLog(@"%s warning: could not allocate Lua state for %s", g_luaLogPrefix, path);
        return NO;
    }

    luaL_openlibs(g_luaState);
    WannaTileRegisterLuaBindings(g_luaState);

    if (luaL_loadfile(g_luaState, path) != LUA_OK) {
        WannaTileLogLuaError(g_luaState, "could not load server config");
        lua_close(g_luaState);
        g_luaState = NULL;
        return NO;
    }

    if (lua_pcall(g_luaState, 0, 0, 0) != LUA_OK) {
        WannaTileLogLuaError(g_luaState, "server config failed");
        lua_close(g_luaState);
        g_luaState = NULL;
        return NO;
    }

    return YES;
}

void WannaTileShutdown(void) {
    if (g_luaState != NULL) {
        lua_close(g_luaState);
        g_luaState = NULL;
    }

    g_luaCallbackDisabled = NO;
    g_luaLogPrefix = "[WannaTile]";
}

static BOOL WannaTileRunLuaWindowManagerCallback(void) {
    if (g_luaState == NULL || g_luaCallbackDisabled) {
        return NO;
    }

    lua_getglobal(g_luaState, kWannaTileLuaCallbackName);
    if (!lua_isfunction(g_luaState, -1)) {
        lua_pop(g_luaState, 1);
        g_luaCallbackDisabled = YES;
        return NO;
    }

    if (lua_pcall(g_luaState, 0, 0, 0) != LUA_OK) {
        WannaTileLogLuaError(g_luaState, "WindowManagerCallback failed");
        g_luaCallbackDisabled = YES;
        return NO;
    }

    return YES;
}

CVReturn WindowManagerCallback(CVDisplayLinkRef displayLink,
                               const CVTimeStamp* now,
                               const CVTimeStamp* outputTime,
                               CVOptionFlags flagsIn,
                               CVOptionFlags* flagsOut,
                               void* displayLinkContext) {

    (void)displayLink;
    (void)now;
    (void)outputTime;
    (void)flagsIn;
    (void)flagsOut;
    (void)displayLinkContext;

    @autoreleasepool {
        if (!WannaTileRunLuaWindowManagerCallback()) {
            return kCVReturnSuccess;
        }
    }

    return kCVReturnSuccess;
}
