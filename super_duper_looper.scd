/*
  super_duper_looper.scd
  SuperCollider looper with monome64 control (mlr-style)

  Setup:
    - 4 tracks, each with its own buffer
    - monome64: rows 0-3 = tracks, columns 0-7 = playhead position (8 segments)
    - Row 4: track record arm buttons (col 0-3)
    - Row 5: overdub / clear per track (col 0-3 overdub, col 4-7 clear)
    - Row 6: global transport (col 0 = play/stop, col 1 = record all, col 7 = clear all)
    - Audio input: default hardware input (guitar, mic, etc.)

  Requires: serialosc (for monome communication via OSC)
  Default serialosc port: 12002 (sending), local receive port: 57121
*/

(
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
~numTracks    = 4;
~numCols      = 8;         // monome64 columns used for position (row 0-3)
~loopDuration = 4.0;       // seconds per loop (set before starting)
~inputBus     = 0;         // hardware input channel
~outBus       = 0;         // hardware output channel
~sampleRate   = 44100;
~bufFrames    = (~loopDuration * ~sampleRate).asInteger;

// monome OSC ports
~monomeReceivePort = 57121; // local port this app listens on
~monomeSendPort    = 12002; // serialosc port (auto-updated to device port at boot)
~monomeAddr        = NetAddr("127.0.0.1", ~monomeSendPort);
~monomePrefix      = "/monome"; // change to match your device prefix
~monomeConnected   = false;    // set true once serialosc reports a device

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
~buffers      = Array.newClear(~numTracks);
~recNodes     = Array.newClear(~numTracks);
~playNodes    = Array.newClear(~numTracks);
~isRecording  = Array.fill(~numTracks, false);
~isOverdub    = Array.fill(~numTracks, false);
~isPlaying    = Array.fill(~numTracks, true);
~playPos      = Array.fill(~numTracks, 0);   // current playhead segment 0-7
~loopStart    = Array.fill(~numTracks, 0);   // loop start segment 0-7
~loopEnd      = Array.fill(~numTracks, 7);   // loop end   segment 0-7
~transport    = false; // global play state
~ledState     = Array.fill(8, { Array.fill(8, 0) }); // [row][col]

// ---------------------------------------------------------------------------
// Allocate Buffers
// ---------------------------------------------------------------------------
~allocBuffers = {
    ~numTracks.do { |i|
        ~buffers[i] = Buffer.alloc(s, ~bufFrames, 1);
    };
    "Buffers allocated (% tracks, % sec each)".format(~numTracks, ~loopDuration).postln;
};

// ---------------------------------------------------------------------------
// SynthDefs
// ---------------------------------------------------------------------------
~loadSynthDefs = {
    // Record into buffer (overdub-capable)
    SynthDef(\loopRec, { |bufnum, inputBus = 0, startFrame = 0, endFrame = 44100,
                           preLevel = 1.0, recLevel = 1.0, gate = 1|
        var input = SoundIn.ar(inputBus);
        var phase = Phasor.ar(0, 1, startFrame, endFrame, startFrame);
        var rec   = RecordBuf.ar(input, bufnum, offset: startFrame,
                                 recLevel: recLevel, preLevel: preLevel,
                                 run: gate, loop: 1);
        FreeSelf.kr(1 - gate);
    }).add;

    // Play back buffer with variable start/end (stereo output)
    SynthDef(\loopPlay, { |bufnum, outBus = 0, startFrame = 0, endFrame = 44100,
                           amp = 0.8, gate = 1|
        var env   = EnvGen.kr(Env.asr(0.005, 1, 0.005), gate, doneAction: 2);
        var phase = Phasor.ar(0, BufRateScale.kr(bufnum), startFrame, endFrame, startFrame);
        var sig   = BufRd.ar(1, bufnum, phase);
        Out.ar(outBus, (sig * amp * env).dup(2));
    }).add;

    // Passthrough: monitor live input (stereo output)
    SynthDef(\inputMonitor, { |inputBus = 0, outBus = 0, amp = 0.5|
        Out.ar(outBus, SoundIn.ar(inputBus).dup(2) * amp);
    }).add;

    s.sync;
    "SynthDefs loaded".postln;
};

// ---------------------------------------------------------------------------
// Frame helpers
// ---------------------------------------------------------------------------
~segToFrame = { |seg| (seg / ~numCols * ~bufFrames).asInteger };
~frameToSeg = { |frame| (frame / ~bufFrames * ~numCols).asInteger.clip(0, ~numCols - 1) };

// ---------------------------------------------------------------------------
// monome LED helpers
// ---------------------------------------------------------------------------
~ledSet = { |row, col, val|
    ~ledState[row][col] = val;
    ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/set", col, row, val);
};

~ledRow = { |row, vals|
    // build bitmask with doWithIndex so the column index i is available
    var mask = 0;
    vals.doWithIndex { |v, i| mask = mask | (v.asInteger << i) };
    vals.doWithIndex { |v, i| ~ledState[row][i] = v };
    ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/row", 0, row, mask);
};

~clearLeds = {
    ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 0);
    ~ledState = Array.fill(8, { Array.fill(8, 0) });
};

