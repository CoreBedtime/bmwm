#import <Foundation/Foundation.h>
#include "iomfb.h"
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define IMFB_INFO_TYPE_OFFSET 8
#define IMFB_INFO_SERVICE_OFFSET 20
#define IMFB_INFO_MAIN_OFFSET 152
#define IMFB_HDCP_HOOVER_STATE_OFFSET 2040

static size_t align_up_size(size_t value, size_t alignment)
{
    if (alignment == 0) return value;
    size_t rem = value % alignment;
    return rem ? (value + alignment - rem) : value;
}

static void copy_nsstring(char *dst, size_t dst_len, NSString *src)
{
    if (!dst || dst_len == 0) return;
    dst[0] = '\0';
    if (!src.length) return;

    NSData *utf8 = [src dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8.length) return;

    size_t copy_len = utf8.length;
    if (copy_len >= dst_len) copy_len = dst_len - 1;
    memcpy(dst, utf8.bytes, copy_len);
    dst[copy_len] = '\0';
}

static uint32_t env_u32(const char *name, uint32_t fallback)
{
    const char *value = getenv(name);
    if (!value || !*value) return fallback;

    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 0);
    if (!end || *end != '\0' || parsed > UINT32_MAX) return fallback;
    return (uint32_t)parsed;
}

static bool env_flag(const char *name)
{
    const char *value = getenv(name);
    return value && *value && strcmp(value, "0") != 0;
}

static bool has_display_filters(void)
{
    return (getenv("SCREENPROC_TRANSPORT") && *getenv("SCREENPROC_TRANSPORT")) ||
           (getenv("SCREENPROC_DISPLAY_UUID") && *getenv("SCREENPROC_DISPLAY_UUID")) ||
           (getenv("SCREENPROC_SERVICE") && *getenv("SCREENPROC_SERVICE")) ||
           (getenv("SCREENPROC_DISPLAY_NAME") && *getenv("SCREENPROC_DISPLAY_NAME"));
}

static bool use_display_area_probe(void)
{
    return !env_flag("SCREENPROC_SKIP_DISPLAY_AREA");
}

static bool use_swap_regions(void)
{
    return env_flag("SCREENPROC_USE_SWAP_REGIONS");
}

static bool is_external_transport(NSString *transport)
{
    if (![transport isKindOfClass:[NSString class]] || transport.length == 0) return NO;

    NSString *upper = transport.uppercaseString;
    return [upper isEqualToString:@"DP"]   ||
           [upper isEqualToString:@"HDMI"] ||
           [upper isEqualToString:@"DVI"]  ||
           [upper isEqualToString:@"VGA"]  ||
           [upper isEqualToString:@"DISPLAYPORT"] ||
           [upper isEqualToString:@"THUNDERBOLT"];
}

static NSString *transport_from_property(id property)
{
    if ([property isKindOfClass:[NSString class]]) return property;

    if ([property isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)property;
        for (NSString *key in @[ @"Transport", @"Downstream", @"Type", @"LinkType" ]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSString class]]) return value;
        }

        for (id value in dict.allValues) {
            if ([value isKindOfClass:[NSString class]] && is_external_transport(value))
                return value;
        }
    }

    if ([property isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)property) {
            NSString *transport = transport_from_property(value);
            if (transport.length) return transport;
        }
    }

    return property ? [property description] : nil;
}

