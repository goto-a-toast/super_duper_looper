/*
  ambient_machine.scd
  Autonomous ambient music generator for monome64 + SuperCollider

  Concept
    - Source pool: WAV/AIF files from ./samples/ + live input rolling 30 s buffer
      + 4 on-demand snapshot buffers
    - 4 voice types, scheduled randomly by an autonomous Routine:
      \aGran   : granular cloud
      \aFreeze : spectral freeze
      \aRev    : reverse playback
      \aPitch  : pitch-shifted playback (octave down ↔ up)
      \aDrone  : sustained spectral-freeze drone (toggled, gate-released)
    - Global FX chain: long delay (3.5 s, feedback) → big reverb (+ optional
      octave-up shimmer feedback) → soft saturation
    - monome64 grid: every one of the 64 buttons does something —
      rows 0-3 double as activity meters AND playable pads (col = buffer position),
      plus voice enables, pitch palettes, density, burst, source bias, transport,
      snapshot capture/audition, drone, FX toggles, shimmer, master volume, panic.

  Inspired by rconstanzo's the-party-van, simplified for hands-off operation.

  Requires: serialosc, monome64.  Live input expected on hardware input 0.
*/

(
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
~aNumVoices         = 4;
~aNumCols           = 8;
~aInputBus          = 0;
~aOutBus            = 0;
~aLiveRollSeconds   = 30;
~aSnapshotSeconds   = 4;
~aMaxConcurrent     = 12;             // safety cap
// sample folder: local Mac path first, fallback to ./samples next to this file
~aSamplePath        = "/Users/gotouakira/Desktop/ClaudeWork/super_duper_looper/samples";
if(File.exists(~aSamplePath).not) {
    thisProcess.nowExecutingPath !? { |p|
        ~aSamplePath = PathName(p).parentPath +/+ "samples";
    };
};

// monome OSC ports (same convention as super_duper_looper.scd)
~aMonomeReceivePort = 57122;          // distinct from the looper's 57121
~aMonomeSendPort    = 12002;
~aMonomeAddr        = NetAddr("127.0.0.1", ~aMonomeSendPort);
~aMonomePrefix      = "/monome";
~aMonomeConnected   = false;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
~aTransport         = false;          // engine on/off (row 6 col 0)
~density            = 2;              // 1 slow, 2 med, 3 dense
~sourceBias         = 4;              // 0..7 (0 = all live, 7 = all sample)
~enabledVoiceTypes  = [\aGran, \aFreeze, \aRev, \aPitch];
~allVoiceTypes      = [\aGran, \aFreeze, \aRev, \aPitch];
~voiceTypeLabels    = ['G', 'F', 'R', 'P'];

// pitch palettes — rate sets used by \aPitch and \aGran (row 4 col 4-7)
~pitchPalettes      = [
    [0.5, 0.75, 1.0, 1.5, 2.0],       // free
    [0.5, 1.0, 1.0, 2.0],             // octaves
    [0.667, 1.0, 1.0, 1.5],           // fifths
    [1.0, 2.0, 2.0, 4.0]              // shimmer (upward)
];
~paletteNames       = ["free", "octaves", "fifths", "shimmer"];
~palette            = 0;

~sourcePool         = [];             // loaded sample Buffers
~liveRollBuffer     = nil;
~snapshotBuffers    = Array.newClear(4);
~snapshotCursor     = 0;              // next snapshot slot to write
~snapshotFilled     = Array.fill(4, false); // slot has recorded material

~voiceActivity      = Array.fill(4, 0); // 0..8, used for rows 0-3 LED meter
~captureGroup       = nil;
~voiceGroup         = nil;
~fxGroup            = nil;
~mixBus             = nil;
~liveCaptureNode    = nil;
~fxNode             = nil;

~droneNode          = nil;
~droneActive        = false;

~fxReverb           = true;
~fxDelay            = true;
~fxSaturate         = false;
~fxShimmer          = false;
~masterLevels       = [0.4, 0.6, 0.8, 1.0];   // row 7 col 4-7
~masterIdx          = 2;
~masterAmp          = 0.8;

~genScheduler       = nil;
~activityRoutine    = nil;

~aWindow            = nil;            // status GUI (display only)
~statusText         = nil;

~aLedState          = Array.fill(8, { Array.fill(8, 0) });

// ---------------------------------------------------------------------------
// SynthDefs
// ---------------------------------------------------------------------------
~loadSynthDefs = {
    // Always-on: rolling capture of live input into ~liveRollBuffer
    SynthDef(\aLiveCapture, { |bufnum, inputBus = 0|
        var input = SoundIn.ar(inputBus);
        RecordBuf.ar(input, bufnum, recLevel: 1.0, preLevel: 0, run: 1, loop: 1);
    }).add;

    // One-shot snapshot capture (frees itself when buffer is full)
    SynthDef(\aSnapshot, { |bufnum, inputBus = 0|
        var input = SoundIn.ar(inputBus);
        RecordBuf.ar(input, bufnum, recLevel: 1.0, preLevel: 0, run: 1, loop: 0,
                     doneAction: 2);
    }).add;

    // Granular cloud
    SynthDef(\aGran, { |bufnum, outBus = 0, pos = 0.5, pan = 0, amp = 0.2, dur = 8,
                        rate = 1, spread = 0.1, grainRate = 22, grainDur = 0.12|
        var env, jitter, scan, sig;
        env    = EnvGen.ar(Env([0, 1, 1, 0], [dur*0.3, dur*0.4, dur*0.3], \sin),
                           doneAction: 2);
        jitter = LFNoise1.kr(grainRate * 0.5) * spread;
        scan   = (pos + jitter).fold(0, 1);
        sig    = GrainBuf.ar(1, Impulse.kr(grainRate), grainDur, bufnum, rate, scan);
        Out.ar(outBus, Pan2.ar(sig * env * amp, pan));
    }).add;

    // Spectral freeze
    SynthDef(\aFreeze, { |bufnum, outBus = 0, pos = 0.5, pan = 0, amp = 0.3, dur = 10|
        var env, src, chain, sig, freezeRamp, startFrames;
        env         = EnvGen.ar(Env([0, 1, 1, 0], [dur*0.3, dur*0.4, dur*0.3], \sin),
                                doneAction: 2);
        startFrames = pos * BufFrames.kr(bufnum);
        src         = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum),
                                 startPos: startFrames, loop: 1);
        // start unfrozen so FFT captures content, then ramp to fully frozen
        freezeRamp  = Line.kr(0, 1, dur * 0.08);
        chain       = FFT(LocalBuf(2048), src);
        chain       = PV_Freeze(chain, freezeRamp);
        sig         = IFFT(chain);
        Out.ar(outBus, Pan2.ar(sig * env * amp * 0.7, pan));
    }).add;

    // Reverse playback
    SynthDef(\aRev, { |bufnum, outBus = 0, pos = 0.5, pan = 0, amp = 0.3, dur = 6|
        var env, sig, frames, startF;
        env    = EnvGen.ar(Env([0, 1, 1, 0], [dur*0.3, dur*0.4, dur*0.3], \sin),
                           doneAction: 2);
        frames = BufFrames.kr(bufnum);
        startF = pos * frames;
        sig    = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum) * -1,
                            startPos: startF, loop: 1);
        Out.ar(outBus, Pan2.ar(sig * env * amp, pan));
    }).add;

    // Pitch-shifted playback (rate determines pitch)
    SynthDef(\aPitch, { |bufnum, outBus = 0, pos = 0.5, pan = 0, amp = 0.25, dur = 6,
                         rate = 1|
        var env, sig, frames, startF;
        env    = EnvGen.ar(Env([0, 1, 1, 0], [dur*0.3, dur*0.4, dur*0.3], \sin),
                           doneAction: 2);
        frames = BufFrames.kr(bufnum);
        startF = pos * frames;
        sig    = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum) * rate,
                            startPos: startF, loop: 1);
        Out.ar(outBus, Pan2.ar(sig * env * amp, pan));
    }).add;

    // Sustained spectral-freeze drone — gate-released, slow pan/amp drift
    SynthDef(\aDrone, { |bufnum, outBus = 0, pos = 0.3, amp = 0.3, gate = 1|
        var env, src, chain, sig, drift;
        env   = EnvGen.kr(Env.asr(6, 1, 10, \sin), gate, doneAction: 2);
        src   = PlayBuf.ar(1, bufnum, BufRateScale.kr(bufnum),
                           startPos: pos * BufFrames.kr(bufnum), loop: 1);
        chain = FFT(LocalBuf(4096), src);
        chain = PV_Freeze(chain, Line.kr(0, 1, 0.5));
        sig   = IFFT(chain);
        drift = SinOsc.kr(0.031).range(0.55, 1.0);
        sig   = Pan2.ar(sig * drift, SinOsc.kr(0.017).range(-0.5, 0.5));
        Out.ar(outBus, sig * env * amp);
    }).add;

    // Global FX chain: in(stereo) → delay → reverb (+shimmer feedback) → saturation → out
    SynthDef(\aFX, { |inBus = 0, outBus = 0, revAmt = 0.7, delAmt = 0.5,
                      satAmt = 0, shimAmt = 0, masterAmp = 0.8|
        var in, dly, fb, dry, rev, sat, sig;
        in  = In.ar(inBus, 2);
        dly = CombL.ar(in, 4.0, 3.5, 8) * delAmt;
        fb  = LocalIn.ar(2) * shimAmt;          // octave-up reverb feedback
        sig = in + dly + fb;
        dry = sig;
        // FreeVerb2 mix:0 can output silence in some SC builds, so blend manually
        rev = FreeVerb2.ar(sig[0], sig[1], mix: 1.0, room: 0.9, damp: 0.2);
        LocalOut.ar(PitchShift.ar(rev, 0.23, 2.0, 0, 0.01).softclip * 0.4);
        sig = (dry * (1 - revAmt)) + (rev * revAmt);
        sat = (sig * (1 + (satAmt * 4))).tanh;
        sig = SelectX.ar(satAmt, [sig, sat]);
        Out.ar(outBus, sig.softclip * masterAmp);
    }).add;

    s.sync;
    "SynthDefs loaded".postln;
};