// ---------------------------------------------------------------------------
// Display update
// ---------------------------------------------------------------------------
~updateDisplay = {
    // declare all vars at top of block
    var recRow = Array.fill(~numCols, 0);
    var odRow  = Array.fill(~numCols, 0);
    var trRow  = Array.fill(~numCols, 0);

    // Rows 0-3: mlr-style — playhead LED always on; blinks through columns when playing
    ~numTracks.do { |track|
        var row = Array.fill(~numCols, 0);
        row[~playPos[track]] = 1;
        ~ledRow.(track, row);
    };

    // Row 4: record arm indicators (col 0-3)
    ~numTracks.do { |t| recRow[t] = if(~isRecording[t]) { 1 } { 0 } };
    ~ledRow.(4, recRow);

    // Row 5: overdub (col 0-3) and clear (col 4-7)
    ~numTracks.do { |t|
        odRow[t]     = if(~isOverdub[t]) { 1 } { 0 };
        odRow[t + 4] = 0;
    };
    ~ledRow.(5, odRow);

    // Row 6: transport
    trRow[0] = if(~transport) { 1 } { 0 };
    ~ledRow.(6, trRow);
};

// ---------------------------------------------------------------------------
// Playhead tracker
// ---------------------------------------------------------------------------
~playheadRoutine = nil;

~startPlayheadTracker = {
    var segDur = ~loopDuration / ~numCols;
    ~playheadRoutine !? { ~playheadRoutine.stop };
    ~playheadRoutine = Routine({
        loop {
            if(~transport) {
                ~numTracks.do { |t|
                    var newPos;
                    if(~isPlaying[t]) {
                        newPos = ~playPos[t] + 1;
                        if(newPos > ~loopEnd[t]) { newPos = ~loopStart[t] };
                        ~playPos[t] = newPos;
                    };
                };
                ~updateDisplay.();
            };
            segDur.wait;
        };
    }).play;
};

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------
~startTransport = {
    ~transport = true;
    ~numTracks.do { |t|
        var startF = ~segToFrame.(~loopStart[t]);
        var endF   = ~segToFrame.(~loopEnd[t] + 1);
        if(~playNodes[t].notNil) { ~playNodes[t].free };
        ~playNodes[t] = Synth(\loopPlay, [
            \bufnum,     ~buffers[t],
            \outBus,     ~outBus,
            \startFrame, startF,
            \endFrame,   endF,
            \amp,        0.8
        ]);
        ~playPos[t] = ~loopStart[t];
    };
    ~startPlayheadTracker.();
    ~updateDisplay.();
    "Transport started".postln;
};

