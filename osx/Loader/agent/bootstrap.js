function setupReceiver() {
    recv(function (message) {
        console.log(`[Frida Agent] Received message: ${JSON.stringify(message)}`);
        if (message.type === 'focus') {
            const payload = message.payload.trim();
            const parts = payload.split(' ');
            if (parts.length >= 2) {
                const windowId = parts[0];
                const isAppKit = parts[1] === '1';
                console.log(`[Frida Agent] Focused Window ID: ${windowId}, AppKit Backed: ${isAppKit}`);
            }
        } else {
            console.log(`[Frida Agent] Unknown message type: ${message.type}`);
        }
        setupReceiver(); // Recursively set up next receiver
    });
}

console.log("Frida Agent: Focus Monitor Active");
setupReceiver();

// Keep the event loop ticking and prove the script isn't dead
setInterval(function() {
    // console.log("[Frida Agent] ping"); 
}, 5000);
