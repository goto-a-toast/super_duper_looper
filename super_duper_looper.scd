/*
  super_duper_looper.scd  v3
  SuperCollider looper — monome64 / mlr-style

  v2: global FX chain (reverb/delay/crush), per-track granular mode
  v3: analysis-driven features (Phase 3) + reverse / variable speed (Phase 4)

  Signal flow:
    [ampAnalysis]                      ──► ~ampBus (kr) ──► globalFX + grainPlay
    [onsetDetect]                      ──► SendReply '/onset' ──► language
    [inputMonitor / loopPlay / grainPlay] ──► ~mixBus (ar mono)
    ──► [globalFX (reverb/delay/crush, optionally amp-driven)] ──► hw out (stereo)

  monome64 layout:
    Row 0-3 : loop range & playhead per track
    Row 4   : col 0-3  rec-arm (normal) / onset-arm (onset-rec mode)
              col 4    onset-rec mode on/off
              col 5    amp-fx mode on/off  (amp → reverb boost + grain spread)
              col 6    half-speed (0.5×)
              col 7    double-speed (2×)
    Row 5   : col 0-3 overdub, col 4-7 clear track
    Row 6   : col 0   play/stop
              col 1   rec all
              col 2-5 reverse T0-T3
              col 7   clear all
    Row 7   : col 0-3 granular mode per track
              col 4 reverb, col 5 delay, col 6 bit crush
*/

