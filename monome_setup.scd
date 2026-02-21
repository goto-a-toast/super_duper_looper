/*
  monome_setup.scd
  serialosc device discovery and prefix configuration helper.

  Run this file first to find your monome64's OSC prefix and port,
  then update the values in super_duper_looper.scd accordingly.

  Requires: serialosc running (https://github.com/monome/serialosc)
*/

(
// serialosc listens on port 12002 by default
var serialoscAddr = NetAddr("127.0.0.1", 12002);
var localPort     = 57120; // use SC's default OSC port for discovery

// Listen for device list response
OSCdef(\serialoscList, { |msg|
    "Device found:".postln;
    "  id:     %".format(msg[1]).postln;
    "  type:   %".format(msg[2]).postln;
    "  port:   %".format(msg[3]).postln;
    "=> Update ~monomeSendPort in super_duper_looper.scd to: %".format(msg[3]).postln;
}, "/serialosc/device");

// Ask serialosc to list connected devices
serialoscAddr.sendMsg("/serialosc/list", "127.0.0.1", localPort);

"Querying serialosc for devices...".postln;
"(wait 1-2 seconds for response)".postln;
)

// ---------------------------------------------------------------------------
// After finding your device, connect to it to get its prefix:
// Replace <device_port> with the port number reported above.
// ---------------------------------------------------------------------------
(
var devicePort = 12003; // <-- replace with your device's port
var deviceAddr = NetAddr("127.0.0.1", devicePort);
var localPort  = 57121;

// Listen for prefix response
OSCdef(\monomePrefix, { |msg|
    "Prefix: %".format(msg[1]).postln;
    "=> Update ~monomePrefix in super_duper_looper.scd to: %".format(msg[1]).postln;
}, "/sys/prefix");

OSCdef(\monomeSize, { |msg|
    "Grid size: % x %".format(msg[1], msg[2]).postln;
}, "/sys/size");

// Request device info
deviceAddr.sendMsg("/sys/info");

// Tell device to send OSC to our local port
deviceAddr.sendMsg("/sys/port", localPort);
deviceAddr.sendMsg("/sys/prefix", "/monome");  // set prefix (optional)

"Querying device on port %...".postln.format(devicePort);
)