// ---------------------------------------------------------------------------
// Buffer allocation
// ---------------------------------------------------------------------------
~allocBuffers = {
    ~liveRollBuffer = Buffer.alloc(s, s.sampleRate * ~aLiveRollSeconds, 1);
    4.do { |i|
        ~snapshotBuffers[i] = Buffer.alloc(s, s.sampleRate * ~aSnapshotSeconds, 1);
    };
    "live buffer: % s   |   4 snapshot buffers: % s each"
        .format(~aLiveRollSeconds, ~aSnapshotSeconds).postln;
};

// ---------------------------------------------------------------------------
// Sample bank loader
// ---------------------------------------------------------------------------
~loadSamples = {
    var pn, allFiles, files;
    if(File.exists(~aSamplePath).not) {
        "WARNING: sample folder not found: %".format(~aSamplePath).postln;
        "         running with live input only".postln;
    } {
        pn       = PathName(~aSamplePath);
        allFiles = pn.files;
        files    = allFiles.select { |f|
            #["wav","aif","aiff","flac"].includes(f.extension.toLower)
        };
        if(files.size == 0) {
            "no loadable samples in % (live input only)".format(~aSamplePath).postln;
            if(allFiles.size > 0) {
                "folder contains % file(s) but none end in .wav/.aif/.aiff/.flac:"
                    .format(allFiles.size).postln;
                allFiles.do { |f| ("  " ++ f.fileName).postln };
            };
        } {
            "loading % samples from % ...".format(files.size, ~aSamplePath).postln;
            files.do { |f|
                // voices expect mono buffers (GrainBuf / PlayBuf.ar(1, ...)),
                // so read only the first channel of each file
                var buf = Buffer.readChannel(s, f.fullPath, channels: [0],
                    action: { |b|
                        "  loaded: %  (% s)".format(f.fileName,
                            (b.numFrames / b.sampleRate).round(0.1)).postln;
                        ~updateGui !? { ~updateGui.() };
                    });
                ~sourcePool = ~sourcePool.add(buf);
            };
        };
    };
};

