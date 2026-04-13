export function installTitlebarPatch() {
  if (typeof ObjC === "undefined" || !ObjC.available || !ObjC.classes.NSWindow) {
    return;
  }

  const NSWindow = ObjC.classes.NSWindow;
  const NSView = ObjC.classes.NSView;

  // Aggressive view hiding during layout, similar to Yeetbar
  if (NSView && NSView["- layout"]) {
    Interceptor.attach(NSView["- layout"].implementation, {
      onEnter: function (args) {
        const view = new ObjC.Object(args[0]);
        if (!view.$className) return;
        
        const typeName = view.$className;
        
        // Hide titlebar views and traffic light buttons
        if (typeName.includes("NSTitlebar") || 
            typeName.includes("_NSTitlebar") ||
            typeName.includes("_NSThemeWidget") ||
            typeName.includes("WindowHeader") ||
            typeName.includes("TopBarView")) {
            
          if (view.setHidden_) view.setHidden_(true);
          
          if (typeName.includes("_NSThemeWidget") && view.setAlphaValue_) {
            view.setAlphaValue_(0);
          }
        }
      }
    });
  }

  const applyPatch = function (windowPtr) {
    const win = new ObjC.Object(windowPtr);
    if (!win || !win.$className) return;
    
    const windowClassName = win.$className;

    // Skip system windows
    if (windowClassName.includes("MenuBar") || 
        windowClassName.includes("StatusBar") ||
        windowClassName.includes("Dock") ||
        windowClassName.includes("PopupMenu") ||
        windowClassName.includes("ContextMenu") ||
        windowClassName.includes("TUINSWindow")) {
        return;
    }

    if (win.styleMask && win.setStyleMask_) {
      win.setStyleMask_(win.styleMask() | (1 << 15)); // NSWindowStyleMaskFullSizeContentView
    }

    if (win.setTitleVisibility_) win.setTitleVisibility_(1); // NSWindowTitleHidden
    if (win.setTitlebarAppearsTransparent_) win.setTitlebarAppearsTransparent_(true);
    if (win.setMovableByWindowBackground_) win.setMovableByWindowBackground_(true);

    // Hide traffic lights explicitly
    for (let i = 0; i < 3; i++) {
      if (win.standardWindowButton_) {
        const btn = win.standardWindowButton_(i);
        if (btn !== null && btn.setHidden_) {
          btn.setHidden_(true);
        }
      }
    }
  };

  // Intercept window visibility and frame changes
  ["- makeKeyAndOrderFront:", "- orderFront:", "- orderFrontRegardless", "- setFrame:display:", "- setFrame:display:animate:"].forEach(function (selector) {
    const method = NSWindow[selector];
    if (method) {
      Interceptor.attach(method.implementation, {
        onEnter: function (args) {
          applyPatch(args[0]);
        }
      });
    }
  });
}