~stopTransport = {
    ~transport = false;
    ~playheadRoutine !? { ~playheadRoutine.stop };
    ~numTracks.do { |t|
        ~playNodes[t] !? { ~playNodes[t].set(\gate, 0) };
        ~playNodes[t] = nil;
        ~stopRecording.(t);
    };
    ~updateDisplay.();
    "Transport stopped".postln;
};

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------
~startRecording = { |track|
    var startF = ~segToFrame.(~loopStart[track]);
    var endF   = ~segToFrame.(~loopEnd[track] + 1);
    var preL   = if(~isOverdub[track]) { 1.0 } { 0.0 };
    ~stopRecording.(track);
    ~isRecording[track] = true;
    ~recNodes[track] = Synth(\loopRec, [
        \bufnum,     ~buffers[track],
        \inputBus,   ~inputBus,
        \startFrame, startF,
        \endFrame,   endF,
        \preLevel,   preL,
        \recLevel,   1.0,
        \gate,       1
    ]);
    "Track % recording (overdub: %)".format(track, ~isOverdub[track]).postln;
    ~updateDisplay.();
};

~stopRecording = { |track|
    if(~isRecording[track]) {
        ~recNodes[track] !? { |n| n.set(\gate, 0) };
        ~recNodes[track]    = nil;
        ~isRecording[track] = false;
        ~updateDisplay.();
        "Track % recording stopped".format(track).postln;
    };
};

~clearTrack = { |track|
    ~stopRecording.(track);
    ~buffers[track].zero;
    "Track % cleared".format(track).postln;
    ~updateDisplay.();
};

// ---------------------------------------------------------------------------
// serialosc device registration
// ---------------------------------------------------------------------------
// Queries serialosc (port 12002) for connected monome devices, then tells
// the device to send button events to our receive port and sets the prefix.
// ~monomeAddr is updated automatically when the device responds.
//
// If auto-discovery fails (no "monome found" message in the SC console),
// call ~connectMonome.(port) manually with the port from monome_setup.scd.
~connectMonome = { |devicePort|
    var deviceAddr = NetAddr("127.0.0.1", devicePort);
    ~monomeAddr      = deviceAddr;
    ~monomeConnected = true;
    deviceAddr.sendMsg("/sys/port",   ~monomeReceivePort);
    deviceAddr.sendMsg("/sys/prefix", ~monomePrefix);
    // 50 ms: let /sys/prefix take effect, then flash ALL LEDs on as a connection test
    SystemClock.sched(0.05, {
        ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 1);
        nil
    });
    // 400 ms: switch to real display state
    SystemClock.sched(0.4, { ~updateDisplay.(); nil });
    "=== monome connected on port % (sending to this port) ===".format(devicePort).postln;
    "    If ALL LEDs flash briefly the connection is good.".postln;
};

~setupMonome = {
    // explicitly open the receive port — recvPort: in OSCdef alone is not
    // always sufficient in all SC versions
    thisProcess.openUDPPort(~monomeReceivePort);

    OSCdef(\serialoscDevice, { |msg|
        var devicePort = msg[3].asInteger;
        "monome found: type=%, port=%".format(msg[2], devicePort).postln;
        ~connectMonome.(devicePort);
        OSCdef(\serialoscDevice).free;
    }, "/serialosc/device", recvPort: ~monomeReceivePort);

    // query now, and retry once after 2 s in case serialosc is slow to respond
    fork {
        NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list", "127.0.0.1", ~monomeReceivePort);
        "querying serialosc for monome devices (port %)...".format(~monomeReceivePort).postln;
        2.0.wait;
        if(~monomeConnected.not) {
            "retrying serialosc query...".postln;
            NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list", "127.0.0.1", ~monomeReceivePort);
            2.0.wait;
            if(~monomeConnected.not) {
                "WARNING: no monome device found. Run monome_setup.scd to get the device port,".postln;
                "then call:  ~connectMonome.(port)  to connect manually.".postln;
            };
        };
    };
};

