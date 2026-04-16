#import "ModFontPatch.h"
#import "lua_config.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <dobby.h>
#import <fontconfig/fontconfig.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static CTFontRef (*originalCTFontCreateWithFontDescriptor)(CTFontDescriptorRef descriptor,
                                                           CGFloat size,
                                                           const CGAffineTransform *matrix) = NULL;
static CTFontRef (*originalCTFontCreateWithName)(CFStringRef name,
                                                 CGFloat size,
                                                 const CGAffineTransform *matrix) = NULL;
static CTFontRef (*originalCTFontCreateUIFontForLanguage)(CTFontUIFontType uiType,
                                                          CGFloat size,
                                                          CFStringRef language) = NULL;
static CGFontRef replacementCGFont = NULL;
static bool fontHookInstalled = false;
static pthread_once_t fontConfigOnce = PTHREAD_ONCE_INIT;
static pthread_once_t replacementFontOnce = PTHREAD_ONCE_INIT;
static pthread_once_t replacementSettingsOnce = PTHREAD_ONCE_INIT;
static char replacementFontPath[PATH_MAX];
static char replacementFontFamily[PATH_MAX];
static const char *defaultReplacementFontPath = "/Users/bedtime/Library/Fonts/ComicShannsMonoNerdFontMono-Regular.otf";
static const char *defaultReplacementFontFamily = "ComicShannsMono Nerd Font Mono";
static const char *fontConfigDirPath = "/tmp/applicator-fontconfig";
static const char *fontConfigFilePath = "/tmp/applicator-fontconfig/fonts.conf";
static const char *gtkSettingsDirPath = "/tmp/applicator-gtk/gtk-3.0";
static const char *gtkSettingsFilePath = "/tmp/applicator-gtk/gtk-3.0/settings.ini";

void ModFontPatchInit(void);

static bool ModFontPatchResolveScriptPath(const char *scriptName, char *buffer, size_t bufferSize) {
    Dl_info info;
    char dir[PATH_MAX];
    char *slash = NULL;
    int written = 0;

    if (buffer == NULL || bufferSize == 0 || scriptName == NULL || *scriptName == '\0') {
        return false;
    }

    if (dladdr((void *)ModFontPatchInit, &info) == 0 || info.dli_fname == NULL) {
        return false;
    }

    written = snprintf(dir, sizeof(dir), "%s", info.dli_fname);
    if (written < 0 || (size_t)written >= sizeof(dir)) {
        return false;
    }

    slash = strrchr(dir, '/');
    if (slash == NULL) {
        return false;
    }
    *slash = '\0';

    written = snprintf(buffer, bufferSize, "%s/%s", dir, scriptName);
    return written >= 0 && (size_t)written < bufferSize;
}

static void ModFontPatchLoadConfiguredSettingsOnce(void) {
    const char *fontPath = getenv(APPLICATOR_LUA_FONT_FILE_ENV);
    const char *fontFamily = getenv(APPLICATOR_LUA_FONT_FAMILY_ENV);

    snprintf(replacementFontPath,
             sizeof(replacementFontPath),
             "%s",
             (fontPath != NULL && fontPath[0] != '\0') ? fontPath : defaultReplacementFontPath);
    snprintf(replacementFontFamily,
             sizeof(replacementFontFamily),
             "%s",
             (fontFamily != NULL && fontFamily[0] != '\0') ? fontFamily : defaultReplacementFontFamily);
}

static void ModFontPatchLoadConfiguredSettings(void) {
    pthread_once(&replacementSettingsOnce, ModFontPatchLoadConfiguredSettingsOnce);
}

static void ModFontPatchInstallFontConfigOnce(void) {
    setenv("FONTCONFIG_FILE", fontConfigFilePath, 1);
    setenv("FONTCONFIG_PATH", fontConfigDirPath, 1);
    setenv("XDG_CONFIG_HOME", "/tmp/applicator-gtk", 1);

    ModFontPatchLoadConfiguredSettings();

    if (mkdir(fontConfigDirPath, 0755) != 0 && errno != EEXIST) {
        return;
    }

    int fd = open(fontConfigFilePath, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) {
        return;
    }

    FILE *file = fdopen(fd, "w");
    if (file == NULL) {
        close(fd);
        unlink(fontConfigFilePath);
        return;
    }

    fprintf(file,
            "<?xml version=\"1.0\"?>\n"
            "<!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\">\n"
            "<fontconfig>\n"
            "  <include ignore_missing=\"yes\">/opt/local/etc/fonts/fonts.conf</include>\n"
            "  <!-- Force every fontconfig request onto the replacement family. -->\n"
            "  <match target=\"pattern\">\n"
            "    <edit name=\"family\" mode=\"assign\" binding=\"same\">\n"
            "      <string>%s</string>\n"
            "    </edit>\n"
            "  </match>\n"
            "  <alias>\n"
            "    <family>sans-serif</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>sans</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>serif</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>monospace</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>ui-monospace</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>ui-sans-serif</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "  <alias>\n"
            "    <family>system-ui</family>\n"
            "    <prefer><family>%s</family></prefer>\n"
            "  </alias>\n"
            "</fontconfig>\n",
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily,
            replacementFontFamily);

    if (fclose(file) != 0) {
        unlink(fontConfigFilePath);
        return;
    }

    if (FcInitReinitialize() == FcFalse) {
        FcInit();
    }

    FcConfig *config = FcConfigGetCurrent();
    if (config != NULL) {
        FcConfigAppFontAddFile(config, (const FcChar8 *)replacementFontPath);
        FcConfigBuildFonts(config);
    }

    // Update GTK settings as well
    if (mkdir("/tmp/applicator-gtk", 0755) == 0 || errno == EEXIST) {
        if (mkdir(gtkSettingsDirPath, 0755) == 0 || errno == EEXIST) {
            FILE *gtkFile = fopen(gtkSettingsFilePath, "w");
            if (gtkFile) {
                fprintf(gtkFile, "[Settings]\ngtk-font-name=%s 12\n", replacementFontFamily);
                fclose(gtkFile);
            }
        }
    }
}