// ---------------------------------------------------------------------------
// Source chooser — respects live↔sample bias
// ---------------------------------------------------------------------------
~chooseSource = {
    var filledSnaps = ~snapshotBuffers.select { |b, i| b.notNil and: { ~snapshotFilled[i] } };
    var liveBufs    = [~liveRollBuffer].reject(_.isNil) ++ filledSnaps;
    var sampleBufs = ~sourcePool;
    var biasNorm   = ~sourceBias / 7.0;  // 0..1
    var result;
    if(sampleBufs.isEmpty) {
        result = liveBufs.choose;
    } {
        if(liveBufs.isEmpty) {
            result = sampleBufs.choose;
        } {
            if(1.0.rand < biasNorm) {
                result = sampleBufs.choose;
            } {
                result = liveBufs.choose;
            };
        };
    };
    result;
};

// ---------------------------------------------------------------------------
// LED helpers
// ---------------------------------------------------------------------------
~ledSet = { |row, col, val|
    ~aLedState[row][col] = val;
    ~aMonomeAddr.sendMsg(~aMonomePrefix ++ "/grid/led/set", col, row, val);
};

~ledRow = { |row, vals|
    var mask = 0;
    vals.do { |v, i| mask = mask | (v.asInteger << i) };
    vals.do { |v, i| ~aLedState[row][i] = v };
    ~aMonomeAddr.sendMsg(~aMonomePrefix ++ "/grid/led/row", 0, row, mask);
};

