/*
  super_duper_looper.scd  v2
  SuperCollider looper with monome64 control (mlr-style)

  v2 additions:
    Phase 1 — Global effects chain: reverb / delay / bit crush
    Phase 2 — Per-track granular mode (GrainBuf, slow-scan + jitter)

  Signal flow:
    [loopPlay / grainPlay] ──► ~mixBus (mono) ──► [globalFX] ──► hardware out (stereo)
    [inputMonitor]         ──► ~mixBus  (goes through FX too)

  monome64 layout:
    Row 0-3 : loop range & playhead per track
    Row 4   : col 0-3 = record arm
    Row 5   : col 0-3 = overdub, col 4-7 = clear track
    Row 6   : col 0 = play/stop, col 1 = rec all, col 7 = clear all
    Row 7   : col 0-3 = granular mode per track
              col 4   = reverb on/off
              col 5   = delay on/off
              col 6   = bit crush on/off
*/

(
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
~numTracks    = 4;
~numCols      = 8;
~loopDuration = 4.0;       // seconds per loop
~inputBus     = 0;
~outBus       = 0;
~sampleRate   = 44100;
~bufFrames    = (~loopDuration * ~sampleRate).asInteger;

~monomeReceivePort = 57121;
~monomeSendPort    = 12002;
~monomeAddr        = NetAddr("127.0.0.1", ~monomeSendPort);
~monomePrefix      = "/monome";
~monomeConnected   = false;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
~buffers     = Array.newClear(~numTracks);
~recNodes    = Array.newClear(~numTracks);
~playNodes   = Array.newClear(~numTracks);
~isRecording = Array.fill(~numTracks, false);
~isOverdub   = Array.fill(~numTracks, false);
~isPlaying   = Array.fill(~numTracks, true);
~isGranular  = Array.fill(~numTracks, false);   // Phase 2: granular mode per track
~playPos     = Array.fill(~numTracks, 0);
~loopStart   = Array.fill(~numTracks, 0);
~loopEnd     = Array.fill(~numTracks, 7);
~transport   = false;
~ledState    = Array.fill(8, { Array.fill(8, 0) });
~heldCol     = Array.fill(~numTracks, nil);
~rangeSet    = Array.fill(~numTracks, false);

// Phase 1: effects state
~fxReverb    = false;
~fxDelay     = false;
~fxCrush     = false;
~fxNode      = nil;     // global FX synth
~mixBus      = nil;     // mono mix bus

// Phase 2: granular parameters (adjustable at runtime)
~grainRate   = 20;      // grains per second
~grainDur    = 0.08;    // grain duration in seconds
~grainSpread = 0.06;    // position jitter as fraction of loop region
~grainPitch  = 1.0;     // pitch ratio (1.0 = no shift)

// Synth ordering groups
~playGroup   = nil;
~fxGroup     = nil;

// ---------------------------------------------------------------------------
// Allocate buffers + mix bus
// ---------------------------------------------------------------------------
~allocBuffers = {
    ~mixBus = Bus.audio(s, 1);
    ~numTracks.do { |i|
        ~buffers[i] = Buffer.alloc(s, ~bufFrames, 1);
    };
    "Buffers allocated (% tracks × % sec)  mix bus: %"
        .format(~numTracks, ~loopDuration, ~mixBus.index).postln;
};

// ---------------------------------------------------------------------------
// SynthDefs
// ---------------------------------------------------------------------------
~loadSynthDefs = {

    // Record into buffer (overdub-capable) ──────────────────────────────────
    SynthDef(\loopRec, { |bufnum, inputBus = 0, startFrame = 0, endFrame = 44100,
                           preLevel = 1.0, recLevel = 1.0, gate = 1|
        var input = SoundIn.ar(inputBus);
        RecordBuf.ar(input, bufnum, offset: startFrame,
                     recLevel: recLevel, preLevel: preLevel,
                     run: gate, loop: 1);
        FreeSelf.kr(1 - gate);
    }).add;

    // Standard playback → mono mix bus ──────────────────────────────────────
    SynthDef(\loopPlay, { |bufnum, outBus = 0, startFrame = 0, endFrame = 44100,
                           amp = 0.7, gate = 1|
        var env   = EnvGen.kr(Env.asr(0.005, 1, 0.005), gate, doneAction: 2);
        var phase = Phasor.ar(0, BufRateScale.kr(bufnum), startFrame, endFrame, startFrame);
        var sig   = BufRd.ar(1, bufnum, phase);
        Out.ar(outBus, sig * amp * env);   // mono output
    }).add;

    // Granular playback → mono mix bus  (Phase 2) ────────────────────────────
    // Slow-scans through the active loop region, adding per-grain position jitter.
    SynthDef(\grainPlay, { |bufnum, outBus = 0,
                             startFrame = 0, endFrame = 44100,
                             grainRate = 20, grainDur = 0.08,
                             spread = 0.06, pitchRatio = 1.0,
                             amp = 0.7, gate = 1|
        var env      = EnvGen.kr(Env.asr(0.03, 1, 0.08), gate, doneAction: 2);
        var bufFrames = BufFrames.kr(bufnum);
        var loopLen   = (endFrame - startFrame) / bufFrames;          // 0..1 fraction
        var startPos  = startFrame / bufFrames;
        var endPos    = endFrame   / bufFrames;
        // Scan once per loop duration (kr sawtooth, resets at endPos)
        var scanFreq  = 1.0 / max(loopLen * BufDur.kr(bufnum), 0.01);
        var scanPos   = LFSaw.kr(scanFreq).range(startPos, endPos);
        // Random jitter scaled to the loop region
        var jitter    = LFNoise1.kr(grainRate) * spread * loopLen;
        var pos       = (scanPos + jitter).clip(0, 1);
        var trig      = Impulse.ar(grainRate);
        var sig       = GrainBuf.ar(1, trig, grainDur, bufnum, pitchRatio, pos);
        Out.ar(outBus, sig * amp * env);
    }).add;

    // Global FX chain: reads mono mix bus → stereo out  (Phase 1) ───────────
    //   crushAmt  0→clean,  1→4-bit crunch
    //   delayAmt  0→dry,    0.5→50% delay mix
    //   reverbAmt 0→dry,    1→full FreeVerb
    SynthDef(\globalFX, { |inBus, outBus = 0,
                           reverbAmt = 0.0,
                           delayAmt  = 0.0, delayTime = 0.35, delayFeedback = 0.5,
                           crushAmt  = 0.0,
                           amp = 1.0|
        // All vars declared upfront (SC requires var declarations before any statements)
        var sig, step, crushed, delayed, revved;
        sig = In.ar(inBus, 1);

        // Bit crush ──────────────────────────────────────────────────────────
        step    = 1.0 / 16;   // ≈ 4-bit quantisation when fully engaged
        crushed = (sig / step).round * step;
        sig     = XFade2.ar(sig, crushed, crushAmt * 2 - 1);

        // Delay (CombL with feedback, parallel mix) ──────────────────────────
        delayed = CombL.ar(sig, 2.0, delayTime, delayFeedback * 10);
        sig     = sig + (delayed * delayAmt * 0.7);

        // Reverb (FreeVerb) ──────────────────────────────────────────────────
        revved = FreeVerb.ar(sig, mix: 0.7, room: 0.85, damp: 0.2);
        sig    = XFade2.ar(sig, revved, reverbAmt * 2 - 1);

        Out.ar(outBus, sig.dup(2) * amp);
    }).add;

    // Input monitor → mix bus (processed by FX chain) ───────────────────────
    SynthDef(\inputMonitor, { |inputBus = 0, outBus = 0, amp = 0.5|
        Out.ar(outBus, SoundIn.ar(inputBus) * amp);
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
// Restart playback for one track (respects granular mode)
// ---------------------------------------------------------------------------
~restartPlay = { |track|
    var startF = ~segToFrame.(~loopStart[track]);
    var endF   = ~segToFrame.(~loopEnd[track] + 1);
    ~playPos[track] = ~loopStart[track];
    if(~transport && ~isPlaying[track]) {
        ~playNodes[track] !? { ~playNodes[track].set(\gate, 0) };
        if(~isGranular[track]) {
            ~playNodes[track] = Synth(\grainPlay, [
                \bufnum,     ~buffers[track],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \grainRate,  ~grainRate,
                \grainDur,   ~grainDur,
                \spread,     ~grainSpread,
                \pitchRatio, ~grainPitch,
                \amp,        0.7
            ], target: ~playGroup);
        } {
            ~playNodes[track] = Synth(\loopPlay, [
                \bufnum,     ~buffers[track],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \amp,        0.7
            ], target: ~playGroup);
        };
    };
};

// ---------------------------------------------------------------------------
// LED helpers
// ---------------------------------------------------------------------------
~ledSet = { |row, col, val|
    ~ledState[row][col] = val;
    ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/set", col, row, val);
};

~ledRow = { |row, vals|
    var mask = 0;
    vals.do { |v, i| mask = mask | (v.asInteger << i) };
    vals.do { |v, i| ~ledState[row][i] = v };
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
    var recRow = Array.fill(~numCols, 0);
    var odRow  = Array.fill(~numCols, 0);
    var trRow  = Array.fill(~numCols, 0);
    var fxRow  = Array.fill(~numCols, 0);

    // Rows 0-3: loop range lit, playhead = dark spot
    ~numTracks.do { |track|
        var row = Array.fill(~numCols, { |col|
            if((col >= ~loopStart[track]) && (col <= ~loopEnd[track])) {
                if(col == ~playPos[track]) { 0 } { 1 }
            } { 0 }
        });
        ~ledRow.(track, row);
    };

    // Row 4: record arm
    ~numTracks.do { |t| recRow[t] = if(~isRecording[t]) { 1 } { 0 } };
    ~ledRow.(4, recRow);

    // Row 5: overdub (col 0-3); clear buttons always dark
    ~numTracks.do { |t| odRow[t] = if(~isOverdub[t]) { 1 } { 0 } };
    ~ledRow.(5, odRow);

    // Row 6: transport
    trRow[0] = if(~transport) { 1 } { 0 };
    ~ledRow.(6, trRow);

    // Row 7: granular per track (col 0-3) + effects (col 4-6)
    ~numTracks.do { |t| fxRow[t] = if(~isGranular[t]) { 1 } { 0 } };
    fxRow[4] = if(~fxReverb) { 1 } { 0 };
    fxRow[5] = if(~fxDelay)  { 1 } { 0 };
    fxRow[6] = if(~fxCrush)  { 1 } { 0 };
    ~ledRow.(7, fxRow);
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
                    if(~isPlaying[t]) {
                        var newPos = ~playPos[t] + 1;
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
        ~playNodes[t] !? { ~playNodes[t].free };
        if(~isGranular[t]) {
            ~playNodes[t] = Synth(\grainPlay, [
                \bufnum,     ~buffers[t],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \grainRate,  ~grainRate,
                \grainDur,   ~grainDur,
                \spread,     ~grainSpread,
                \pitchRatio, ~grainPitch,
                \amp,        0.7
            ], target: ~playGroup);
        } {
            ~playNodes[t] = Synth(\loopPlay, [
                \bufnum,     ~buffers[t],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \amp,        0.7
            ], target: ~playGroup);
        };
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
    ], target: ~playGroup);
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
// Toggle granular mode for one track  (Phase 2)
// ---------------------------------------------------------------------------
~toggleGranular = { |track|
    ~isGranular[track] = ~isGranular[track].not;
    "Track % granular: %".format(track, ~isGranular[track]).postln;
    ~restartPlay.(track);     // swap synth immediately if transport is running
    ~updateDisplay.();
};

// ---------------------------------------------------------------------------
// Apply current effects state to the global FX synth  (Phase 1)
// ---------------------------------------------------------------------------
~updateFX = {
    ~fxNode !? {
        ~fxNode.set(
            \reverbAmt, if(~fxReverb) { 1.0 } { 0.0 },
            \delayAmt,  if(~fxDelay)  { 0.5 } { 0.0 },
            \crushAmt,  if(~fxCrush)  { 1.0 } { 0.0 }
        );
    };
};

// ---------------------------------------------------------------------------
// serialosc device registration
// ---------------------------------------------------------------------------
~connectMonome = { |devicePort|
    var deviceAddr = NetAddr("127.0.0.1", devicePort);
    ~monomeAddr      = deviceAddr;
    ~monomeConnected = true;
    deviceAddr.sendMsg("/sys/port",   ~monomeReceivePort);
    deviceAddr.sendMsg("/sys/prefix", ~monomePrefix);
    SystemClock.sched(0.05, {
        ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 1); nil
    });
    SystemClock.sched(0.4, {
        ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 0);
        ~updateDisplay.(); nil
    });
    "=== monome connected on port % ===".format(devicePort).postln;
    "    Brief LED flash = connection confirmed.".postln;
};

~setupMonome = {
    thisProcess.openUDPPort(~monomeReceivePort);
    OSCdef(\serialoscDevice, { |msg|
        var devicePort = msg[3].asInteger;
        "monome found: type=%, port=%".format(msg[2], devicePort).postln;
        ~connectMonome.(devicePort);
        OSCdef(\serialoscDevice).free;
    }, "/serialosc/device", recvPort: ~monomeReceivePort);
    fork {
        NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list", "127.0.0.1", ~monomeReceivePort);
        "querying serialosc...".postln;
        2.0.wait;
        if(~monomeConnected.not) {
            "retrying serialosc query...".postln;
            NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list", "127.0.0.1", ~monomeReceivePort);
            2.0.wait;
            if(~monomeConnected.not) {
                "WARNING: no monome found. Run monome_setup.scd then call ~connectMonome.(port).".postln;
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
        var state = msg[3].asInteger;   // 1 = down, 0 = up

        case

        // Rows 0-3: mlr-style loop range ─────────────────────────────────────
        { row < ~numTracks } {
            var track = row;
            if(state == 1) {
                if(~heldCol[track].isNil) {
                    ~heldCol[track]   = col;
                    ~loopStart[track] = col;
                    ~loopEnd[track]   = ~numCols - 1;
                    ~restartPlay.(track);
                } {
                    var a = ~heldCol[track];
                    ~loopStart[track] = min(a, col);
                    ~loopEnd[track]   = max(a, col);
                    ~rangeSet[track]  = true;
                    ~restartPlay.(track);
                };
                ~updateDisplay.();
            } {
                if(~heldCol[track] == col) {
                    ~heldCol[track]  = nil;
                    ~rangeSet[track] = false;
                };
            };
        }

        // Row 4: record arm ───────────────────────────────────────────────────
        { (state == 1) && (row == 4) && (col < ~numTracks) } {
            if(~isRecording[col]) { ~stopRecording.(col) } { ~startRecording.(col) };
        }

        // Row 5: overdub (col 0-3) / clear track (col 4-7) ───────────────────
        { (state == 1) && (row == 5) } {
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

        // Row 6: global transport ─────────────────────────────────────────────
        { (state == 1) && (row == 6) } {
            case
            { col == 0 } { if(~transport) { ~stopTransport.() } { ~startTransport.() } }
            { col == 1 } { ~numTracks.do { |t| ~startRecording.(t) } }
            { col == 7 } { ~numTracks.do { |t| ~clearTrack.(t) } };
        }

        // Row 7: granular (col 0-3) + effects (col 4-6) ── Phase 1 + 2 ───────
        { (state == 1) && (row == 7) } {
            case
            { col < ~numTracks } {
                ~toggleGranular.(col);
            }
            { col == 4 } {
                ~fxReverb = ~fxReverb.not;
                ~updateFX.();
                ~updateDisplay.();
                "Reverb: %".format(~fxReverb).postln;
            }
            { col == 5 } {
                ~fxDelay = ~fxDelay.not;
                ~updateFX.();
                ~updateDisplay.();
                "Delay: %".format(~fxDelay).postln;
            }
            { col == 6 } {
                ~fxCrush = ~fxCrush.not;
                ~updateFX.();
                ~updateDisplay.();
                "BitCrush: %".format(~fxCrush).postln;
            };
        };

    }, ~monomePrefix ++ "/grid/key", recvPort: ~monomeReceivePort);

    "OSC handlers registered on port %".format(~monomeReceivePort).postln;
};

// ---------------------------------------------------------------------------
// Boot sequence
// ---------------------------------------------------------------------------
s.waitForBoot({
    // Groups: play synths run before FX synth
    ~playGroup = Group.new(s);
    ~fxGroup   = Group.after(~playGroup);

    ~loadSynthDefs.();
    s.sync;
    ~allocBuffers.();
    s.sync;

    // Global FX synth (always running; updated via ~updateFX)
    ~fxNode = Synth(\globalFX, [
        \inBus,     ~mixBus,
        \outBus,    ~outBus,
        \reverbAmt, 0.0,
        \delayAmt,  0.0,
        \crushAmt,  0.0
    ], target: ~fxGroup);

    // Input monitor → mix bus (live input processed by FX chain)
    ~monitorNode = Synth(\inputMonitor, [
        \inputBus, ~inputBus,
        \outBus,   ~mixBus,
        \amp,      0.5
    ], target: ~playGroup);

    ~setupOSC.();
    ~setupMonome.();
    ~updateDisplay.();

    "".postln;
    "=== super_duper_looper v2 ready ===".postln;
    "monome64 prefix: %  |  receive port: %".format(~monomePrefix, ~monomeReceivePort).postln;
    "Loop duration: % sec  |  %k frames".format(~loopDuration, (~bufFrames / 1000).round).postln;
    "".postln;
    "--- monome64 layout ---".postln;
    "  Row 0-3 : loop range & playhead per track".postln;
    "  Row 4   : col 0-3 = record arm".postln;
    "  Row 5   : col 0-3 = overdub, col 4-7 = clear track".postln;
    "  Row 6   : col 0 = play/stop, col 1 = rec all, col 7 = clear all".postln;
    "  Row 7   : col 0-3 = granular mode per track".postln;
    "            col 4 = reverb, col 5 = delay, col 6 = bit crush".postln;
    "".postln;
    "--- granular defaults (change anytime) ---".postln;
    "  ~grainRate   = 20   // grains/sec".postln;
    "  ~grainDur    = 0.08 // grain size in sec".postln;
    "  ~grainSpread = 0.06 // position jitter".postln;
    "  ~grainPitch  = 1.0  // pitch ratio".postln;
});
)

// ---------------------------------------------------------------------------
// Cleanup — evaluate this block to tear down
// ---------------------------------------------------------------------------
(
~stopTransport.();
~playheadRoutine !? { ~playheadRoutine.stop };
~monitorNode !? { ~monitorNode.free };
~fxNode      !? { ~fxNode.free };
~playGroup   !? { ~playGroup.free };
~fxGroup     !? { ~fxGroup.free };
~mixBus      !? { ~mixBus.free };
OSCdef(\monomeGrid).free;
~buffers.do { |b| b !? { b.free } };
~clearLeds.();
"super_duper_looper stopped".postln;
)

// ---------------------------------------------------------------------------
// Keyboard shortcuts — evaluate this block separately after boot
// SC window must have focus for keys to register.
// ---------------------------------------------------------------------------
(
var w = Window("sdl keys", Rect(10, 600, 220, 30)).front;
w.view.keyDownAction = { |view, char|
    switch(char,
        // transport
        $p, { if(~transport) { ~stopTransport.() } { ~startTransport.() } },
        // record arm T0-T3
        $1, { if(~isRecording[0]) { ~stopRecording.(0) } { ~startRecording.(0) } },
        $2, { if(~isRecording[1]) { ~stopRecording.(1) } { ~startRecording.(1) } },
        $3, { if(~isRecording[2]) { ~stopRecording.(2) } { ~startRecording.(2) } },
        $4, { if(~isRecording[3]) { ~stopRecording.(3) } { ~startRecording.(3) } },
        // overdub T0-T3
        $q, { ~isOverdub[0] = ~isOverdub[0].not; ~updateDisplay.() },
        $w, { ~isOverdub[1] = ~isOverdub[1].not; ~updateDisplay.() },
        $e, { ~isOverdub[2] = ~isOverdub[2].not; ~updateDisplay.() },
        $r, { ~isOverdub[3] = ~isOverdub[3].not; ~updateDisplay.() },
        // clear T0-T3 / all
        $z, { ~clearTrack.(0) },
        $x, { ~clearTrack.(1) },
        $v, { ~clearTrack.(2) },
        $b, { ~clearTrack.(3) },
        $c, { ~numTracks.do { |t| ~clearTrack.(t) } },
        // granular mode T0-T3
        $a, { ~toggleGranular.(0) },
        $s, { ~toggleGranular.(1) },
        $d, { ~toggleGranular.(2) },
        $f, { ~toggleGranular.(3) },
        // effects
        $[, { ~fxReverb = ~fxReverb.not; ~updateFX.(); ~updateDisplay.();
              "Reverb: %".format(~fxReverb).postln },
        $], { ~fxDelay  = ~fxDelay.not;  ~updateFX.(); ~updateDisplay.();
              "Delay: %".format(~fxDelay).postln },
        $\\,{ ~fxCrush  = ~fxCrush.not;  ~updateFX.(); ~updateDisplay.();
              "BitCrush: %".format(~fxCrush).postln }
    );
};
"Keyboard shortcuts active (keep 'sdl keys' window focused)".postln;
"  p     : play/stop".postln;
"  1-4   : record arm T0-T3".postln;
"  q/w/e/r : overdub T0-T3".postln;
"  z/x/v/b : clear T0-T3   c = clear all".postln;
"  a/s/d/f : granular mode T0-T3".postln;
"  [ ] \\ : reverb / delay / bit crush".postln;
)
