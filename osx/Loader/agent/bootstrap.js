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
        }
        setupReceiver(); // Recursively set up next receiver
    });
}

console.log("Frida Agent: Focus Monitor Active");
setupReceiver();
