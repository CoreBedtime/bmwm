#import "Mod/ModFontPatch.h"
#import "Mod/ModTitlebarPatch.h"
#import "Mod/ModCornerMaskPatch.h"
#import "Mod/ModShadowParametersPatch.h"
#import <objc/runtime.h>

__attribute__((constructor))
static void initializer(void) {
    ModFontPatchInit();
    ModTitlebarPatchInit();
    ModCornerMaskPatchInit();
    ModShadowParametersPatchInit();
}