static NSString *display_name_from_attributes(id property)
{
    if (![property isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)property;
    id productAttributes = dict[@"ProductAttributes"];
    if ([productAttributes isKindOfClass:[NSDictionary class]]) {
        id productName = productAttributes[@"ProductName"];
        if ([productName isKindOfClass:[NSString class]]) return productName;
    }

    id productName = dict[@"ProductName"];
    if ([productName isKindOfClass:[NSString class]]) return productName;

    return nil;
}

static uint32_t dictionary_u32(NSDictionary *dict, NSString *key, uint32_t fallback);
static uint32_t timing_active_dimension(NSDictionary *timing, NSString *axis);

static CGSize geometry_from_display_attributes(id property)
{
    if (![property isKindOfClass:[NSDictionary class]]) return CGSizeZero;

    NSDictionary *dict = (NSDictionary *)property;
    uint32_t width = dictionary_u32(dict, @"Width", 0);
    if (!width) width = dictionary_u32(dict, @"PixelWidth", 0);
    if (!width) width = dictionary_u32(dict, @"DisplayWidth", 0);

    uint32_t height = dictionary_u32(dict, @"Height", 0);
    if (!height) height = dictionary_u32(dict, @"PixelHeight", 0);
    if (!height) height = dictionary_u32(dict, @"DisplayHeight", 0);

    if ((!width || !height) && [dict[@"PreferredTimingElements"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *timing = (NSDictionary *)dict[@"PreferredTimingElements"];
        if (!width) width = timing_active_dimension(timing, @"HorizontalAttributes");
        if (!height) height = timing_active_dimension(timing, @"VerticalAttributes");
    }

    if (!width || !height) return CGSizeZero;
    return CGSizeMake((CGFloat)width, (CGFloat)height);
}

static NSNumber *dictionary_number(NSDictionary *dict, NSString *key)
{
    id value = dict[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static uint32_t dictionary_u32(NSDictionary *dict, NSString *key, uint32_t fallback)
{
    NSNumber *number = dictionary_number(dict, key);
    return number ? number.unsignedIntValue : fallback;
}

static int dictionary_i32(NSDictionary *dict, NSString *key, int fallback)
{
    NSNumber *number = dictionary_number(dict, key);
    return number ? number.intValue : fallback;
}

static uint32_t timing_active_dimension(NSDictionary *timing, NSString *axis)
{
    id attrs = timing[axis];
    if ([attrs isKindOfClass:[NSDictionary class]]) {
        return dictionary_u32(attrs, @"Active", 0);
    }
    return 0;
}

static NSDictionary *find_mode_dict_by_id(NSArray *items, uint32_t target_id)
{
    for (id obj in items) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)obj;
        if (dictionary_u32(dict, @"ID", UINT32_MAX) == target_id)
            return dict;
    }
    return nil;
}

static bool array_contains_mode_id(NSArray *items, uint32_t target_id)
{
    return find_mode_dict_by_id(items, target_id) != nil;
}

static bool timing_allows_color_id(NSDictionary *timing, uint32_t color_id)
{
    id colorModes = timing[@"ColorModes"];
    if (![colorModes isKindOfClass:[NSArray class]]) return true;

    NSArray *modes = (NSArray *)colorModes;
    for (id entry in modes) {
        if ([entry isKindOfClass:[NSNumber class]] && [entry unsignedIntValue] == color_id)
            return true;
        if ([entry isKindOfClass:[NSDictionary class]] &&
            dictionary_u32((NSDictionary *)entry, @"ID", UINT32_MAX) == color_id)
            return true;
    }

    return false;
}

static bool color_mode_supports_bgra(NSDictionary *color)
{
    NSString *pixelEncoding = [[color[@"PixelEncoding"] description] lowercaseString];
    NSString *dynamicRange  = [[color[@"DynamicRange"] description] lowercaseString];
    NSString *eotf          = [[color[@"EOTF"] description] lowercaseString];
    uint32_t depth = dictionary_u32(color, @"Depth", 8);

    bool rgb_like = (pixelEncoding.length == 0) || [pixelEncoding containsString:@"rgb"];
    bool hdr_like = [dynamicRange containsString:@"hdr"] ||
                    [dynamicRange containsString:@"hlg"] ||
                    [dynamicRange containsString:@"pq"]  ||
                    [eotf containsString:@"hdr"]         ||
                    [eotf containsString:@"hlg"]         ||
                    [eotf containsString:@"pq"];

    return rgb_like && !hdr_like && depth <= 8;
}

static CGSize record_geometry(const IMFBDisplayRecord *record)
{
    if (!record) return CGSizeZero;
    if (record->displaySize.width > 0 && record->displaySize.height > 0)
        return record->displaySize;
    if (record->displayArea.width > 0 && record->displayArea.height > 0)
        return record->displayArea;
    if (record->mode.width > 0 && record->mode.height > 0)
        return CGSizeMake((CGFloat)record->mode.width, (CGFloat)record->mode.height);
    return CGSizeZero;
}

static long long record_geometry_score(const IMFBDisplayRecord *record)
{
    CGSize size = record_geometry(record);
    return (long long)size.width * (long long)size.height;
}

static long long record_selection_score(const IMFBDisplayRecord *record)
{
    if (!record) return LLONG_MIN;

    long long score = record_geometry_score(record);
    if (record->mode.valid)
        score += (1LL << 54);
    if (record->transport[0] != '\0')
        score += (1LL << 53);
    if (record->name[0] != '\0')
        score += (1LL << 52);
    if (record->uuid[0] != '\0')
        score += (1LL << 51);
    return score;
}

static bool record_has_geometry(const IMFBDisplayRecord *record);
static bool activate_record(IMFBApi *api, IMFBDisplayRecord *record);

static NSDictionary *choose_timing_dict(NSArray *timings, uint32_t preferred_id)
{
    if (preferred_id) {
        NSDictionary *dict = find_mode_dict_by_id(timings, preferred_id);
        if (dict) return dict;
    }

    uint32_t forced_id = env_u32("SCREENPROC_FORCE_TIMING", 0);
    if (forced_id) {
        NSDictionary *dict = find_mode_dict_by_id(timings, forced_id);
        if (dict) return dict;
    }

    NSDictionary *best = nil;
    long long best_score = LLONG_MIN;
    for (id obj in timings) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *timing = (NSDictionary *)obj;
        int score = dictionary_i32(timing, @"Score", 0);
        uint32_t width = timing_active_dimension(timing, @"HorizontalAttributes");
        uint32_t height = timing_active_dimension(timing, @"VerticalAttributes");
        long long composite = (long long)score * 1000000LL + (long long)width * (long long)height;
        if (!best || composite > best_score) {
            best = timing;
            best_score = composite;
        }
    }

    if (best) return best;
    for (id obj in timings) {
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    }
    return nil;
}

static NSDictionary *choose_color_dict(NSArray *colors,
                                       NSDictionary *timing,
                                       uint32_t current_id)
{
    uint32_t forced_id = env_u32("SCREENPROC_FORCE_COLOR", 0);
    if (forced_id) {
        NSDictionary *forced = find_mode_dict_by_id(colors, forced_id);
        if (forced && timing_allows_color_id(timing, forced_id)) return forced;
    }

    if (current_id) {
        NSDictionary *current = find_mode_dict_by_id(colors, current_id);
        if (current && timing_allows_color_id(timing, current_id) && color_mode_supports_bgra(current))
            return current;
    }

    NSDictionary *fallback = nil;
    for (id obj in colors) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *color = (NSDictionary *)obj;
        uint32_t color_id = dictionary_u32(color, @"ID", 0);
        if (!timing_allows_color_id(timing, color_id)) continue;

        if (!fallback) fallback = color;
        if (color_mode_supports_bgra(color)) return color;
    }

    return fallback;
}

static bool infer_mode_roles(NSArray   *timings,
                             NSArray   *colors,
                             uint32_t   first_id,
                             uint32_t   second_id,
                             uint32_t  *timing_id_out,
                             uint32_t  *color_id_out,
                             bool      *timing_first_out)
{
    bool first_is_timing = array_contains_mode_id(timings, first_id);
    bool first_is_color  = array_contains_mode_id(colors, first_id);
    bool second_is_timing = array_contains_mode_id(timings, second_id);
    bool second_is_color  = array_contains_mode_id(colors, second_id);

    if (first_is_timing && second_is_color) {
        if (timing_id_out) *timing_id_out = first_id;
        if (color_id_out)  *color_id_out = second_id;
        if (timing_first_out) *timing_first_out = true;
        return true;
    }

    if (first_is_color && second_is_timing) {
        if (timing_id_out) *timing_id_out = second_id;
        if (color_id_out)  *color_id_out = first_id;
        if (timing_first_out) *timing_first_out = false;
        return true;
    }

    if (timing_id_out) *timing_id_out = first_id;
    if (color_id_out)  *color_id_out = second_id;
    if (timing_first_out) *timing_first_out = true;
    return false;
}

static id copy_property_obj(IMFBApi *api, IOMobileFramebufferRef display, CFStringRef key)
{
    if (!api || !api->CopyProperty || !display) return nil;
    CFTypeRef value = api->CopyProperty(display, key);
    return value ? CFBridgingRelease(value) : nil;
}

static io_service_t display_info_service(const void *display_info)
{
    if (!display_info) return IO_OBJECT_NULL;
    return *(const uint32_t *)((const uint8_t *)display_info + IMFB_INFO_SERVICE_OFFSET);
}

static uint32_t display_info_type(const void *display_info)
{
    if (!display_info) return 0;
    return *(const uint32_t *)((const uint8_t *)display_info + IMFB_INFO_TYPE_OFFSET);
}

static bool display_info_is_main(const void *display_info)
{
    if (!display_info) return false;
    return (*(const uint8_t *)((const uint8_t *)display_info + IMFB_INFO_MAIN_OFFSET) & 1) != 0;
}

static bool open_display_from_service(IMFBApi                 *api,
                                      io_service_t             service,
                                      bool                     is_main,
                                      IOMobileFramebufferReturn *status_out,
                                      IOMobileFramebufferRef  *display_out)
{
    if (!api || !api->Open || !service || !display_out) return false;

    *display_out = NULL;
    IOMobileFramebufferReturn r = api->Open(service, mach_task_self(), 0, display_out);
    if (status_out) *status_out = r;
    if (r != kIOReturnSuccess || !*display_out)
        return false;

    if (!is_main) {
        id hdcpHoover = copy_property_obj(api, *display_out, CFSTR("hdcp-hoover-protocol"));
        if ([hdcpHoover respondsToSelector:@selector(boolValue)] && [hdcpHoover boolValue])
            *(uint32_t *)((uint8_t *)*display_out + IMFB_HDCP_HOOVER_STATE_OFFSET) = 9;
    }

    return true;
}

CGSize imfb_display_size(IMFBApi *api, IOMobileFramebufferRef display)
{
    if (!api || !api->GetDisplaySize || !display) return CGSizeZero;

    IOMobileFramebufferDisplaySize size = {0, 0};
    IOMobileFramebufferReturn r = api->GetDisplaySize(display, &size);
    fprintf(stderr, "[screenproc] GetDisplaySize: 0x%x  size=%.0fx%.0f\n",
            r, size.width, size.height);

    if (r != kIOReturnSuccess || size.width <= 0 || size.height <= 0)
        return CGSizeZero;

    return size;
}

CGSize imfb_display_area(IMFBApi *api, IOMobileFramebufferRef display)
{
    if (!api || !api->GetDisplayArea || !display) return CGSizeZero;

    IOMobileFramebufferDisplayArea area = {0};
    IOMobileFramebufferReturn r = api->GetDisplayArea(display, &area);
    if (r != kIOReturnSuccess || area.width <= 0.0f || area.height <= 0.0f)
        return CGSizeZero;

    return CGSizeMake((CGFloat)area.width, (CGFloat)area.height);
}

static void populate_display_record(IMFBApi                 *api,
                                    IOMobileFramebufferRef   display,
                                    IOMobileFramebufferRef   main_display,
                                    IMFBDisplayRecord       *record)
{
    memset(record, 0, sizeof(*record));
    record->framebuffer = display;
    record->service = api->GetServiceObject ? api->GetServiceObject(display) : IO_OBJECT_NULL;
    record->isMain = (display && main_display == display);

    id transportProperty = copy_property_obj(api, display, CFSTR("Transport"));
    id uuidProperty = copy_property_obj(api, display, CFSTR("IOMFBUUID"));
    id containerProperty = copy_property_obj(api, display, CFSTR("DisplayContainerID"));
    id displayAttributes = copy_property_obj(api, display, CFSTR("DisplayAttributes"));
    id hdcpHoover = copy_property_obj(api, display, CFSTR("hdcp-hoover-protocol"));

    NSString *transport = transport_from_property(transportProperty);
    NSString *uuid = [uuidProperty isKindOfClass:[NSString class]] ? uuidProperty : [uuidProperty description];
    NSString *container = [containerProperty isKindOfClass:[NSString class]] ? containerProperty : [containerProperty description];
    NSString *name = display_name_from_attributes(displayAttributes);
    CGSize attributeGeometry = geometry_from_display_attributes(displayAttributes);

    copy_nsstring(record->transport, sizeof(record->transport), transport);
    copy_nsstring(record->uuid, sizeof(record->uuid), uuid);
    copy_nsstring(record->containerID, sizeof(record->containerID), container);
    copy_nsstring(record->name, sizeof(record->name), name);

    if (attributeGeometry.width > 0 && attributeGeometry.height > 0) {
        record->displaySize = attributeGeometry;
        record->displayArea = attributeGeometry;
    }

    record->isExternal = is_external_transport(transport) ||
                         (!record->isMain && [hdcpHoover respondsToSelector:@selector(boolValue)] &&
                          [hdcpHoover boolValue]);
    record->displayDevice = record->isExternal ? 2u : (record->isMain ? 1u : 0u);
}

static size_t collect_displays(IMFBApi *api, IMFBDisplayRecord *records, size_t record_cap)
{
    if (!api || !records || record_cap == 0) return 0;

    size_t count = 0;
    if (api->CreateDisplayList && api->Open) {
        CFArrayRef displays = api->CreateDisplayList(kCFAllocatorDefault);
        if (displays) {
            CFIndex total = CFArrayGetCount(displays);
            for (CFIndex i = 0; i < total && count < record_cap; i++) {
                const void *display_info = CFArrayGetValueAtIndex(displays, i);
                io_service_t service = display_info_service(display_info);
                uint32_t display_type = display_info_type(display_info);
                bool is_main = display_info_is_main(display_info);
                IOMobileFramebufferRef display = NULL;
                IOMobileFramebufferReturn open_r = kIOReturnSuccess;
                bool opened_from_info = false;

                if (service)
                    opened_from_info = open_display_from_service(api, service, is_main, &open_r, &display);

                if (opened_from_info) {
                    bool duplicate = false;
                    for (size_t j = 0; j < count; j++) {
                        if ((records[j].service && records[j].service == service) ||
                            records[j].framebuffer == display) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) continue;

                    populate_display_record(api, display, NULL, &records[count]);
                    records[count].service = service;
                    records[count].isMain = is_main;
                    if (display_type == 1)
                        records[count].isExternal = true;
                    records[count].displayDevice =
                        records[count].isExternal ? 2u : (records[count].isMain ? 1u : 0u);
                    count++;
                    continue;
                }

                if (service) {
                    fprintf(stderr,
                            "[screenproc] display-list open failed entry=%p service=0x%x type=%u main=%d status=0x%x\n",
                            display_info,
                            service,
                            display_type,
                            is_main,
                            open_r);
                    continue;
                }

                display = (IOMobileFramebufferRef)display_info;
                if (!display) continue;

                bool duplicate = false;
                for (size_t j = 0; j < count; j++) {
                    if (records[j].framebuffer == display) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;

                populate_display_record(api, display, NULL, &records[count++]);
            }
            CFRelease(displays);
        }
    }

    if (count == 0 && api->GetMainDisplay) {
        IOMobileFramebufferRef main_display = NULL;
        IOMobileFramebufferRef display = NULL;
        if (api->GetMainDisplay(&display) == kIOReturnSuccess && display) {
            main_display = display;
            populate_display_record(api, display, main_display, &records[count++]);
        }
    }

    if (count < record_cap && api->GetSecondaryDisplay) {
        IOMobileFramebufferRef main_display = NULL;
        if (api->GetMainDisplay)
            api->GetMainDisplay(&main_display);
        IOMobileFramebufferRef display = NULL;
        if (api->GetSecondaryDisplay(&display) == kIOReturnSuccess && display) {
            bool duplicate = false;
            for (size_t i = 0; i < count; i++) {
                if ((records[i].service && api->GetServiceObject &&
                     records[i].service == api->GetServiceObject(display)) ||
                    records[i].framebuffer == display) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate)
                populate_display_record(api, display, main_display, &records[count++]);
        }
    }

    return count;
}

static bool record_matches_filters(const IMFBDisplayRecord *record)
{
    const char *transport = getenv("SCREENPROC_TRANSPORT");
    const char *uuid = getenv("SCREENPROC_DISPLAY_UUID");
    const char *service = getenv("SCREENPROC_SERVICE");
    const char *name = getenv("SCREENPROC_DISPLAY_NAME");

    if (transport && *transport &&
        strcasecmp(transport, record->transport) != 0)
        return false;

    if (uuid && *uuid &&
        strcasecmp(uuid, record->uuid) != 0)
        return false;

    if (name && *name &&
        strcasestr(record->name, name) == NULL)
        return false;

    if (service && *service) {
        char *end = NULL;
        unsigned long expected = strtoul(service, &end, 0);
        if (!end || *end != '\0' || expected != (unsigned long)record->service)
            return false;
    }

    return true;
}

static void choose_primary_display(IMFBDisplayRecord *records,
                                   size_t             count,
                                   IMFBDisplayRecord **selected_out)
{
    *selected_out = NULL;
    if (!records || count == 0) return;

    IMFBDisplayRecord *external = NULL;
    IMFBDisplayRecord *internal_main = NULL;
    IMFBDisplayRecord *first_any = NULL;
    long long external_score = LLONG_MIN;
    long long main_score = LLONG_MIN;
    long long any_score = LLONG_MIN;

    for (size_t i = 0; i < count; i++) {
        IMFBDisplayRecord *record = &records[i];
        if (!record_has_geometry(record)) continue;

        long long score = record_selection_score(record);
        if (!first_any || score > any_score) {
            first_any = record;
            any_score = score;
        }

        if (record->isExternal && score > external_score) {
            external = record;
            external_score = score;
        }
        if (record->isMain && score > main_score) {
            internal_main = record;
            main_score = score;
        }
    }
    if (external) {
        *selected_out = external;
        return;
    }
    if (internal_main) {
        *selected_out = internal_main;
        return;
    }

    *selected_out = first_any;
}

static void refresh_record_geometry(IMFBApi *api, IMFBDisplayRecord *record)
{
    CGSize size = imfb_display_size(api, record->framebuffer);

    if (size.width > 0 && size.height > 0)
        record->displaySize = size;
    if (use_display_area_probe()) {
        CGSize area = imfb_display_area(api, record->framebuffer);
        if (area.width > 0 && area.height > 0)
            record->displayArea = area;
    }
    if ((record->displayArea.width <= 0 || record->displayArea.height <= 0) &&
        record->displaySize.width > 0 && record->displaySize.height > 0)
        record->displayArea = record->displaySize;
    if ((record->displaySize.width <= 0 || record->displaySize.height <= 0) &&
        record->mode.width > 0 && record->mode.height > 0)
        record->displaySize = CGSizeMake((CGFloat)record->mode.width,
                                         (CGFloat)record->mode.height);
    if ((record->displayArea.width <= 0 || record->displayArea.height <= 0) &&
        record->mode.width > 0 && record->mode.height > 0)
        record->displayArea = CGSizeMake((CGFloat)record->mode.width,
                                         (CGFloat)record->mode.height);
}

static bool record_has_geometry(const IMFBDisplayRecord *record)
{
    CGSize size = record_geometry(record);
    return record && size.width > 0 && size.height > 0;
}

static bool should_attempt_record(const IMFBDisplayRecord *record)
{
    if (!record || !record->framebuffer) return false;
    if (env_flag("SCREENPROC_EXTERNAL_ONLY") && !record->isExternal) return false;
    if (has_display_filters() && !record_matches_filters(record)) return false;
    return true;
}

static bool active_list_contains(const IMFBDisplayRecord *records,
                                 size_t                   count,
                                 const IMFBDisplayRecord *candidate)
{
    if (!candidate) return false;
    for (size_t i = 0; i < count; i++) {
        if ((records[i].service && candidate->service &&
             records[i].service == candidate->service) ||
            records[i].framebuffer == candidate->framebuffer)
            return true;
    }
    return false;
}

static bool record_has_metadata(const IMFBDisplayRecord *record)
{
    if (!record) return false;
    return record->service != IO_OBJECT_NULL ||
           record->transport[0] != '\0' ||
           record->uuid[0] != '\0' ||
           record->containerID[0] != '\0' ||
           record->name[0] != '\0' ||
           record->displaySize.width > 0 ||
           record->displaySize.height > 0 ||
           record->displayArea.width > 0 ||
           record->displayArea.height > 0;
}

static void log_record_state(const char *prefix, const IMFBDisplayRecord *record)
{
    if (!record) return;

    CGSize size = record_geometry(record);
    fprintf(stderr,
            "[screenproc] %s service=0x%x main=%d external=%d transport=%s name=%s size=%.0fx%.0f timing=%u color=%u depth=%u hdr=%d\n",
            prefix,
            record->service,
            record->isMain,
            record->isExternal,
            record->transport,
            record->name,
            size.width,
            size.height,
            record->mode.timingID,
            record->mode.colorID,
            record->mode.colorDepth,
            record->mode.hdr);
}

static void append_active_record(IMFBApi                  *api,
                                 const IMFBDisplayRecord  *record,
                                 IMFBDisplayRecord        *active_out,
                                 size_t                    active_cap,
                                 size_t                   *active_count)
{
    if (!record || !active_out || !active_count) return;
    if (*active_count >= active_cap) return;
    if (!should_attempt_record(record)) return;
    if (active_list_contains(active_out, *active_count, record)) return;
    if (!record->isMain && !record->isExternal && !record_has_metadata(record)) {
        fprintf(stderr, "[screenproc] skipping opaque display-list entry %p\n", record->framebuffer);
        return;
    }

    IMFBDisplayRecord candidate = *record;
    if (!activate_record(api, &candidate)) {
        log_record_state("skipping unusable display", &candidate);
        return;
    }

    active_out[(*active_count)++] = candidate;
    log_record_state("activated display", &candidate);
}

static bool configure_digital_mode(IMFBApi *api, IMFBDisplayRecord *record)
{
    if (!api || !record || !record->framebuffer)
        return true;

    if (!api->GetSupportedDigitalOutModes || !api->GetDigitalOutMode) {
        refresh_record_geometry(api, record);
        return record_has_geometry(record);
    }

    CFArrayRef color_modes_ref = NULL;
    CFArrayRef timing_modes_ref = NULL;
    IOMobileFramebufferReturn modes_r =
        api->GetSupportedDigitalOutModes(record->framebuffer, &color_modes_ref, &timing_modes_ref);

    if (modes_r != kIOReturnSuccess || !color_modes_ref || !timing_modes_ref) {
        fprintf(stderr, "[screenproc] GetSupportedDigitalOutModes failed: 0x%x\n", modes_r);
        refresh_record_geometry(api, record);
        return record_has_geometry(record);
    }

    if (!record->isMain) {
        record->isExternal = true;
        if (record->displayDevice == 0)
            record->displayDevice = 2;
    }

    NSArray *colors = (__bridge NSArray *)color_modes_ref;
    NSArray *timings = (__bridge NSArray *)timing_modes_ref;

    uint32_t first_mode_id = 0;
    uint32_t second_mode_id = 0;
    bool have_current = false;
    bool timing_first = true;
    uint32_t current_timing_id = 0;
    uint32_t current_color_id = 0;
    bool roles_known = false;

    IOMobileFramebufferReturn current_r =
        api->GetDigitalOutMode(record->framebuffer, &first_mode_id, &second_mode_id);
    if (current_r == kIOReturnSuccess) {
        have_current = true;
        roles_known = infer_mode_roles(timings,
                                       colors,
                                       first_mode_id,
                                       second_mode_id,
                                       &current_timing_id,
                                       &current_color_id,
                                       &timing_first);
    }

    NSDictionary *timing = choose_timing_dict(timings, current_timing_id);
    NSDictionary *color  = choose_color_dict(colors, timing, current_color_id);
    if (!timing || !color) {
        fprintf(stderr, "[screenproc] failed to choose external timing/color mode\n");
        refresh_record_geometry(api, record);
        return record_has_geometry(record);
    }

    uint32_t chosen_timing = dictionary_u32(timing, @"ID", current_timing_id);
    uint32_t chosen_color  = dictionary_u32(color, @"ID", current_color_id);
    if (!chosen_timing || !chosen_color) {
        fprintf(stderr, "[screenproc] chosen timing/color mode is missing an ID\n");
        refresh_record_geometry(api, record);
        return record_has_geometry(record);
    }

    record->mode.valid = true;
    record->mode.timingID = chosen_timing;
    record->mode.colorID = chosen_color;
    record->mode.colorDepth = dictionary_u32(color, @"Depth", 8);
    record->mode.hdr = !color_mode_supports_bgra(color);
    record->mode.width = timing_active_dimension(timing, @"HorizontalAttributes");
    record->mode.height = timing_active_dimension(timing, @"VerticalAttributes");

    if (api->SetDisplayDevice) {
        IOMobileFramebufferReturn device_r =
            api->SetDisplayDevice(record->framebuffer, record->displayDevice);
        fprintf(stderr, "[screenproc] SetDisplayDevice(%u): 0x%x\n",
                record->displayDevice, device_r);
    }

    bool mode_changed = !have_current ||
                        (current_timing_id != chosen_timing) ||
                        (current_color_id != chosen_color);

    if (mode_changed && api->SetDigitalOutMode) {
        uint32_t mode_arg0 = chosen_timing;
        uint32_t mode_arg1 = chosen_color;
        if (have_current && roles_known && !timing_first) {
            mode_arg0 = chosen_color;
            mode_arg1 = chosen_timing;
        }

        IOMobileFramebufferReturn set_r =
            api->SetDigitalOutMode(record->framebuffer, mode_arg0, mode_arg1);
        fprintf(stderr, "[screenproc] SetDigitalOutMode(%u, %u): 0x%x\n",
                mode_arg0, mode_arg1, set_r);
    }

    refresh_record_geometry(api, record);
    return record_has_geometry(record);
}

static bool activate_record(IMFBApi *api, IMFBDisplayRecord *record)
{
    if (!record || !record->framebuffer) return false;

    if (record->isExternal || !record->isMain)
        return configure_digital_mode(api, record);

    refresh_record_geometry(api, record);
    return record_has_geometry(record);
}

static void append_legacy_displays(IMFBApi           *api,
                                   IMFBDisplayRecord *active_out,
                                   size_t             active_cap,
                                   size_t            *active_count)
{
    IOMobileFramebufferRef main_display = NULL;
    if (api->GetMainDisplay) {
        IOMobileFramebufferReturn main_r = api->GetMainDisplay(&main_display);
        if (main_r == kIOReturnSuccess && main_display) {
            IMFBDisplayRecord record;
            populate_display_record(api, main_display, main_display, &record);
            append_active_record(api, &record, active_out, active_cap, active_count);
        } else {
            fprintf(stderr, "[screenproc] GetMainDisplay: 0x%x display=%p\n",
                    main_r, main_display);
        }
    }

    IOMobileFramebufferRef secondary_display = NULL;
    if (api->GetSecondaryDisplay) {
        IOMobileFramebufferReturn secondary_r =
            api->GetSecondaryDisplay(&secondary_display);
        if (secondary_r == kIOReturnSuccess && secondary_display) {
            IMFBDisplayRecord record;
            populate_display_record(api, secondary_display, main_display, &record);
            append_active_record(api, &record, active_out, active_cap, active_count);
        } else {
            fprintf(stderr, "[screenproc] GetSecondaryDisplay: 0x%x display=%p\n",
                    secondary_r, secondary_display);
        }
    }
}

void *imfb_load(IMFBApi *api)
{
    void *fwk = dlopen(IMFB_PATH, RTLD_NOW);
    if (!fwk) {
        fprintf(stderr, "[screenproc] dlopen IOMobileFramebuffer: %s\n", dlerror());
        return NULL;
    }

    *api = (IMFBApi){
        .CreateDisplayList     = (fn_CreateDisplayList)    dlsym(fwk, "IOMobileFramebufferCreateDisplayList"),
        .Open                  = (fn_Open)                 dlsym(fwk, "IOMobileFramebufferOpen"),
        .GetMainDisplay        = (fn_GetMainDisplay)       dlsym(fwk, "IOMobileFramebufferGetMainDisplay"),
        .GetSecondaryDisplay   = (fn_GetSecondaryDisplay)  dlsym(fwk, "IOMobileFramebufferGetSecondaryDisplay"),
        .GetServiceObject      = (fn_GetServiceObject)     dlsym(fwk, "IOMobileFramebufferGetServiceObject"),
        .CopyProperty          = (fn_CopyProperty)         dlsym(fwk, "IOMobileFramebufferCopyProperty"),
        .GetDisplaySize        = (fn_GetDisplaySize)       dlsym(fwk, "IOMobileFramebufferGetDisplaySize"),
        .GetDisplayArea        = (fn_GetDisplayArea)       dlsym(fwk, "IOMobileFramebufferGetDisplayArea"),
        .GetSupportedDigitalOutModes =
            (fn_GetSupportedDigitalOutModes)dlsym(fwk, "IOMobileFramebufferGetSupportedDigitalOutModes"),
        .GetDigitalOutMode     = (fn_GetDigitalOutMode)    dlsym(fwk, "IOMobileFramebufferGetDigitalOutMode"),
        .SetDisplayDevice      = (fn_SetDisplayDevice)     dlsym(fwk, "IOMobileFramebufferSetDisplayDevice"),
        .SetDigitalOutMode     = (fn_SetDigitalOutMode)    dlsym(fwk, "IOMobileFramebufferSetDigitalOutMode"),
        .SwapBegin             = (fn_SwapBegin)            dlsym(fwk, "IOMobileFramebufferSwapBegin"),
        .SwapSetLayer          = (fn_SwapSetLayer)         dlsym(fwk, "IOMobileFramebufferSwapSetLayer"),
        .SwapSetBackgroundColor =
            (fn_SwapSetBackgroundColor)dlsym(fwk, "IOMobileFramebufferSwapSetBackgroundColor"),
        .SwapEnd               = (fn_SwapEnd)              dlsym(fwk, "IOMobileFramebufferSwapEnd"),
        .SwapActiveRegion      = (fn_SwapActiveRegion)     dlsym(fwk, "IOMobileFramebufferSwapActiveRegion"),
        .SwapDirtyRegion       = (fn_SwapDirtyRegion)      dlsym(fwk, "IOMobileFramebufferSwapDirtyRegion"),
        .SwapSetTimestamp      = (fn_SwapSetTimestamp)     dlsym(fwk, "IOMobileFramebufferSwapSetTimestamp"),
    };

    if (!api->GetDisplaySize || !api->SwapBegin || !api->SwapSetLayer || !api->SwapEnd) {
        fprintf(stderr, "[screenproc] failed to resolve required IMFB symbols\n");
        dlclose(fwk);
        return NULL;
    }

    return fwk;
}

bool imfb_open(IMFBApi             *api,
               IMFBDisplayRecord   *primary_out,
               IMFBDisplayRecord   *active_out,
               size_t               active_cap,
               size_t              *active_count_out)
{
    if (!primary_out || !active_out || active_cap == 0 || !active_count_out) return false;
    memset(primary_out, 0, sizeof(*primary_out));
    memset(active_out, 0, active_cap * sizeof(*active_out));
    *active_count_out = 0;

    IMFBDisplayRecord records[IMFB_MAX_DISPLAYS];
    memset(records, 0, sizeof(records));

    size_t raw_count = collect_displays(api, records, IMFB_MAX_DISPLAYS);
    size_t active_count = 0;

    for (size_t i = 0; i < raw_count; i++) {
        append_active_record(api, &records[i], active_out, active_cap, &active_count);
    }

    append_legacy_displays(api, active_out, active_cap, &active_count);

    if (active_count == 0) {
        fprintf(stderr, "[screenproc] no activatable displays (raw_count=%zu)\n", raw_count);
        return false;
    }

    IMFBDisplayRecord *selected = NULL;
    choose_primary_display(active_out, active_count, &selected);
    if (!selected || !selected->framebuffer)
        return false;

    *primary_out = *selected;
    *active_count_out = active_count;

    fprintf(stderr,
            "[screenproc] using %zu active display(s); primary service=0x%x main=%d external=%d transport=%s uuid=%s\n",
            active_count,
            primary_out->service,
            primary_out->isMain,
            primary_out->isExternal,
            primary_out->transport,
            primary_out->uuid);

    return true;
}

bool imfb_build_surface_spec(const IMFBDisplayRecord *display,
                             IMFBSurfaceSpec         *spec_out)
{
    if (!display || !spec_out) return false;

    CGSize size = record_geometry(display);
    if (size.width <= 0 || size.height <= 0)
        return false;

    size_t width = (size_t)size.width;
    size_t height = (size_t)size.height;
    size_t bytes_per_element = 4;
    size_t bytes_per_row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytes_per_element);
    size_t alloc_size = align_up_size(bytes_per_row * height, 0x4000);

    *spec_out = (IMFBSurfaceSpec){
        .width = width,
        .height = height,
        .bytesPerRow = bytes_per_row,
        .allocSize = alloc_size,
        .pixelFormat = (uint32_t)'BGRA',
        .bytesPerElement = (uint32_t)bytes_per_element,
        .cacheMode = 0x700,
        .caWindowServerSurface = true,
    };

    if (display->mode.valid && (display->mode.colorDepth > 8 || display->mode.hdr)) {
        fprintf(stderr,
                "[screenproc] selected display mode is not BGRA-native (depth=%u hdr=%d); "
                "forcing SDR BGRA surface\n",
                display->mode.colorDepth,
                display->mode.hdr);
    }

    return true;
}

static IOMobileFramebufferReturn imfb_present_one(IMFBApi               *api,
                                                  IOMobileFramebufferRef display,
                                                  IOSurfaceRef           surface,
                                                  CGRect                 source_frame,
                                                  CGRect                 dest_frame)
{
    if (!api || !display || !surface) return kIOReturnBadArgument;

    int token = 0;
    IOMobileFramebufferReturn r = api->SwapBegin(display, &token);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "[screenproc] SwapBegin: 0x%x\n", r);
        return r;
    }

    if (api->SwapSetTimestamp)
        api->SwapSetTimestamp(display, mach_absolute_time());

    if (api->SwapSetBackgroundColor)
        api->SwapSetBackgroundColor(display, 0.0f, 0.0f, 0.0f);

    IOMobileFramebufferReturn lr =
        api->SwapSetLayer(display, 0, surface, source_frame, dest_frame, 512);
    if (lr != kIOReturnSuccess) {
        fprintf(stderr, "[screenproc] SwapSetLayer: 0x%x\n", lr);
        return lr;
    }

    if (use_swap_regions() && api->SwapActiveRegion)
        api->SwapActiveRegion(display, 0, dest_frame);

    if (use_swap_regions() && api->SwapDirtyRegion)
        api->SwapDirtyRegion(display, dest_frame);

    IOMobileFramebufferReturn er = api->SwapEnd(display);
    if (er != kIOReturnSuccess)
        fprintf(stderr, "[screenproc] SwapEnd: 0x%x\n", er);
    fflush(stderr);

    return (lr == kIOReturnSuccess) ? er : lr;
}

