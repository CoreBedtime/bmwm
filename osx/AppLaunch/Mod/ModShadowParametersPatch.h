#ifndef ModShadowParametersPatch_h
#define ModShadowParametersPatch_h

#import <Cocoa/Cocoa.h>
void ModShadowParametersPatchInit(void);

@interface NSWindow (ModShadowParametersPatch)
@property (nonatomic, assign) NSInteger shadowStyle;
@end

#endif