(
// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
~numTracks    = 4;
~numCols      = 8;
~loopDuration = 4.0;
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
~isGranular  = Array.fill(~numTracks, false);
~playPos     = Array.fill(~numTracks, 0);
~loopStart   = Array.fill(~numTracks, 0);
~loopEnd     = Array.fill(~numTracks, 7);
~transport   = false;
~ledState    = Array.fill(8, { Array.fill(8, 0) });
~heldCol     = Array.fill(~numTracks, nil);
~rangeSet    = Array.fill(~numTracks, false);

// Phase 1: effects
~fxReverb    = false;
~fxDelay     = false;
~fxCrush     = false;
~fxNode      = nil;
~mixBus      = nil;

// Phase 2: granular parameters
~grainRate   = 20;
~grainDur    = 0.08;
~grainSpread = 0.06;
~grainPitch  = 1.0;

// Phase 3: analysis-driven
~onsetRecMode    = false;          // onset triggers recording on armed tracks
~ampFxMode       = false;          // input amplitude drives reverb + grain spread
~isArmed         = Array.fill(~numTracks, false);  // onset-record arm per track
~onsetThreshold  = 0.5;            // Onsets sensitivity (0=most, 1=least)
~ampNode         = nil;
~onsetNode       = nil;
~ampBus          = nil;            // control bus carrying input amplitude (0-1)

// Phase 4: reverse / speed
~playRate        = Array.fill(~numTracks, 1.0);  // +1.0 forward, -1.0 reverse
~speedMult       = 1.0;                          // global speed: 0.5, 1.0, or 2.0

// Synth groups
~playGroup   = nil;
~fxGroup     = nil;

// ---------------------------------------------------------------------------
// Allocate buffers + buses
// ---------------------------------------------------------------------------
~allocBuffers = {
    ~mixBus = Bus.audio(s, 1);
    ~ampBus = Bus.control(s, 1);
    ~numTracks.do { |i|
        ~buffers[i] = Buffer.alloc(s, ~bufFrames, 1);
    };
    "Buffers allocated (% tracks × % sec)  mixBus: %  ampBus: %"
        .format(~numTracks, ~loopDuration, ~mixBus.index, ~ampBus.index).postln;
};

// ---------------------------------------------------------------------------
// SynthDefs
// ---------------------------------------------------------------------------
~loadSynthDefs = {

    // Record into buffer ─────────────────────────────────────────────────────
    SynthDef(\loopRec, { |bufnum, inputBus = 0, startFrame = 0, endFrame = 44100,
                           preLevel = 1.0, recLevel = 1.0, gate = 1|
        var input = SoundIn.ar(inputBus);
        RecordBuf.ar(input, bufnum, offset: startFrame,
                     recLevel: recLevel, preLevel: preLevel,
                     run: gate, loop: 1);
        FreeSelf.kr(1 - gate);
    }).add;

    // Standard playback → mono mix bus  (Phase 4: rate for speed + reverse) ─
    //   rate > 0: forward,  rate < 0: reverse,  abs(rate) sets speed
    //   resetPos is set at creation time to match direction
    SynthDef(\loopPlay, { |bufnum, outBus = 0, startFrame = 0, endFrame = 44100,
                           rate = 1.0, amp = 0.7, gate = 1|
        var env, speed, resetPos, phase, sig;
        env      = EnvGen.kr(Env.asr(0.005, 1, 0.005), gate, doneAction: 2);
        speed    = BufRateScale.kr(bufnum) * rate;
        // Forward: start at startFrame; reverse: start at endFrame
        resetPos = Select.kr(rate < 0, [startFrame.asFloat, (endFrame - 1).asFloat]);
        phase    = Phasor.ar(0, speed, startFrame, endFrame, resetPos);
        sig      = BufRd.ar(1, bufnum, phase, interpolation: 2);
        Out.ar(outBus, sig * amp * env);
    }).add;

    // Granular playback → mono mix bus  (Phase 2 + 3 + 4) ───────────────────
    //   scanDir  +1 = forward scan,  -1 = reverse scan
    //   scanRate speed multiplier (1.0 = normal)
    //   ampMod   0 = off, 1 = input amplitude widens grain spread
    SynthDef(\grainPlay, { |bufnum, outBus = 0,
                             startFrame = 0, endFrame = 44100,
                             grainRate = 20, grainDur = 0.08,
                             spread = 0.06, pitchRatio = 1.0,
                             scanDir = 1, scanRate = 1.0,
                             ampMod = 0, ampBus = 0,
                             amp = 0.7, gate = 1|
        var env, numFrames, loopLen, startPos, endPos, scanFreq;
        var lo, hi, scanPos, inputAmp, dynSpread, jitter, pos, trig, sig;
        env       = EnvGen.kr(Env.asr(0.03, 1, 0.08), gate, doneAction: 2);
        numFrames = BufFrames.kr(bufnum);
        loopLen   = (endFrame - startFrame) / numFrames;    // fraction 0..1
        startPos  = startFrame / numFrames;
        endPos    = endFrame   / numFrames;
        scanFreq  = scanRate.abs / max(loopLen * BufDur.kr(bufnum), 0.01);
        // Direction: swap lo/hi so LFSaw scans forward or backward
        lo        = Select.kr(scanDir > 0, [endPos,   startPos]);
        hi        = Select.kr(scanDir > 0, [startPos, endPos  ]);
        scanPos   = LFSaw.kr(scanFreq).range(lo, hi);
        // Amplitude-driven spread (Phase 3)
        inputAmp  = In.kr(ampBus);
        dynSpread = spread + (ampMod * inputAmp.linlin(0, 0.6, 0, 0.25));
        jitter    = LFNoise1.kr(grainRate) * dynSpread * loopLen;
        pos       = (scanPos + jitter).clip(0, 1);
        trig      = Impulse.ar(grainRate);
        sig       = GrainBuf.ar(1, trig, grainDur, bufnum, pitchRatio, pos);
        Out.ar(outBus, sig * amp * env);
    }).add;

    // Global FX chain  (Phase 1 + 3) ─────────────────────────────────────────
    //   ampFxMode 1: input amplitude boosts reverb send level dynamically
    SynthDef(\globalFX, { |inBus, outBus = 0, ampBus = 0,
                           reverbAmt = 0.0,
                           delayAmt  = 0.0, delayTime = 0.35, delayFeedback = 0.5,
                           crushAmt  = 0.0,
                           ampFxMode = 0,
                           amp = 1.0|
        var sig, step, crushed, delayed, inputAmp, dynReverb, revved;
        sig = In.ar(inBus, 1);

        // Bit crush ──────────────────────────────────────────────────────────
        step    = 1.0 / 16;
        crushed = (sig / step).round * step;
        sig     = XFade2.ar(sig, crushed, crushAmt * 2 - 1);

        // Delay ──────────────────────────────────────────────────────────────
        delayed = CombL.ar(sig, 2.0, delayTime, delayFeedback * 10);
        sig     = sig + (delayed * delayAmt * 0.7);

        // Reverb with optional amplitude modulation (Phase 3) ────────────────
        //   dynReverb = manual setting + amp boost when ampFxMode=1
        inputAmp  = In.kr(ampBus);
        dynReverb = (reverbAmt + (ampFxMode * inputAmp.linlin(0, 0.6, 0, 0.7))).clip(0, 1);
        revved    = FreeVerb.ar(sig, mix: 0.7, room: 0.85, damp: 0.2);
        sig       = XFade2.ar(sig, revved, dynReverb * 2 - 1);

        Out.ar(outBus, sig.dup(2) * amp);
    }).add;

    // Input monitor → mix bus ────────────────────────────────────────────────
    SynthDef(\inputMonitor, { |inputBus = 0, outBus = 0, amp = 0.5|
        Out.ar(outBus, SoundIn.ar(inputBus) * amp);
    }).add;

    // Amplitude tracker → control bus  (Phase 3) ─────────────────────────────
    //   Writes a smoothed amplitude value (0..1) to ampBus at kr rate
    SynthDef(\ampAnalysis, { |inputBus = 0, ampBus = 0|
        var input = SoundIn.ar(inputBus);
        var level = Amplitude.kr(input, attackTime: 0.01, releaseTime: 0.15);
        Out.kr(ampBus, level);
    }).add;

    // Onset detector → SendReply '/onset'  (Phase 3) ─────────────────────────
    //   Uses FFT + Onsets.kr; fires SendReply each time an onset is detected
    SynthDef(\onsetDetect, { |inputBus = 0, threshold = 0.5|
        var input = SoundIn.ar(inputBus);
        var chain = FFT(LocalBuf(512), input);
        var onset = Onsets.kr(chain, threshold: threshold, odftype: \rcomplex);
        SendReply.kr(onset, '/onset');
    }).add;

    s.sync;
    "SynthDefs loaded".postln;
};

// ---------------------------------------------------------------------------
// Frame helpers
// ---------------------------------------------------------------------------
~segToFrame = { |seg| (seg / ~numCols * ~bufFrames).asInteger };
~frameToSeg = { |frame| (frame / ~bufFrames * ~numCols).asInteger.clip(0, ~numCols - 1) };

// Effective playback rate for a track: direction × global speed
~effectiveRate = { |track| ~playRate[track] * ~speedMult };

// ---------------------------------------------------------------------------
// Restart playback for one track (respects granular mode, rate, speed)
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
                \scanDir,    if(~playRate[track] < 0) { -1 } { 1 },
                \scanRate,   ~speedMult,
                \ampMod,     if(~ampFxMode) { 1 } { 0 },
                \ampBus,     ~ampBus,
                \amp,        0.7
            ], target: ~playGroup);
        } {
            ~playNodes[track] = Synth(\loopPlay, [
                \bufnum,     ~buffers[track],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \rate,       ~effectiveRate.(track),
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

    // Row 4: rec indicators (col 0-3 shows armed/recording state)
    //        + mode/speed indicators (col 4-7)
    ~numTracks.do { |t|
        recRow[t] = if(~onsetRecMode) {
            if(~isArmed[t]) { 1 } { 0 }     // onset mode: show arm state
        } {
            if(~isRecording[t]) { 1 } { 0 } // normal mode: show recording state
        };
    };
    recRow[4] = if(~onsetRecMode) { 1 } { 0 };
    recRow[5] = if(~ampFxMode)    { 1 } { 0 };
    recRow[6] = if(~speedMult == 0.5) { 1 } { 0 };
    recRow[7] = if(~speedMult == 2.0) { 1 } { 0 };
    ~ledRow.(4, recRow);

    // Row 5: overdub (col 0-3)
    ~numTracks.do { |t| odRow[t] = if(~isOverdub[t]) { 1 } { 0 } };
    ~ledRow.(5, odRow);

    // Row 6: transport (col 0) + reverse per track (col 2-5)
    trRow[0] = if(~transport) { 1 } { 0 };
    ~numTracks.do { |t| trRow[t + 2] = if(~playRate[t] < 0) { 1 } { 0 } };
    ~ledRow.(6, trRow);

    // Row 7: granular (col 0-3) + effects (col 4-6)
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
                \scanDir,    if(~playRate[t] < 0) { -1 } { 1 },
                \scanRate,   ~speedMult,
                \ampMod,     if(~ampFxMode) { 1 } { 0 },
                \ampBus,     ~ampBus,
                \amp,        0.7
            ], target: ~playGroup);
        } {
            ~playNodes[t] = Synth(\loopPlay, [
                \bufnum,     ~buffers[t],
                \outBus,     ~mixBus,
                \startFrame, startF,
                \endFrame,   endF,
                \rate,       ~effectiveRate.(t),
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
// Phase 2: granular toggle
// ---------------------------------------------------------------------------
~toggleGranular = { |track|
    ~isGranular[track] = ~isGranular[track].not;
    "Track % granular: %".format(track, ~isGranular[track]).postln;
    ~restartPlay.(track);
    ~updateDisplay.();
};

// ---------------------------------------------------------------------------
// Phase 3: onset-rec mode
// ---------------------------------------------------------------------------
~toggleOnsetRec = {
    ~onsetRecMode = ~onsetRecMode.not;
    if(~onsetRecMode.not) { ~isArmed = Array.fill(~numTracks, false) };
    ~updateDisplay.();
    "Onset-rec mode: %".format(~onsetRecMode).postln;
};

// Phase 3: amplitude-driven FX
~toggleAmpFx = {
    ~ampFxMode = ~ampFxMode.not;
    // Update FX synth
    ~fxNode !? { ~fxNode.set(\ampFxMode, if(~ampFxMode) { 1 } { 0 }) };
    // Update any running grainPlay synths
    ~numTracks.do { |t|
        if(~isGranular[t]) {
            ~playNodes[t] !? { ~playNodes[t].set(\ampMod, if(~ampFxMode) { 1 } { 0 }) };
        };
    };
    ~updateDisplay.();
    "Amp-FX mode: %".format(~ampFxMode).postln;
};

// ---------------------------------------------------------------------------
// Phase 4: reverse + speed
// ---------------------------------------------------------------------------
~toggleReverse = { |track|
    ~playRate[track] = ~playRate[track].neg;
    "Track % reverse: %".format(track, ~playRate[track] < 0).postln;
    // Hot-swap the running synth so direction changes immediately
    if(~transport && ~isPlaying[track]) {
        if(~isGranular[track]) {
            ~playNodes[track] !? {
                ~playNodes[track].set(\scanDir, if(~playRate[track] < 0) { -1 } { 1 })
            };
        } {
            // For loopPlay, restart with new rate (Phasor resetPos must be re-set)
            ~restartPlay.(track);
        };
    };
    ~updateDisplay.();
};

~setSpeed = { |mult|
    ~speedMult = mult;
    "Speed: %×".format(~speedMult).postln;
    // Update all running play synths
    ~numTracks.do { |t|
        ~playNodes[t] !? {
            if(~isGranular[t]) {
                ~playNodes[t].set(\scanRate, ~speedMult);
            } {
                ~playNodes[t].set(\rate, ~effectiveRate.(t));
            };
        };
    };
    ~updateDisplay.();
};

// ---------------------------------------------------------------------------
// Phase 1: FX toggle
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
// serialosc
// ---------------------------------------------------------------------------
~connectMonome = { |devicePort|
    var deviceAddr = NetAddr("127.0.0.1", devicePort);
    ~monomeAddr      = deviceAddr;
    ~monomeConnected = true;
    deviceAddr.sendMsg("/sys/port",   ~monomeReceivePort);
    deviceAddr.sendMsg("/sys/prefix", ~monomePrefix);
    SystemClock.sched(0.05, { ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 1); nil });
    SystemClock.sched(0.4,  {
        ~monomeAddr.sendMsg(~monomePrefix ++ "/grid/led/all", 0);
        ~updateDisplay.(); nil
    });
    "=== monome connected on port % ===".format(devicePort).postln;
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
            "retrying...".postln;
            NetAddr("127.0.0.1", 12002).sendMsg("/serialosc/list", "127.0.0.1", ~monomeReceivePort);
            2.0.wait;
            if(~monomeConnected.not) {
                "WARNING: no monome found. Call ~connectMonome.(port) manually.".postln;
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
        var state = msg[3].asInteger;

        case

        // Rows 0-3: mlr loop range ────────────────────────────────────────────
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

        // Row 4: rec/onset-arm (col 0-3) + mode/speed (col 4-7) ─────────────
        { (state == 1) && (row == 4) } {
            case
            { col < ~numTracks } {
                if(~onsetRecMode) {
                    ~isArmed[col] = ~isArmed[col].not;
                    "Track % onset-armed: %".format(col, ~isArmed[col]).postln;
                    ~updateDisplay.();
                } {
                    if(~isRecording[col]) { ~stopRecording.(col) } { ~startRecording.(col) };
                };
            }
            { col == 4 } { ~toggleOnsetRec.() }
            { col == 5 } { ~toggleAmpFx.() }
            { col == 6 } { ~setSpeed.(if(~speedMult == 0.5) { 1.0 } { 0.5 }) }
            { col == 7 } { ~setSpeed.(if(~speedMult == 2.0) { 1.0 } { 2.0 }) };
        }

        // Row 5: overdub / clear ──────────────────────────────────────────────
        { (state == 1) && (row == 5) } {
            if(col < ~numTracks) {
                ~isOverdub[col] = ~isOverdub[col].not;
                "Track % overdub: %".format(col, ~isOverdub[col]).postln;
                ~updateDisplay.();
            } {
                if((col >= 4) && (col < (4 + ~numTracks))) { ~clearTrack.(col - 4) };
            };
        }

        // Row 6: transport + reverse per track ───────────────────────────────
        { (state == 1) && (row == 6) } {
            case
            { col == 0 } { if(~transport) { ~stopTransport.() } { ~startTransport.() } }
            { col == 1 } { ~numTracks.do { |t| ~startRecording.(t) } }
            { (col >= 2) && (col <= 5) } { ~toggleReverse.(col - 2) }
            { col == 7 } { ~numTracks.do { |t| ~clearTrack.(t) } };
        }

        // Row 7: granular (col 0-3) + effects (col 4-6) ──────────────────────
        { (state == 1) && (row == 7) } {
            case
            { col < ~numTracks } { ~toggleGranular.(col) }
            { col == 4 } {
                ~fxReverb = ~fxReverb.not; ~updateFX.(); ~updateDisplay.();
                "Reverb: %".format(~fxReverb).postln;
            }
            { col == 5 } {
                ~fxDelay = ~fxDelay.not; ~updateFX.(); ~updateDisplay.();
                "Delay: %".format(~fxDelay).postln;
            }
            { col == 6 } {
                ~fxCrush = ~fxCrush.not; ~updateFX.(); ~updateDisplay.();
                "BitCrush: %".format(~fxCrush).postln;
            };
        };

    }, ~monomePrefix ++ "/grid/key", recvPort: ~monomeReceivePort);

    // Onset reaction: fire when onsetDetect sends '/onset' (Phase 3)
    OSCdef(\onsetReact, { |msg|
        if(~onsetRecMode && ~transport) {
            ~numTracks.do { |t|
                var track = t;
                if(~isArmed[track]) {
                    { ~startRecording.(track) }.defer;
                };
            };
        };
    }, '/onset');

    "OSC handlers registered on port %".format(~monomeReceivePort).postln;
};

// ---------------------------------------------------------------------------
// Boot sequence
// ---------------------------------------------------------------------------
s.waitForBoot({
    ~playGroup = Group.new(s);
    ~fxGroup   = Group.after(~playGroup);

    ~loadSynthDefs.();
    s.sync;
    ~allocBuffers.();
    s.sync;

    // Amplitude analysis (always running; writes to ~ampBus)
    ~ampNode = Synth(\ampAnalysis, [
        \inputBus, ~inputBus,
        \ampBus,   ~ampBus
    ], target: ~playGroup);

    // Onset detector (always running; sends '/onset' to language)
    ~onsetNode = Synth(\onsetDetect, [
        \inputBus,  ~inputBus,
        \threshold, ~onsetThreshold
    ], target: ~playGroup);

    // Global FX synth (always running)
    ~fxNode = Synth(\globalFX, [
        \inBus,     ~mixBus,
        \outBus,    ~outBus,
        \ampBus,    ~ampBus,
        \reverbAmt, 0.0,
        \delayAmt,  0.0,
        \crushAmt,  0.0,
        \ampFxMode, 0
    ], target: ~fxGroup);

    // Input monitor → mix bus
    ~monitorNode = Synth(\inputMonitor, [
        \inputBus, ~inputBus,
        \outBus,   ~mixBus,
        \amp,      0.5
    ], target: ~playGroup);

    ~setupOSC.();
    ~setupMonome.();
    ~updateDisplay.();

    "".postln;
    "=== super_duper_looper v3 ready ===".postln;
    "monome64 prefix: %  |  receive port: %".format(~monomePrefix, ~monomeReceivePort).postln;
    "Loop: % sec  |  onset threshold: ~onsetThreshold (adjust anytime)".format(~loopDuration).postln;
    "".postln;
    "--- monome64 layout ---".postln;
    "  Row 0-3 : loop range & playhead".postln;
    "  Row 4   : col 0-3 = rec arm / onset arm".postln;
    "            col 4 = onset-rec mode  col 5 = amp-fx mode".postln;
    "            col 6 = 0.5× speed      col 7 = 2.0× speed".postln;
    "  Row 5   : col 0-3 = overdub, col 4-7 = clear track".postln;
    "  Row 6   : col 0 = play/stop, col 1 = rec all".postln;
    "            col 2-5 = reverse T0-T3, col 7 = clear all".postln;
    "  Row 7   : col 0-3 = granular, col 4 = reverb, col 5 = delay, col 6 = crush".postln;
    "".postln;
    "--- tunable parameters ---".postln;
    "  ~grainRate=20  ~grainDur=0.08  ~grainSpread=0.06  ~grainPitch=1.0".postln;
    "  ~onsetThreshold=0.5  (lower=more sensitive; restart onset synth after changing)".postln;
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
~ampNode     !? { ~ampNode.free };
~onsetNode   !? { ~onsetNode.free };
~playGroup   !? { ~playGroup.free };
~fxGroup     !? { ~fxGroup.free };
~mixBus      !? { ~mixBus.free };
~ampBus      !? { ~ampBus.free };
OSCdef(\monomeGrid).free;
OSCdef(\onsetReact).free;
~buffers.do { |b| b !? { b.free } };
~clearLeds.();
"super_duper_looper stopped".postln;
)

// ---------------------------------------------------------------------------
// Keyboard shortcuts — evaluate this block separately after boot
// ---------------------------------------------------------------------------
(
var w = Window("sdl keys", Rect(10, 600, 260, 30)).front;
w.view.keyDownAction = { |view, char|
    switch(char,
        // transport
        $p, { if(~transport) { ~stopTransport.() } { ~startTransport.() } },
        // record arm / onset arm T0-T3
        $1, { if(~onsetRecMode) {
                  ~isArmed[0] = ~isArmed[0].not; ~updateDisplay.()
              } { if(~isRecording[0]) { ~stopRecording.(0) } { ~startRecording.(0) } } },
        $2, { if(~onsetRecMode) {
                  ~isArmed[1] = ~isArmed[1].not; ~updateDisplay.()
              } { if(~isRecording[1]) { ~stopRecording.(1) } { ~startRecording.(1) } } },
        $3, { if(~onsetRecMode) {
                  ~isArmed[2] = ~isArmed[2].not; ~updateDisplay.()
              } { if(~isRecording[2]) { ~stopRecording.(2) } { ~startRecording.(2) } } },
        $4, { if(~onsetRecMode) {
                  ~isArmed[3] = ~isArmed[3].not; ~updateDisplay.()
              } { if(~isRecording[3]) { ~stopRecording.(3) } { ~startRecording.(3) } } },
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
        // reverse T0-T3
        $g, { ~toggleReverse.(0) },
        $h, { ~toggleReverse.(1) },
        $j, { ~toggleReverse.(2) },
        $k, { ~toggleReverse.(3) },
        // speed
        $-, { ~setSpeed.(if(~speedMult == 0.5) { 1.0 } { 0.5 }) },
        $=, { ~setSpeed.(if(~speedMult == 2.0) { 1.0 } { 2.0 }) },
        // effects
        $[, { ~fxReverb = ~fxReverb.not; ~updateFX.(); ~updateDisplay.();
              "Reverb: %".format(~fxReverb).postln },
        $], { ~fxDelay  = ~fxDelay.not;  ~updateFX.(); ~updateDisplay.();
              "Delay: %".format(~fxDelay).postln },
        $\\,{ ~fxCrush  = ~fxCrush.not;  ~updateFX.(); ~updateDisplay.();
              "Crush: %".format(~fxCrush).postln },
        // analysis modes
        $o, { ~toggleOnsetRec.() },
        $m, { ~toggleAmpFx.() }
    );
};
"Keyboard shortcuts active (keep 'sdl keys' window focused)".postln;
"  p       : play/stop".postln;
"  1-4     : rec arm T0-T3  (or onset-arm when onset-rec mode is on)".postln;
"  q/w/e/r : overdub T0-T3".postln;
"  a/s/d/f : granular T0-T3".postln;
"  g/h/j/k : reverse T0-T3".postln;
"  z/x/v/b : clear T0-T3   c = clear all".postln;
"  - / =   : 0.5× / 2× speed (press again to return to 1×)".postln;
"  [ ] \\  : reverb / delay / crush".postln;
"  o       : onset-rec mode".postln;
"  m       : amp-fx mode".postln;
)