~clearLeds = {
    ~aMonomeAddr.sendMsg(~aMonomePrefix ++ "/grid/led/all", 0);
    ~aLedState = Array.fill(8, { Array.fill(8, 0) });
};

// ---------------------------------------------------------------------------
// Display update
// ---------------------------------------------------------------------------
~updateDisplay = {
    var row4 = Array.fill(~aNumCols, 0);
    var row5 = Array.fill(~aNumCols, 0);
    var row6 = Array.fill(~aNumCols, 0);
    var row7 = Array.fill(~aNumCols, 0);

    // Rows 0-3: voice activity bar (lit LEDs = recent activity, decays over time)
    ~aNumVoices.do { |i|
        var row = Array.fill(~aNumCols, { |col|
            if(col < ~voiceActivity[i]) { 1 } { 0 }
        });
        ~ledRow.(i, row);
    };

    // Row 4 col 0-3: enabled voice types (G F R P).  col 4-7: pitch palette
    ~allVoiceTypes.do { |kind, i|
        row4[i] = if(~enabledVoiceTypes.includes(kind)) { 1 } { 0 };
    };
    row4[4 + ~palette.clip(0, 3)] = 1;
    ~ledRow.(4, row4);

    // Row 5 col 0-2: density.  col 3: burst (momentary).  col 4-7: source bias
    row5[(~density - 1).clip(0, 2)] = 1;
    row5[4 + (~sourceBias / 2).floor.asInteger.clip(0, 3)] = 1;
    ~ledRow.(5, row5);

    // Row 6: transport, snap, drone, snapshot slots 0-3, panic
    row6[0] = if(~aTransport)  { 1 } { 0 };
    row6[2] = if(~droneActive) { 1 } { 0 };
    4.do { |i| row6[3 + i] = if(~snapshotFilled[i]) { 1 } { 0 } };
    ~ledRow.(6, row6);

    // Row 7: FX toggles + shimmer + master volume slider
    row7[0] = if(~fxReverb)   { 1 } { 0 };
    row7[1] = if(~fxDelay)    { 1 } { 0 };
    row7[2] = if(~fxSaturate) { 1 } { 0 };
    row7[3] = if(~fxShimmer)  { 1 } { 0 };
    row7[4 + ~masterIdx.clip(0, 3)] = 1;
    ~ledRow.(7, row7);

    ~updateGui !? { ~updateGui.() };
};

// ---------------------------------------------------------------------------
// Voice activity meter — bar decays toward 0 every 250 ms
// ---------------------------------------------------------------------------
~triggerActivity = { |voiceIdx|
    ~voiceActivity[voiceIdx] = ~aNumCols;
    ~updateDisplay.();
};

~startActivityFade = {
    ~activityRoutine !? { ~activityRoutine.stop };
    ~activityRoutine = Routine({
        loop {
            var changed = false;
            ~aNumVoices.do { |i|
                if(~voiceActivity[i] > 0) {
                    ~voiceActivity[i] = ~voiceActivity[i] - 1;
                    changed = true;
                };
            };
            if(changed) { ~updateDisplay.() };
            0.25.wait;
        };
    }).play;
};

