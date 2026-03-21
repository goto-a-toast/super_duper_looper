# super_duper_looper

SuperCollider looper for guitar / external audio input, controlled via **monome64** (mlr-style).

## Features

- **4 tracks**, each with an independent audio buffer
- **mlr-style loop region control**: tap buttons on the grid to set loop start/end per track
- **Overdub** mode per track
- **Record arm** per track (or all at once)
- **Clear** per track or all
- Live **input monitor** (processed through the effects chain)
- **Granular mode** per track — slow-scan GrainBuf with position jitter
- **Global effects chain** — reverb, delay, bit crush
- **Amplitude-driven FX** — input level dynamically boosts reverb send + grain spread
- **Onset-triggered recording** — play a note to auto-start recording on armed tracks
- **Reverse playback** per track
- **Variable speed** — 0.5×, 1×, or 2× global speed multiplier
- Keyboard shortcuts for testing without a monome

---

## Requirements

| Dependency | Notes |
|---|---|
| [SuperCollider](https://supercollider.github.io/) | 3.11+ recommended |
| [serialosc](https://github.com/monome/serialosc) | OSC bridge for monome hardware |
| monome64 | 8×8 grid controller |

---

## Setup

### 1. Start serialosc

Make sure `serialosc` is running and your monome64 is connected via USB.

### 2. Find your device prefix and port

Open `monome_setup.scd` in SuperCollider and run the blocks in order:

1. **Block 1** – queries serialosc for connected devices → note the reported port number.
2. **Block 2** – replace `devicePort` with the port from step 1, then run to get the prefix string.

### 3. Configure `super_duper_looper.scd`

Update the following variables near the top of the file:

```supercollider
~loopDuration = 4.0;        // loop length in seconds
~inputBus     = 0;          // hardware input channel (0 = first input)
~outBus       = 0;          // hardware output channel
~monomeSendPort = 12002;    // your device's OSC port
~monomePrefix   = "/monome"; // your device's prefix
```

### 4. Boot the looper

Select the **first block** in `super_duper_looper.scd` and evaluate (`Cmd+Enter`).

---

## Signal Flow

```
[ampAnalysis]                           ──► ~ampBus (kr)
[onsetDetect]                           ──► SendReply '/onset' ──► language

[inputMonitor / loopPlay / grainPlay]   ──► ~mixBus (ar mono)
                                        ──► [globalFX]  ──► hw out (stereo)

globalFX  reads ~ampBus when amp-fx mode is on
grainPlay reads ~ampBus when amp-fx mode is on
```

---

## monome64 Layout

```
Col:   0    1    2    3    4      5       6     7
       ──────────────────────────────────────────
Row 0: [  Track 0 loop range & playhead         ]
Row 1: [  Track 1 loop range & playhead         ]
Row 2: [  Track 2 loop range & playhead         ]
Row 3: [  Track 3 loop range & playhead         ]
       ──────────────────────────────────────────
Row 4: [T0] [T1] [T2] [T3] [ONS] [AMP] [½×] [2×]  ← Rec arm / Onset arm + Modes
Row 5: [T0] [T1] [T2] [T3] [C0]  [C1]  [C2] [C3]  ← Overdub | Clear
Row 6: [▶/■][●]  [R0] [R1] [R2]  [R3]   ·  [✕all] ← Transport | Reverse
Row 7: [G0] [G1] [G2] [G3] [RV]  [DL]  [BC]  ·    ← Granular | Effects
```

### Row 0–3: Loop region (per track)

- **Tap a column** to set loop start (plays from there to end).
- **Hold first tap, tap another column** to set a custom range [min, max].
- **Playhead** = dark gap moving through the lit loop range.

### Row 4: Rec arm + modes

| Button | Normal mode | Onset-rec mode ON |
|---|---|---|
| Col 0–3 | Immediate record start/stop | Toggle onset-arm on/off |
| Col 4 | **Onset-rec mode** on/off | — |
| Col 5 | **Amp-FX mode** on/off | — |
| Col 6 | **½× speed** toggle | — |
| Col 7 | **2× speed** toggle | — |

### Row 5: Overdub & Clear

| Button | Action |
|---|---|
| Col 0–3 | Toggle overdub for Track 0–3 |
| Col 4–7 | Clear buffer for Track 0–3 |

### Row 6: Transport & Reverse

| Button | Action |
|---|---|
| Col 0 | Play / Stop (global) |
| Col 1 | Record all tracks simultaneously |
| Col 2–5 | Toggle **reverse** for Track 0–3 |
| Col 7 | Clear all tracks |

### Row 7: Granular mode & Effects

| Button | Action |
|---|---|
| Col 0–3 | Toggle **granular mode** for Track 0–3 |
| Col 4 | Toggle **reverb** |
| Col 5 | Toggle **delay** (350 ms) |
| Col 6 | Toggle **bit crush** (4-bit) |

---

## Granular Mode

`GrainBuf` replaces standard playback. A slow phasor scans through the active loop region; each grain is placed at scan position ± random jitter.

```supercollider
~grainRate   = 20;    // grains per second
~grainDur    = 0.08;  // grain size in seconds
~grainSpread = 0.06;  // position jitter (fraction of loop region)
~grainPitch  = 1.0;   // pitch ratio (0.5 = octave down, 2.0 = octave up)
```

**Reverse** (row 6 col 2-5 or `g`–`k`): scans backward through the loop region.
**Speed** (row 4 col 6-7 or `-`/`=`): multiplies the scan rate.

---

## Onset-Triggered Recording (Phase 3)

1. Press **row 4 col 4** to enable onset-rec mode (lit LED).
2. Press **row 4 col 0–3** to arm the tracks you want to record on.
3. Play a note — `Onsets.kr` detects the attack and starts recording on all armed tracks automatically.
4. Press record arm again to stop, or let it loop naturally.

Sensitivity is controlled by `~onsetThreshold` (0 = most sensitive, 1 = least). After changing it, restart the onset synth:

```supercollider
~onsetNode.free;
~onsetNode = Synth(\onsetDetect, [\inputBus, ~inputBus, \threshold, ~onsetThreshold],
                   target: ~playGroup);
```

---

## Amplitude-Driven FX (Phase 3)

Press **row 4 col 5** (or `m`) to enable amp-fx mode.

- **Reverb send** is boosted when you play loudly (quiet = dry, loud = reverbed).
- **Grain spread** widens with input amplitude when granular mode is also active.

Combine with reverb toggle off for pure dynamic reverb (no constant wash).

---

## Reverse & Speed (Phase 4)

| Control | Action |
|---|---|
| Row 6 col 2–5 | Toggle reverse for Track 0–3 |
| Row 4 col 6 | Half speed (0.5×) — press again to return to 1× |
| Row 4 col 7 | Double speed (2×) — press again to return to 1× |

Speed affects:
- `loopPlay`: Phasor rate multiplied.
- `grainPlay`: scan phasor rate multiplied (grain pitch unchanged).

---

## Keyboard Shortcuts

Evaluate the **keyboard shortcuts block** (last block) after booting; keep the small `sdl keys` window focused.

| Key | Action |
|---|---|
| `p` | Play / Stop |
| `1`–`4` | Rec arm T0–T3 (or onset-arm when onset-rec is on) |
| `q` `w` `e` `r` | Overdub T0–T3 |
| `a` `s` `d` `f` | Granular mode T0–T3 |
| `g` `h` `j` `k` | Reverse T0–T3 |
| `z` `x` `v` `b` | Clear T0–T3 · `c` = clear all |
| `-` / `=` | 0.5× / 2× speed (press again to return to 1×) |
| `[` `]` `\` | Reverb / Delay / Bit crush |
| `o` | Onset-rec mode |
| `m` | Amp-FX mode |

---

## Stopping / Cleanup

Evaluate the **Cleanup block** (second block):

```supercollider
(
~stopTransport.();
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
```

---

## Tips

- **Granular + reverb**: ambient washes from short recorded phrases.
- **Granular + bit crush**: lo-fi glitchy clouds.
- **Granular + amp-fx**: soft playing = tight grains; hard playing = wide spread clouds.
- **Onset-rec + reverse**: play a phrase, it records backward — instant backwards loop.
- **½× speed + granular + reverb**: slow, atmospheric textures.
- Lower `~grainDur` (e.g. `0.02`) for smoother clouds; raise it (e.g. `0.2`) for choppier stutter.
- `~onsetThreshold` defaults to `0.5`. Lower it (e.g. `0.3`) in quiet playing situations.
- Change `~loopDuration` **before** booting — it sets the buffer size.