IOMobileFramebufferReturn imfb_present_all(IMFBApi                 *api,
                                           const IMFBDisplayRecord *displays,
                                           size_t                   display_count,
                                           IOSurfaceRef             surface,
                                           CGRect                   source_frame)
{
    if (!api || !displays || display_count == 0 || !surface)
        return kIOReturnBadArgument;

    size_t presented = 0;
    IOMobileFramebufferReturn first_error = kIOReturnSuccess;

    for (size_t i = 0; i < display_count; i++) {
        const IMFBDisplayRecord *record = &displays[i];
        CGSize size = record_geometry(record);
        if (!record->framebuffer || size.width <= 0 || size.height <= 0)
            continue;

        CGRect dest_frame = CGRectMake(0.0, 0.0, size.width, size.height);
        IOMobileFramebufferReturn r =
            imfb_present_one(api, record->framebuffer, surface, source_frame, dest_frame);
        if (r == kIOReturnSuccess) {
            presented++;
            continue;
        }

        if (first_error == kIOReturnSuccess)
            first_error = r;
        fprintf(stderr,
                "[screenproc] present failed on service=0x%x transport=%s err=0x%x\n",
                record->service,
                record->transport,
                r);
    }

    if (presented > 0)
        return kIOReturnSuccess;
    return first_error == kIOReturnSuccess ? kIOReturnNoDevice : first_error;
}