// ---------------------------------------------------------------------------
// Voice spawning
// ---------------------------------------------------------------------------
// Core spawner — used by the scheduler, the pads (rows 0-3), burst and
// snapshot audition.  pos/src are optional; rates come from the active palette.
~spawnVoiceAt = { |kind, pos, src|
    var pan, amp, dur, args, rate;
    src = src ?? { ~chooseSource.() };
    if(src.notNil) {
        pos  = pos ?? { rrand(0.0, 0.85) };
        pan  = rrand(-0.8, 0.8);
        amp  = exprand(0.08, 0.32);
        dur  = exprand(4.0, 12.0);
        args = [\bufnum, src, \outBus, ~mixBus.index, \pos, pos, \pan, pan,
                \amp, amp, \dur, dur];
        if(kind == \aPitch) {
            rate = ~pitchPalettes[~palette].choose;
            args = args ++ [\rate, rate];
        };
        if(kind == \aGran) {
            args = args ++ [\rate,    ~pitchPalettes[~palette].choose,
                            \spread,  exprand(0.04, 0.25)];
        };
        Synth(kind, args, target: ~voiceGroup);
        ~triggerActivity.(~allVoiceTypes.indexOf(kind) ? 0);
    };
};

~spawnVoice = {
    ~spawnVoiceAt.(~enabledVoiceTypes.choose);
};

// Manual pad hit (rows 0-3): row = voice type, col = buffer position
~firePad = { |row, col|
    ~spawnVoiceAt.(~allVoiceTypes[row], col / (~aNumCols - 1));
};

// Burst: fire several voices in quick succession (row 5 col 3)
~burst = {
    fork {
        rrand(3, 5).do {
            ~spawnVoice.();
            rrand(0.05, 0.3).wait;
        };
    };
    "burst!".postln;
};

// ---------------------------------------------------------------------------
// Generative scheduler
// ---------------------------------------------------------------------------
~startGen = {
    ~aTransport = true;
    ~genScheduler !? { ~genScheduler.stop };
    ~genScheduler = Routine({
        loop {
            if(~aTransport && ~enabledVoiceTypes.notEmpty) {
                if(~voiceGroup.notNil) {
                    ~spawnVoice.();
                };
                (exprand(1.5, 6.0) / ~density).wait;
            } {
                0.5.wait;
            };
        };
    }).play;
    ~updateDisplay.();
    "ambient engine: ON".postln;
};

~stopGen = {
    ~aTransport = false;
    ~genScheduler !? { ~genScheduler.stop };
    ~genScheduler = nil;
    ~updateDisplay.();
    "ambient engine: OFF (tails will keep ringing)".postln;
};

// ---------------------------------------------------------------------------
// Snapshot — capture next ~aSnapshotSeconds of live input
// ---------------------------------------------------------------------------
~takeSnapshot = {
    var slot = ~snapshotCursor;
    var buf  = ~snapshotBuffers[slot];
    buf.zero;
    ~snapshotFilled[slot] = false;
    ~updateDisplay.();
    Synth(\aSnapshot, [\bufnum, buf, \inputBus, ~aInputBus],
        target: ~captureGroup);
    SystemClock.sched(~aSnapshotSeconds + 0.1, {
        ~snapshotFilled[slot] = true;
        ~updateDisplay.();
        "snapshot slot % ready".format(slot).postln;
        nil
    });
    ~snapshotCursor = (slot + 1) % 4;
    "snapshot recording into slot %".format(slot).postln;
};

// Audition a snapshot slot (row 6 col 3-6): granular voice from that buffer
~auditionSnapshot = { |slot|
    if(~snapshotFilled[slot]) {
        ~spawnVoiceAt.(\aGran, rrand(0.0, 0.7), ~snapshotBuffers[slot]);
        "audition snapshot %".format(slot).postln;
    } {
        "snapshot slot % is empty".format(slot).postln;
    };
};

// ---------------------------------------------------------------------------
// Drone — sustained freeze pad, toggled on/off (row 6 col 2)
// ---------------------------------------------------------------------------
~toggleDrone = {
    if(~droneActive) {
        ~droneNode !? { ~droneNode.set(\gate, 0) };  // long release, frees itself
        ~droneNode   = nil;
        ~droneActive = false;
        "drone: releasing".postln;
    } {
        var src = ~chooseSource.();
        if(src.notNil) {
            var node = Synth(\aDrone,
                [\bufnum, src, \outBus, ~mixBus.index,
                 \pos, rrand(0.0, 0.8), \amp, 0.3],
                target: ~voiceGroup);
            node.onFree {
                if(~droneNode == node) {  // killed externally (e.g. PANIC)
                    ~droneNode   = nil;
                    ~droneActive = false;
                    ~updateDisplay.();
                };
            };
            ~droneNode   = node;
            ~droneActive = true;
            "drone: ON".postln;
        } {
            "drone: no source available".postln;
        };
    };
    ~updateDisplay.();
};

