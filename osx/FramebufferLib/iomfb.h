#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOReturn.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#define IMFB_PATH \
    "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
#define IMFB_MAX_DISPLAYS 16
#define SCREENPROC_DISPLAY_INFO_ABI_VERSION 1

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef IOReturn                      IOMobileFramebufferReturn;
typedef CGSize                        IOMobileFramebufferDisplaySize;
typedef struct {
    float width;
    float height;
} IOMobileFramebufferDisplayArea;

typedef CFArrayRef (*fn_CreateDisplayList)(CFAllocatorRef);
typedef IOMobileFramebufferReturn (*fn_Open)(io_service_t, task_port_t, uint32_t, IOMobileFramebufferRef *);
typedef IOMobileFramebufferReturn (*fn_GetMainDisplay)(IOMobileFramebufferRef *);
typedef IOMobileFramebufferReturn (*fn_GetSecondaryDisplay)(IOMobileFramebufferRef *);
typedef io_service_t (*fn_GetServiceObject)(IOMobileFramebufferRef);
typedef CFTypeRef (*fn_CopyProperty)(IOMobileFramebufferRef, CFStringRef);
typedef IOMobileFramebufferReturn (*fn_GetDisplaySize)(IOMobileFramebufferRef, IOMobileFramebufferDisplaySize *);
typedef IOMobileFramebufferReturn (*fn_GetDisplayArea)(IOMobileFramebufferRef, IOMobileFramebufferDisplayArea *);
typedef IOMobileFramebufferReturn (*fn_GetSupportedDigitalOutModes)(IOMobileFramebufferRef, CFArrayRef *, CFArrayRef *);
typedef IOMobileFramebufferReturn (*fn_GetDigitalOutMode)(IOMobileFramebufferRef, uint32_t *, uint32_t *);
typedef IOMobileFramebufferReturn (*fn_SetDisplayDevice)(IOMobileFramebufferRef, uint32_t);
typedef IOMobileFramebufferReturn (*fn_SetDigitalOutMode)(IOMobileFramebufferRef, uint32_t, uint32_t);
typedef IOMobileFramebufferReturn (*fn_SwapBegin)(IOMobileFramebufferRef, int *);
typedef IOMobileFramebufferReturn (*fn_SwapSetLayer)(IOMobileFramebufferRef, int, IOSurfaceRef, CGRect, CGRect, int);
typedef IOMobileFramebufferReturn (*fn_SwapSetBackgroundColor)(IOMobileFramebufferRef, float, float, float);
typedef IOMobileFramebufferReturn (*fn_SwapEnd)(IOMobileFramebufferRef);
typedef IOMobileFramebufferReturn (*fn_SwapActiveRegion)(IOMobileFramebufferRef, uint32_t, CGRect);
typedef IOMobileFramebufferReturn (*fn_SwapDirtyRegion)(IOMobileFramebufferRef, CGRect);
typedef IOMobileFramebufferReturn (*fn_SwapSetTimestamp)(IOMobileFramebufferRef, uint64_t);
typedef IOMobileFramebufferReturn (*fn_RequestPowerChange)(IOMobileFramebufferRef, uint32_t);
typedef struct {
    fn_CreateDisplayList    CreateDisplayList;
    fn_Open                 Open;
    fn_GetMainDisplay        GetMainDisplay;
    fn_GetSecondaryDisplay   GetSecondaryDisplay;
    fn_GetServiceObject      GetServiceObject;
    fn_CopyProperty          CopyProperty;
    fn_GetDisplaySize        GetDisplaySize;
    fn_GetDisplayArea        GetDisplayArea;
    fn_GetSupportedDigitalOutModes GetSupportedDigitalOutModes;
    fn_GetDigitalOutMode     GetDigitalOutMode;
    fn_SetDisplayDevice      SetDisplayDevice;
    fn_SetDigitalOutMode     SetDigitalOutMode;
    fn_SwapBegin             SwapBegin;
    fn_SwapSetLayer          SwapSetLayer;
    fn_SwapSetBackgroundColor SwapSetBackgroundColor;
    fn_SwapEnd               SwapEnd;
    fn_SwapActiveRegion      SwapActiveRegion;
    fn_SwapDirtyRegion       SwapDirtyRegion;
    fn_SwapSetTimestamp      SwapSetTimestamp;
} IMFBApi;