static void ModFontPatchInstallFontConfig(void) {
    pthread_once(&fontConfigOnce, ModFontPatchInstallFontConfigOnce);
}

static CGFloat ModFontPatchResolvePointSize(CTFontDescriptorRef descriptor, CGFloat size) {
    if (size > 0.0) {
        return size;
    }

    CGFloat resolvedSize = 0.0;
    CFTypeRef sizeValue = CTFontDescriptorCopyAttribute(descriptor, kCTFontSizeAttribute);
    if (sizeValue != NULL) {
        if (CFGetTypeID(sizeValue) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)sizeValue, kCFNumberCGFloatType, &resolvedSize);
        }
        CFRelease(sizeValue);
    }

    return resolvedSize > 0.0 ? resolvedSize : 13.0;
}

static void ModFontPatchLoadReplacementFontOnce(void) {
    ModFontPatchLoadConfiguredSettings();

    CFStringRef fontPathString = CFStringCreateWithCString(
        kCFAllocatorDefault,
        replacementFontPath,
        kCFStringEncodingUTF8);
    if (fontPathString == NULL) {
        return;
    }

    CFURLRef fontURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault,
        fontPathString,
        kCFURLPOSIXPathStyle,
        false);
    CFRelease(fontPathString);
    if (fontURL == NULL) {
        return;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithURL(fontURL);
    CFRelease(fontURL);
    if (provider == NULL) {
        return;
    }

    replacementCGFont = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
}

static void ModFontPatchLoadReplacementFont(void) {
    pthread_once(&replacementFontOnce, ModFontPatchLoadReplacementFontOnce);
}

static CTFontRef ModFontPatchCreateReplacementFont(CGFloat size,
                                                   const CGAffineTransform *matrix) {
    if (replacementCGFont == NULL) {
        return NULL;
    }

    CGFloat pointSize = size > 0.0 ? size : 13.0;
    return CTFontCreateWithGraphicsFont(replacementCGFont, pointSize, matrix, NULL);
}

static CTFontRef ModFontPatch_CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor,
                                                             CGFloat size,
                                                             const CGAffineTransform *matrix) {
    if (descriptor == NULL) {
        return originalCTFontCreateWithFontDescriptor(descriptor, size, matrix);
    }

    ModFontPatchLoadReplacementFont();
    CTFontRef replacementFont = ModFontPatchCreateReplacementFont(
        ModFontPatchResolvePointSize(descriptor, size),
        matrix);
    if (replacementFont != NULL) {
        return replacementFont;
    }

    return originalCTFontCreateWithFontDescriptor(descriptor, size, matrix);
}

static CTFontRef ModFontPatch_CTFontCreateWithName(CFStringRef name,
                                                   CGFloat size,
                                                   const CGAffineTransform *matrix) {
    (void)name;

    ModFontPatchLoadReplacementFont();
    CTFontRef replacementFont = ModFontPatchCreateReplacementFont(size, matrix);
    if (replacementFont != NULL) {
        return replacementFont;
    }

    return originalCTFontCreateWithName(name, size, matrix);
}

static CTFontRef ModFontPatch_CTFontCreateUIFontForLanguage(CTFontUIFontType uiType,
                                                            CGFloat size,
                                                            CFStringRef language) {
    (void)uiType;
    (void)language;

    ModFontPatchLoadReplacementFont();
    CTFontRef replacementFont = ModFontPatchCreateReplacementFont(size, NULL);
    if (replacementFont != NULL) {
        return replacementFont;
    }

    return originalCTFontCreateUIFontForLanguage(uiType, size, language);
}

void ModFontPatchInit(void) {
    if (fontHookInstalled) {
        return;
    }

    char patchesLuaPath[PATH_MAX];
    if (ModFontPatchResolveScriptPath("patches.lua", patchesLuaPath, sizeof(patchesLuaPath))) {
        applicator_lua_config_load_patches(patchesLuaPath, "[ModFontPatch]");
    } else {
        fprintf(stderr, "[ModFontPatch] warning: could not resolve patches.lua next to the helper library\n");
    }

    ModFontPatchInstallFontConfig();
    ModFontPatchLoadReplacementFont();

    int hookResult = DobbyHook((void *)CTFontCreateWithFontDescriptor,
                               (void *)ModFontPatch_CTFontCreateWithFontDescriptor,
                               (void **)&originalCTFontCreateWithFontDescriptor);
    if (hookResult != 0) {
        fprintf(stderr, "[ModFontPatch] failed to hook CTFontCreateWithFontDescriptor: %d\n", hookResult);
        return;
    }

    hookResult = DobbyHook((void *)CTFontCreateWithName,
                           (void *)ModFontPatch_CTFontCreateWithName,
                           (void **)&originalCTFontCreateWithName);
    if (hookResult != 0) {
        fprintf(stderr, "[ModFontPatch] failed to hook CTFontCreateWithName: %d\n", hookResult);
        return;
    }

    hookResult = DobbyHook((void *)CTFontCreateUIFontForLanguage,
                           (void *)ModFontPatch_CTFontCreateUIFontForLanguage,
                           (void **)&originalCTFontCreateUIFontForLanguage);
    if (hookResult != 0) {
        fprintf(stderr, "[ModFontPatch] failed to hook CTFontCreateUIFontForLanguage: %d\n", hookResult);
        return;
    }

    fontHookInstalled = true;
}