// ---------------------------------------------------------------------------
// Panic — free all voice synths immediately
// ---------------------------------------------------------------------------
~aPanic = {
    ~voiceGroup !? { ~voiceGroup.freeAll };
    "PANIC: all voices stopped".postln;
};

// ---------------------------------------------------------------------------
// FX toggles
// ---------------------------------------------------------------------------
~toggleReverb = {
    ~fxReverb = ~fxReverb.not;
    ~fxNode.set(\revAmt, if(~fxReverb) { 0.7 } { 0 });
    ~updateDisplay.();
    "reverb: %".format(~fxReverb).postln;
};

~toggleDelay = {
    ~fxDelay = ~fxDelay.not;
    ~fxNode.set(\delAmt, if(~fxDelay) { 0.5 } { 0 });
    ~updateDisplay.();
    "delay: %".format(~fxDelay).postln;
};

~toggleSaturate = {
    ~fxSaturate = ~fxSaturate.not;
    ~fxNode.set(\satAmt, if(~fxSaturate) { 1.0 } { 0 });
    ~updateDisplay.();
    "saturate: %".format(~fxSaturate).postln;
};

~toggleShimmer = {
    ~fxShimmer = ~fxShimmer.not;
    ~fxNode.set(\shimAmt, if(~fxShimmer) { 1.0 } { 0 });
    ~updateDisplay.();
    "shimmer: %".format(~fxShimmer).postln;
};

~setMasterVolume = { |idx|
    ~masterIdx = idx.clip(0, 3);
    ~masterAmp = ~masterLevels[~masterIdx];
    ~fxNode.set(\masterAmp, ~masterAmp);
    ~updateDisplay.();
    "master volume: %".format(~masterAmp).postln;
};

~setPalette = { |idx|
    ~palette = idx.clip(0, 3);
    ~updateDisplay.();
    "pitch palette: %".format(~paletteNames[~palette]).postln;
};

~toggleVoiceType = { |idx|
    var kind = ~allVoiceTypes[idx];
    if(~enabledVoiceTypes.includes(kind)) {
        ~enabledVoiceTypes = ~enabledVoiceTypes.reject { |x| x == kind };
    } {
        ~enabledVoiceTypes = ~enabledVoiceTypes.add(kind);
    };
    ~updateDisplay.();
    "voice types enabled: %".format(~enabledVoiceTypes).postln;
};

// ---------------------------------------------------------------------------
// serialosc device registration (copied from super_duper_looper.scd pattern)
// ---------------------------------------------------------------------------
~connectMonome = { |devicePort|
    var deviceAddr = NetAddr("127.0.0.1", devicePort);
    ~aMonomeAddr      = deviceAddr;
    ~aMonomeConnected = true;
    deviceAddr.sendMsg("/sys/port",   ~aMonomeReceivePort);
    deviceAddr.sendMsg("/sys/prefix", ~aMonomePrefix);
    SystemClock.sched(0.05, {
        ~aMonomeAddr.sendMsg(~aMonomePrefix ++ "/grid/led/all", 1);
        nil
    });
    SystemClock.sched(0.4, {
        ~aMonomeAddr.sendMsg(~aMonomePrefix ++ "/grid/led/all", 0);
        ~updateDisplay.();
        nil
    });
    "=== monome connected on port % ===".format(devicePort).postln;
};

