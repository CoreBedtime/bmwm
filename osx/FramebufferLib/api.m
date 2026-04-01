#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "iomfb.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Surface helpers
// ---------------------------------------------------------------------------

static IOSurfaceRef create_surface(const IMFBSurfaceSpec *spec)
{
    if (!spec || spec->width == 0 || spec->height == 0) return NULL;

    size_t width = spec->width;
    size_t height = spec->height;

    if (getenv("VM_TESTING")) {
        NSDictionary *props = @{
            (id)kIOSurfaceWidth:          @(width),
            (id)kIOSurfaceHeight:         @(height),
            (id)kIOSurfacePixelFormat:    @(spec->pixelFormat),
            (id)kIOSurfaceBytesPerRow:    @(spec->bytesPerRow),
            (id)kIOSurfaceBytesPerElement:@(spec->bytesPerElement),
        };

        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        fprintf(stderr, "[screenproc] created vm-compat IOSurface %p\n", (void *)surface);
        return surface;
    }

    NSDictionary *props = @{
        @"IOSurfaceAllocSize": @(spec->allocSize),
        @"IOSurfaceCacheMode": @(spec->cacheMode),
        @"IOSurfaceWidth": @(width),
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceMapCacheAttribute": @0,
        @"IOSurfacePixelSizeCastingAllowed": @0,
        @"IOSurfaceBytesPerRow": @(spec->bytesPerRow),
        @"IOSurfaceBytesPerElement": @(spec->bytesPerElement),
        @"IOSurfacePixelFormat": @(spec->pixelFormat),
    };

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (surface && spec->caWindowServerSurface) {
        IOSurfaceSetValue(surface, CFSTR("CAWindowServerSurface"), kCFBooleanTrue);
    }
    fprintf(stderr, "[screenproc] created IOSurface %p\n", (void *)surface);
    return surface;
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

static inline void store_bgra(uint8_t *pixel,
                              uint8_t  blue,
                              uint8_t  green,
                              uint8_t  red,
                              uint8_t  alpha)
{
    pixel[0] = blue;
    pixel[1] = green;
    pixel[2] = red;
    pixel[3] = alpha;
}

static CGFloat clamp_mouse(CGFloat value, CGFloat limit)
{
    if (limit <= 1.0) return 0.0;
    if (value < 0.0) return 0.0;
    if (value > (limit - 1.0)) return limit - 1.0;
    return value;
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

__attribute__((visibility("default")))
void screenproc_render_frame(RenderState *state)
{
    if (!state) return;
    state->frameNum++;

    IOSurfaceRef back = state->surfaces[state->backIdx];
    imfb_present_all(&state->api,
                     state->activeDisplays,
                     state->activeDisplayCount,
                     back,
                     state->frame);

    state->backIdx ^= 1;
}

__attribute__((visibility("default")))
RenderState *screenproc_create(void)
{
    @autoreleasepool {
        RenderState *state = calloc(1, sizeof(*state));
        if (!state) {
            fprintf(stderr, "[screenproc] failed to allocate RenderState\n");
            return NULL;
        }

        state->frameworkHandle = imfb_load(&state->api);
        if (!state->frameworkHandle) {
            screenproc_destroy(state);
            return NULL;
        }

        if (!imfb_open(&state->api,
                       &state->displayInfo,
                       state->activeDisplays,
                       IMFB_MAX_DISPLAYS,
                       &state->activeDisplayCount)) {
            fprintf(stderr, "[screenproc] failed to open any display\n");
            screenproc_destroy(state);
            return NULL;
        }

        state->display = state->displayInfo.framebuffer;
        if (!state->display) {
            fprintf(stderr, "[screenproc] selected display record has no framebuffer\n");
            screenproc_destroy(state);
            return NULL;
        }

        if (!imfb_build_surface_spec(&state->displayInfo, &state->surfaceSpec)) {
            fprintf(stderr, "[screenproc] failed to build a surface spec for the selected display\n");
            screenproc_destroy(state);
            return NULL;
        }

        CGSize size = CGSizeMake((CGFloat)state->surfaceSpec.width,
                                 (CGFloat)state->surfaceSpec.height);
        if (size.width <= 0 || size.height <= 0) {
            fprintf(stderr, "[screenproc] invalid display size\n");
            screenproc_destroy(state);
            return NULL;
        }
        fprintf(stderr,
                "[screenproc] display size: %.0fx%.0f stride=%zu format=%08x alloc=%zu activeDisplays=%zu\n",
                size.width,
                size.height,
                state->surfaceSpec.bytesPerRow,
                state->surfaceSpec.pixelFormat,
                state->surfaceSpec.allocSize,
                state->activeDisplayCount);

        IOSurfaceRef frontSurface = create_surface(&state->surfaceSpec);
        IOSurfaceRef backSurface  = create_surface(&state->surfaceSpec);

        if (!frontSurface || !backSurface) {
            fprintf(stderr, "[screenproc] failed to create surfaces\n");
            if (frontSurface) CFRelease(frontSurface);
            if (backSurface)  CFRelease(backSurface);
            screenproc_destroy(state);
            return NULL;
        }

        state->surfaces[0]    = frontSurface;
        state->ownsSurface[0] = true;
        state->surfaces[1]    = backSurface;
        state->ownsSurface[1] = true;

        CGRect frame = CGRectMake(0, 0, size.width, size.height);
        state->frame = frame;
        state->surfaceSize = size;
        state->surfW = (size_t)size.width;
        state->frameNum = 0;
        state->backIdx = 1;

        if (pthread_mutex_init(&state->mouseLock, NULL) != 0) {
            fprintf(stderr, "[screenproc] failed to initialize mouse mutex\n");
            screenproc_destroy(state);
            return NULL;
        }
        state->mouseLockReady = true;
        state->mousePos = CGPointMake(size.width * 0.5, size.height * 0.5);

        IOMobileFramebufferReturn r =
            imfb_present_all(&state->api,
                             state->activeDisplays,
                             state->activeDisplayCount,
                             frontSurface,
                             frame);
        if (r != kIOReturnSuccess) {
            fprintf(stderr, "[screenproc] initial present failed: 0x%x\n", r);
            screenproc_destroy(state);
            return NULL;
        }

        fprintf(stderr, "[screenproc] render state initialized\n");
        return state;
    }
}

__attribute__((visibility("default")))
void screenproc_destroy(RenderState *state)
{
    if (!state) return;

    if (state->mouseLockReady) {
        pthread_mutex_destroy(&state->mouseLock);
        state->mouseLockReady = false;
    }

    for (int i = 0; i < 2; i++) {
        if (state->ownsSurface[i] && state->surfaces[i]) {
            CFRelease(state->surfaces[i]);
        }
        state->surfaces[i] = NULL;
        state->ownsSurface[i] = false;
    }

    if (state->frameworkHandle) {
        dlclose(state->frameworkHandle);
        state->frameworkHandle = NULL;
    }

    free(state);
}

__attribute__((visibility("default")))
CGSize screenproc_get_display_size(RenderState *state)
{
    return state ? state->surfaceSize : CGSizeZero;
}

__attribute__((visibility("default")))
void screenproc_set_mouse(RenderState *state, CGFloat x, CGFloat y, uint32_t buttons)
{
    if (!state || !state->mouseLockReady) return;

    pthread_mutex_lock(&state->mouseLock);
    state->mousePos = CGPointMake(
        clamp_mouse(x, state->surfaceSize.width),
        clamp_mouse(y, state->surfaceSize.height)
    );
    state->mouseButtons = buttons;
    pthread_mutex_unlock(&state->mouseLock);
}

__attribute__((visibility("default")))
void screenproc_get_buffers(RenderState *state, ScreenprocBuffers *buffers)
{
    if (!state || !buffers) return;

    // Ensure base addresses are available
    IOSurfaceLock(state->surfaces[0], 0, NULL);
    buffers->buffer0 = (void *)IOSurfaceGetBaseAddress(state->surfaces[0]);
    IOSurfaceUnlock(state->surfaces[0], 0, NULL);

    IOSurfaceLock(state->surfaces[1], 0, NULL);
    buffers->buffer1 = (void *)IOSurfaceGetBaseAddress(state->surfaces[1]);
    IOSurfaceUnlock(state->surfaces[1], 0, NULL);

    buffers->width = (uint32_t)state->surfaceSize.width;
    buffers->height = (uint32_t)state->surfaceSize.height;
    buffers->stride = (uint32_t)IOSurfaceGetBytesPerRow(state->surfaces[0]);
    buffers->format = (uint32_t)IOSurfaceGetPixelFormat(state->surfaces[0]);
}

__attribute__((visibility("default")))
void screenproc_get_info(RenderState *state, ScreenprocDisplayInfo *info)
{
    if (!info) return;

    memset(info, 0, sizeof(*info));
    info->abiVersion = SCREENPROC_DISPLAY_INFO_ABI_VERSION;
    info->structSize = (uint32_t)sizeof(*info);

    if (!state) return;

    screenproc_get_buffers(state, &info->buffers);
    info->service = (uint32_t)state->displayInfo.service;
    info->displayDevice = state->displayInfo.displayDevice;
    info->timingID = state->displayInfo.mode.timingID;
    info->colorID = state->displayInfo.mode.colorID;
    info->colorDepth = state->displayInfo.mode.colorDepth;
    info->isMain = state->displayInfo.isMain ? 1 : 0;
    info->isExternal = state->displayInfo.isExternal ? 1 : 0;
    info->hdr = state->displayInfo.mode.hdr ? 1 : 0;

    memcpy(info->transport,
           state->displayInfo.transport,
           sizeof(info->transport));
    memcpy(info->uuid,
           state->displayInfo.uuid,
           sizeof(info->uuid));
    memcpy(info->containerID,
           state->displayInfo.containerID,
           sizeof(info->containerID));
    memcpy(info->name,
           state->displayInfo.name,
           sizeof(info->name));
}
