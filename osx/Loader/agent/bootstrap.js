let lastFocusedWindowId = 0;
let lastFocusedWindowRealId = 0;
let lastFocusedIsAppKit = false;

function setupReceiver() {
  recv(function (message) {
    if (message.type === "focus") {
      const payload = message.payload.trim();
      const parts = payload.split(" ");
      if (parts.length >= 3) {
        lastFocusedWindowId = parseInt(parts[0]);
        lastFocusedWindowRealId = parseInt(parts[1]);
        lastFocusedIsAppKit = parts[2] === "1";
        console.log(
          `[Frida Agent] Tracking Focus -> Target: ${lastFocusedWindowId}, Source(Proxy): ${lastFocusedWindowRealId}, AppKit: ${lastFocusedIsAppKit}`,
        );
      }
    }
    setupReceiver(); // Recursively set up next receiver
  });
}

function ResolvePrivateSymbol(moduleName, symbolName) {
  var module = Process.getModuleByName(moduleName);
  var symbols = module.enumerateSymbols();

  for (var i = 0; i < symbols.length; i++) {
    var sym = symbols[i];
    if (sym.name === symbolName) {
      console.log("[uv] Found symbol: " + sym.name + " at " + sym.address);
      return sym.address.strip();
    }
  }

  console.error("[uv] Symbol not found: " + symbolName);
  return null;
}

function ResolvePrivateSignedSymbol(moduleName, symbolName) {
  var addr = ResolvePrivateSymbol(moduleName, symbolName);
  if (!addr) return null;
  return addr.sign();
}

const sym = ResolvePrivateSignedSymbol("SkyLight", "CPXPostEvent");

// ev
// SLSEventRecord (size: 0x100)
//
// 0x00  uint16_t var0         (event type)
// 0x02  uint16_t var1         (subtype)
// 0x04  uint32_t var2         (flags)
// 0x08  uint32_t var3         (ANOTHER window ID ??)
// 0x0C  padding (4)
//
// 0x10  CGPoint var4          (screen position)
// 0x20  CGPoint var5          (window-local position)
//
// 0x30  uint64_t var6
// 0x38  uint32_t var7         (notifyCode)
// 0x3C  uint32_t var8         (window ID — set by caller before CPXPostEvent)
// 0x40  uint32_t var9         (slsmainconnectionid - easy)
// 0x44  padding (4)
//
// 0x48  __CGEventSourceData var10 (0x28)
//
// 0x70  _CGEventProcess var11 (0x14)
//   0x70  int          var11.var0   (connection ID — populated by CGXPostEventByConnection, zero on entry)
//   0x74  uint32_t     var11.var1
//   0x78  uint32_t     var11.var2
//   0x7C  uint32_t     var11.var3   (window ID — populated by doPostBackgroundEvent, zero on entry)
//   0x80  uint32_t     var11.var4
// 0x84  padding (4)
//
// 0x88  unknown             var12 (0x50)
//
// 0xD8  void *var13
//
// 0xE0  uint16_t var14
// 0xE2  uint16_t var15
// 0xE4  padding (4)
//
// 0xE8  __CGSEventAppendix *var16
//
// 0xF0  uint32_t var17
// 0xF4  uint8_t  var18
// 0xF5  padding (3)
//
// 0xF8  __CFData *var19
//
// 0x100 end
//
//
// typedef struct _CGSEventRecord {
// 	CGSEventRecordVersion major; /*0x0*/
// 	CGSEventRecordVersion minor; /*0x2*/
// 	CGSByteCount length;         /*0x4*/ /* Length of complete event record */
// 	CGSEventType type;           /*0x8*/ /* An event type from above */
// 	CGPoint location;            /*0x10*/ /* Base coordinates (global), from upper-left */
// 	CGPoint windowLocation;      /*0x20*/ /* Coordinates relative to window */
// 	CGSEventRecordTime time;     /*0x30*/ /* nanoseconds since startup */
// 	CGSEventFlag flags;         /* key state flags */
// 	CGWindowID window;         /* window number of assigned window */
// 	CGSConnectionID connection; /* connection the event came from */
// 	struct __CGEventSourceData {
// 		int source;
// 		unsigned int sourceUID;
// 		unsigned int sourceGID;
// 		unsigned int flags;
// 		unsigned long long userData;
// 		unsigned int sourceState;
// 		unsigned short localEventSuppressionInterval;
// 		unsigned char suppressionIntervalFlags;
// 		unsigned char remoteMouseDragFlags;
// 		unsigned long long serviceID;
// 	} eventSource;
// 	struct _CGEventProcess {
// 		int pid;
// 		unsigned int psnHi;
// 		unsigned int psnLo;
// 		unsigned int targetID;
// 		unsigned int flags;
// 	} eventProcess;
// 	NXEventData eventData;
// 	SInt32 _padding[4];
// 	void *ioEventData;
// 	unsigned short _field16;
// 	unsigned short _field17;
// 	struct _CGSEventAppendix {
// 		unsigned short windowHeight;
// 		unsigned short mainDisplayHeight;
// 		unsigned short *unicodePayload;
// 		unsigned int eventOwner;
// 		unsigned char passedThrough;
// 	} *appendix;
// 	unsigned int _field18;
// 	bool passedThrough;
// 	CFDataRef data;
// } CGSEventRecord;

if (!sym) {
  console.error("CPXPostEvent not found");
} else {
  Interceptor.attach(sym, {
    onEnter(args) {
      const ev = args[1];
      if (ev.isNull()) return;
    },
  });
}

console.log("Frida Agent: Focus Monitor Active");
setupReceiver();