~setupMonome = {
    thisProcess.openUDPPort(~aMonomeReceivePort);

    OSCdef(\aSerialoscDevice, { |msg|
        var devicePort = msg[3].asInteger;
        "monome found: type=%, port=%".format(msg[2], devicePort).postln;
        ~connectMonome.(devicePort);
        OSCdef(\aSerialoscDevice).free;
    }, "/serialosc/device", recvPort: ~aMonomeReceivePort);

    fork {
        NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list",
            "127.0.0.1", ~aMonomeReceivePort);
        "querying serialosc for monome devices (port %)...".format(~aMonomeReceivePort).postln;
        2.0.wait;
        if(~aMonomeConnected.not) {
            "retrying serialosc query...".postln;
            NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list",
                "127.0.0.1", ~aMonomeReceivePort);
            2.0.wait;
            if(~aMonomeConnected.not) {
                "WARNING: no monome device found. Call ~connectMonome.(port) manually.".postln;
            };
        };
    };
};

// ---------------------------------------------------------------------------
// monome OSC handler
// ---------------------------------------------------------------------------
~setupOSC = {
    OSCdef(\aMonomeGrid, { |msg|
        var col   = msg[1].asInteger;
        var row   = msg[2].asInteger;
        var state = msg[3].asInteger;

        if(state == 1) {
            case
            // Rows 0-3: playable pads — row = voice type, col = buffer position
            { row < 4 } {
                ~firePad.(row, col);
            }

            // Row 4 col 0-3: toggle voice types
            { (row == 4) && (col < 4) } {
                ~toggleVoiceType.(col);
            }

            // Row 4 col 4-7: pitch palette select
            { (row == 4) && (col >= 4) } {
                ~setPalette.(col - 4);
            }

            // Row 5 col 0-2: density 1/2/3
            { (row == 5) && (col < 3) } {
                ~density = col + 1;
                ~updateDisplay.();
                "density: %".format(~density).postln;
            }

            // Row 5 col 3: burst
            { (row == 5) && (col == 3) } {
                ~burst.();
            }

            // Row 5 col 4-7: source bias slider
            { (row == 5) && (col >= 4) } {
                ~sourceBias = ((col - 4) * 2) + 1;  // map col 4..7 → bias 1,3,5,7
                ~updateDisplay.();
                "source bias: %  (0=live  7=sample)".format(~sourceBias).postln;
            }

            // Row 6 col 0: transport
            { (row == 6) && (col == 0) } {
                if(~aTransport) { ~stopGen.() } { ~startGen.() };
            }

            // Row 6 col 1: snapshot capture
            { (row == 6) && (col == 1) } {
                ~takeSnapshot.();
            }

            // Row 6 col 2: drone toggle
            { (row == 6) && (col == 2) } {
                ~toggleDrone.();
            }

            // Row 6 col 3-6: snapshot slot audition
            { (row == 6) && (col >= 3) && (col <= 6) } {
                ~auditionSnapshot.(col - 3);
            }

            // Row 6 col 7: PANIC
            { (row == 6) && (col == 7) } {
                ~aPanic.();
            }

            // Row 7: FX toggles, shimmer, master volume
            { (row == 7) && (col == 0) } { ~toggleReverb.() }
            { (row == 7) && (col == 1) } { ~toggleDelay.() }
            { (row == 7) && (col == 2) } { ~toggleSaturate.() }
            { (row == 7) && (col == 3) } { ~toggleShimmer.() }
            { (row == 7) && (col >= 4) } { ~setMasterVolume.(col - 4) };
        };
    }, ~aMonomePrefix ++ "/grid/key", recvPort: ~aMonomeReceivePort);

    "ambient OSC handlers registered on port %".format(~aMonomeReceivePort).postln;
};

// ---------------------------------------------------------------------------
// Status GUI — display only, follows every state change automatically
// ---------------------------------------------------------------------------
~updateGui = {
    {
        if(~aWindow.notNil and: { ~statusText.notNil }) {
            var onoff = { |b| if(b) { "ON " } { "off" } };
            var en    = ~allVoiceTypes.collect { |k, i|
                if(~enabledVoiceTypes.includes(k)) { ~voiceTypeLabels[i] } { "-" }
            }.join(" ");
            var snaps = ~snapshotFilled.collect { |f| if(f) { "*" } { "." } }.join(" ");
            ~statusText.string = (
                   "engine   : %\n".format(onoff.(~aTransport))
                ++ "density  : %     bias : % (0=live 7=sample)\n"
                    .format(~density, ~sourceBias)
                ++ "palette  : %\n".format(~paletteNames[~palette])
                ++ "voices   : %     drone : %\n".format(en, onoff.(~droneActive))
                ++ "FX       : REV %  DLY %  SAT %  SHM %\n".format(
                    onoff.(~fxReverb), onoff.(~fxDelay),
                    onoff.(~fxSaturate), onoff.(~fxShimmer))
                ++ "volume   : %\n".format(~masterAmp)
                ++ "snapshot : %   (* = recorded)\n".format(snaps)
                ++ "samples  : % loaded\n".format(~sourcePool.size)
                ++ "monome   : %".format(
                    if(~aMonomeConnected) { "connected" } { "not found" })
            );
        };
    }.defer;
};

