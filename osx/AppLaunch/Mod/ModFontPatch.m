#import "ModFontPatch.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <dobby.h>
#import <fontconfig/fontconfig.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

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
static const char *replacementFontPath = "/Users/bedtime/Library/Fonts/ComicShannsMonoNerdFontMono-Regular.otf";
static const char *replacementFontFamily = "ComicShannsMono Nerd Font Mono";
static const char *fontConfigDirPath = "/tmp/applicator-fontconfig";
static const char *fontConfigFilePath = "/tmp/applicator-fontconfig/fonts.conf";

static void ModFontPatchInstallFontConfigOnce(void) {
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

    setenv("FONTCONFIG_FILE", fontConfigFilePath, 1);
    setenv("FONTCONFIG_PATH", fontConfigDirPath, 1);

    if (FcInitReinitialize() == FcFalse) {
        FcInit();
    }

    FcConfig *config = FcConfigGetCurrent();
    if (config != NULL) {
        FcConfigAppFontAddFile(config, (const FcChar8 *)replacementFontPath);
        FcConfigBuildFonts(config);
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