// ---------------------------------------------------------------------------
// monome OSC handlers
// ---------------------------------------------------------------------------
~setupOSC = {
    OSCdef(\monomeGrid, { |msg|
        var col   = msg[1].asInteger;
        var row   = msg[2].asInteger;
        var state = msg[3].asInteger; // 1 = down, 0 = up

        if(state == 1) {
            case
            // Rows 0-3: mlr-style — jump playhead to pressed column
            { row < ~numTracks } {
                var track  = row;
                var startF = ~segToFrame.(col);
                var endF   = ~bufFrames;      // always play to end of buffer
                ~playPos[track]    = col;
                ~loopStart[track]  = col;
                ~loopEnd[track]    = ~numCols - 1;
                if(~transport && ~isPlaying[track]) {
                    ~playNodes[track] !? { ~playNodes[track].set(\gate, 0) };
                    ~playNodes[track] = Synth(\loopPlay, [
                        \bufnum,     ~buffers[track],
                        \outBus,     ~outBus,
                        \startFrame, startF,
                        \endFrame,   endF,
                        \amp,        0.8
                    ]);
                };
                if(~isRecording[track] && ~recNodes[track].notNil) {
                    ~recNodes[track].set(\startFrame, startF, \endFrame, endF);
                };
                ~updateDisplay.();
            }

            // Row 4: record arm (col 0-3)
            { (row == 4) && (col < ~numTracks) } {
                var track = col;
                if(~isRecording[track]) {
                    ~stopRecording.(track);
                } {
                    ~startRecording.(track);
                };
            }

            // Row 5: overdub toggle (col 0-3) / clear (col 4-7)
            { row == 5 } {
                if(col < ~numTracks) {
                    ~isOverdub[col] = ~isOverdub[col].not;
                    "Track % overdub: %".format(col, ~isOverdub[col]).postln;
                    ~updateDisplay.();
                } {
                    if((col >= 4) && (col < (4 + ~numTracks))) {
                        ~clearTrack.(col - 4);
                    };
                };
            }

            // Row 6: global transport
            { row == 6 } {
                case
                { col == 0 } {
                    if(~transport) { ~stopTransport.() } { ~startTransport.() };
                }
                { col == 1 } {
                    ~numTracks.do { |t| ~startRecording.(t) };
                }
                { col == 7 } {
                    ~numTracks.do { |t| ~clearTrack.(t) };
                };
            };
        };
    }, ~monomePrefix ++ "/grid/key", recvPort: ~monomeReceivePort);

    "OSC handlers registered on port %".format(~monomeReceivePort).postln;
};

// ---------------------------------------------------------------------------
// Boot sequence
// ---------------------------------------------------------------------------
s.waitForBoot({
    ~loadSynthDefs.();
    s.sync;
    ~allocBuffers.();
    s.sync;
    ~setupOSC.();
    ~setupMonome.();   // auto-discover device, set /sys/port + /sys/prefix, update ~monomeAddr
    ~updateDisplay.(); // initial draw (will re-draw again after device responds)

    ~monitorNode = Synth(\inputMonitor, [\inputBus, ~inputBus, \outBus, ~outBus, \amp, 0.5]);

    "=== super_duper_looper ready ===".postln;
    "monome64 prefix: %  |  receive port: %".format(~monomePrefix, ~monomeReceivePort).postln;
    "Loop duration: % sec  |  Buffer: % frames".format(~loopDuration, ~bufFrames).postln;
    "".postln;
    "--- monome64 layout ---".postln;
    "  Row 0-3 : loop range & playhead per track".postln;
    "  Row 4   : col 0-3 = record arm".postln;
    "  Row 5   : col 0-3 = overdub, col 4-7 = clear track".postln;
    "  Row 6   : col 0 = play/stop, col 1 = rec all, col 7 = clear all".postln;
});
)

// ---------------------------------------------------------------------------
// Cleanup — run this block separately to tear down
// ---------------------------------------------------------------------------
(
~stopTransport.();
~monitorNode !? { ~monitorNode.free };
OSCdef(\monomeGrid).free;
~buffers.do { |b| b !? { b.free } };
~clearLeds.();
"super_duper_looper stopped".postln;
)