~makeGui = {
    ~aWindow !? { if(~aWindow.isClosed.not) { ~aWindow.close } };
    ~aWindow = Window("ambient_machine status", Rect(60, 60, 380, 220))
        .alwaysOnTop_(true);
    ~statusText = StaticText(~aWindow, Rect(14, 10, 352, 200))
        .font_(Font("Menlo", 13))
        .align_(\topLeft);
    ~aWindow.onClose = { ~aWindow = nil; ~statusText = nil };
    ~aWindow.front;
    ~updateGui.();
};

// ---------------------------------------------------------------------------
// Boot sequence
// ---------------------------------------------------------------------------
s.waitForBoot({
    ~captureGroup = Group.new(s);
    ~voiceGroup   = Group.after(~captureGroup);
    ~fxGroup      = Group.after(~voiceGroup);
    ~mixBus     = Bus.audio(s, 2);

    ~loadSynthDefs.();
    s.sync;

    ~allocBuffers.();
    s.sync;

    ~loadSamples.();
    s.sync;

    // always-on synths
    ~liveCaptureNode = Synth(\aLiveCapture,
        [\bufnum, ~liveRollBuffer, \inputBus, ~aInputBus],
        target: ~captureGroup);
    ~fxNode = Synth(\aFX,
        [\inBus, ~mixBus.index, \outBus, ~aOutBus,
         \revAmt, if(~fxReverb) { 0.7 } { 0 },
         \delAmt, if(~fxDelay)  { 0.5 } { 0 },
         \satAmt, if(~fxSaturate) { 1.0 } { 0 },
         \shimAmt, if(~fxShimmer) { 1.0 } { 0 },
         \masterAmp, ~masterAmp],
        target: ~fxGroup);

    ~setupOSC.();
    ~setupMonome.();
    ~startActivityFade.();
    { ~makeGui.() }.defer;

    "=== ambient_machine ready ===".postln;
    "live capture: running (% s rolling buffer)".format(~aLiveRollSeconds).postln;
    "press monome row 6 col 0 to start the generative engine.".postln;
    "".postln;
    "--- monome layout (all 64 buttons live) ---".postln;
    "  Row 0-3 : activity meters + PADS (press: fire voice, col = position)".postln;
    "            row0=Gran row1=Freeze row2=Rev row3=Pitch".postln;
    "  Row 4   : G/F/R/P enables (col 0-3) | pitch palette (col 4-7)".postln;
    "  Row 5   : density (col 0-2) | BURST (col 3) | source bias (col 4-7)".postln;
    "  Row 6   : ▶/■  SNAP  DRONE  [S0 S1 S2 S3 audition]  PANIC".postln;
    "  Row 7   : REV DLY SAT SHIMMER | master volume (col 4-7)".postln;
});
)


// ---------------------------------------------------------------------------
// Cleanup — run this block separately to tear down
// ---------------------------------------------------------------------------
(
~stopGen.();
~activityRoutine !? { ~activityRoutine.stop };
~aWindow         !? { { ~aWindow.close }.defer };
~liveCaptureNode !? { ~liveCaptureNode.free };
~fxNode          !? { ~fxNode.free };
~captureGroup    !? { ~captureGroup.freeAll; ~captureGroup.free };
~voiceGroup      !? { ~voiceGroup.freeAll; ~voiceGroup.free };
~fxGroup         !? { ~fxGroup.free };
~mixBus          !? { ~mixBus.free };
~liveRollBuffer  !? { ~liveRollBuffer.free };
~snapshotBuffers.do { |b| b !? { b.free } };
~sourcePool.do      { |b| b !? { b.free } };
OSCdef(\aMonomeGrid).free;
OSCdef(\aSerialoscDevice).free;
~clearLeds.();
"ambient_machine stopped".postln;
)