typedef struct {
    bool     valid;
    uint32_t timingID;
    uint32_t colorID;
    uint32_t colorDepth;
    bool     hdr;
    uint32_t width;
    uint32_t height;
} IMFBDigitalMode;

typedef struct {
    IOMobileFramebufferRef framebuffer;
    io_service_t           service;
    bool                   isMain;
    bool                   isExternal;
    uint32_t               displayDevice;
    char                   transport[32];
    char                   uuid[128];
    char                   containerID[128];
    char                   name[128];
    CGSize                 displaySize;
    CGSize                 displayArea;
    IMFBDigitalMode        mode;
} IMFBDisplayRecord;

typedef struct {
    size_t   width;
    size_t   height;
    size_t   bytesPerRow;
    size_t   allocSize;
    uint32_t pixelFormat;
    uint32_t bytesPerElement;
    uint32_t cacheMode;
    bool     caWindowServerSurface;
} IMFBSurfaceSpec;

typedef struct {
    IMFBApi                api;
    void                  *frameworkHandle;
    IOMobileFramebufferRef display;
    IMFBDisplayRecord      displayInfo;
    IMFBDisplayRecord      activeDisplays[IMFB_MAX_DISPLAYS];
    size_t                 activeDisplayCount;
    IMFBSurfaceSpec        surfaceSpec;
    IOSurfaceRef           surfaces[2];
    bool                   ownsSurface[2];
    CGRect                 frame;
    CGSize                 surfaceSize;
    size_t                 surfW;
    size_t                 frameNum;
    int                    backIdx;
    pthread_mutex_t        mouseLock;
    bool                   mouseLockReady;
    CGPoint                mousePos;
    uint32_t               mouseButtons;
} RenderState;

typedef struct {
    void                  *buffer0;
    void                  *buffer1;
    uint32_t               width;
    uint32_t               height;
    uint32_t               stride;
    uint32_t               format;
} ScreenprocBuffers;

typedef struct {
    uint32_t               abiVersion;
    uint32_t               structSize;
    ScreenprocBuffers      buffers;
    uint32_t               service;
    uint32_t               displayDevice;
    uint32_t               timingID;
    uint32_t               colorID;
    uint32_t               colorDepth;
    uint8_t                isMain;
    uint8_t                isExternal;
    uint8_t                hdr;
    uint8_t                reserved;
    char                   transport[32];
    char                   uuid[128];
    char                   containerID[128];
    char                   name[128];
} ScreenprocDisplayInfo;

// Load IOMobileFramebuffer.framework and populate api.
// Returns the dlopen handle on success, NULL on failure.
void *imfb_load(IMFBApi *api);

// Acquire all usable displays and choose a primary display record for sizing.
// Prefers an external display selected by transport/service/UUID filters.
// Returns false only when no usable display could be activated.
bool imfb_open(IMFBApi *api,
               IMFBDisplayRecord *primary_out,
               IMFBDisplayRecord *active_out,
               size_t             active_cap,
               size_t            *active_count_out);

// Query the display dimensions via GetDisplaySize.
CGSize imfb_display_size(IMFBApi *api, IOMobileFramebufferRef display);
CGSize imfb_display_area(IMFBApi *api, IOMobileFramebufferRef display);

// Build a linear BGRA IOSurface spec from the selected display/mode.
bool imfb_build_surface_spec(const IMFBDisplayRecord *display,
                             IMFBSurfaceSpec         *spec_out);

// Present a surface on every active display via SwapBegin/SwapSetLayer/SwapEnd.
IOMobileFramebufferReturn imfb_present_all(IMFBApi                  *api,
                                           const IMFBDisplayRecord  *displays,
                                           size_t                    display_count,
                                           IOSurfaceRef              surface,
                                           CGRect                    source_frame);

RenderState *screenproc_create(void);
void screenproc_destroy(RenderState *state);
CGSize screenproc_get_display_size(RenderState *state);
void screenproc_set_mouse(RenderState *state, CGFloat x, CGFloat y, uint32_t buttons);
void screenproc_render_frame(RenderState *state);
void screenproc_get_buffers(RenderState *state, ScreenprocBuffers *buffers);
void screenproc_get_info(RenderState *state, ScreenprocDisplayInfo *info);
