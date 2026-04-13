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
// 0x00  uint16_t var0
// 0x02  uint16_t var1
// 0x04  uint32_t var2
// 0x08  uint32_t var3
// 0x0C  padding (4)
//
// 0x10  CGPoint var4
// 0x20  CGPoint var5
//
// 0x30  uint64_t var6
// 0x38  uint32_t var7
// 0x3C  uint32_t var8
// 0x40  uint32_t var9
// 0x44  padding (4)
//
// 0x48  __CGEventSourceData var10 (0x28)
// 0x70  _CGEventProcess     var11 (0x14)
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
        const windowId = ev.add(0x08).readU32();

        // CGPoint at 0x10 (screen click pos)
        const x1 = ev.add(0x10).readDouble();
        const y1 = ev.add(0x18).readDouble();

        // CGPoint at 0x20 (window click pos)
        const x2 = ev.add(0x20).readDouble();
        const y2 = ev.add(0x28).readDouble();

        console.log(
          `[CPXPostEvent] type=${type} subtype=${subtype} flags=0x${flags.toString(
            16,
          )} windowId=${windowId} p1=(${x1}, ${y1}) p2=(${x2}, ${y2})`,
        );
      } catch (e) {
        console.log("read fail:", e);
      }
    },
  });
}

console.log("Frida Agent: Focus Monitor Active");
setupReceiver();
