function setupReceiver() {
  recv(function (message) {
    console.log(`[Frida Agent] Received message: ${JSON.stringify(message)}`);
    if (message.type === "focus") {
      const payload = message.payload.trim();
      const parts = payload.split(" ");
      if (parts.length >= 2) {
        const windowId = parts[0];
        const isAppKit = parts[1] === "1";
        console.log(
          `[Frida Agent] Focused Window ID: ${windowId}, AppKit Backed: ${isAppKit}`,
        );
      }
    } else {
      console.log(`[Frida Agent] Unknown message type: ${message.type}`);
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
// 0x08  uint32_t var3         (raw connection port — NOT window ID)
// 0x0C  padding (4)
//
// 0x10  CGPoint var4          (screen position)
// 0x20  CGPoint var5          (window-local position)
//
// 0x30  uint64_t var6
// 0x38  uint32_t var7         (notifyCode)
// 0x3C  uint32_t var8         (window ID — set by caller before CPXPostEvent)
// 0x40  uint32_t var9
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

if (!sym) {
  console.error("CPXPostEvent not found");
} else {
  Interceptor.attach(sym, {
    onEnter(args) {
      const ev = args[1];
      if (ev.isNull()) return;

      try {
        const type = ev.readU16();
        const subtype = ev.add(0x02).readU16();
        const flags = ev.add(0x04).readU32();

        // var8 @ 0x3C = window ID (set by caller, e.g. PostCGSEventToProcess writes a4 here)
        const windowId = ev.add(0x3c).readU32();

        // _CGEventProcess.var0 @ 0x70 = connection ID (zero on entry, populated downstream)
        const connectionId = ev.add(0x70).readS32();

        // CGPoint at 0x10 (screen position)
        const x1 = ev.add(0x10).readDouble();
        const y1 = ev.add(0x18).readDouble();

        // CGPoint at 0x20 (window-local position)
        const x2 = ev.add(0x20).readDouble();
        const y2 = ev.add(0x28).readDouble();

        console.log(
          `[CPXPostEvent] type=${type} subtype=${subtype} flags=0x${flags.toString(
            16,
          )} connectionId=${connectionId} windowId=${windowId} p1=(${x1}, ${y1}) p2=(${x2}, ${y2})`,
        );
      } catch (e) {
        console.log("read fail:", e);
      }
    },
  });
}

console.log("Frida Agent: Focus Monitor Active");
setupReceiver();
