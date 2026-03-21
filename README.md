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
- **Global effects chain** — reverb, delay, bit crush (toggle per button)
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

Select the **first block** (`Ctrl+A`) in `super_duper_looper.scd` and evaluate (`Cmd+Enter`).

---

## Signal Flow

```
[loopPlay / grainPlay × 4]  ──►  ~mixBus (mono)  ──►  [globalFX]  ──►  hardware out (stereo)
[inputMonitor]              ──►  ~mixBus          (live input also goes through effects)
```

---

## monome64 Layout

```
Col:   0    1    2    3    4    5    6    7
       ─────────────────────────────────────
Row 0: [  Track 0 loop range & playhead   ]
Row 1: [  Track 1 loop range & playhead   ]
Row 2: [  Track 2 loop range & playhead   ]
Row 3: [  Track 3 loop range & playhead   ]
       ─────────────────────────────────────
Row 4: [T0] [T1] [T2] [T3]  ·    ·    ·    ·     ← Record arm toggle
Row 5: [T0] [T1] [T2] [T3] [C0] [C1] [C2] [C3]   ← Overdub | Clear
Row 6: [▶/■] [●all]  ·    ·    ·    ·    ·  [✕all] ← Transport
Row 7: [G0] [G1] [G2] [G3] [RV] [DL] [BC]  ·     ← Granular | Effects
```

### Row 0–3: Loop region (per track)

- **Tap a column** to set the loop start for that track (plays from there to end of row).
- **Hold first tap, tap another column** to set a custom loop range [min, max].
- The **playhead** appears as a dark gap moving through the lit loop range.

### Row 4: Record arm

| Button | Action |
|---|---|
| Col 0–3 | Toggle record on/off for Track 0–3 |

### Row 5: Overdub & Clear

| Button | Action |
|---|---|
| Col 0–3 | Toggle overdub for Track 0–3 |
| Col 4–7 | Clear buffer for Track 0–3 |

### Row 6: Transport

| Button | Action |
|---|---|
| Col 0 | Play / Stop (global) |
| Col 1 | Record all tracks simultaneously |
| Col 7 | Clear all tracks |

### Row 7: Granular mode & Effects

| Button | Action |
|---|---|
| Col 0–3 | Toggle **granular mode** for Track 0–3 |
| Col 4 | Toggle **reverb** (FreeVerb, room 0.85) |
| Col 5 | Toggle **delay** (CombL, 350 ms, ~50% mix) |
| Col 6 | Toggle **bit crush** (4-bit quantisation) |

---

## Granular Mode

When granular mode is active for a track, `GrainBuf` replaces normal playback:

- A slow phasor **scans through the active loop region** (one pass per loop duration).
- Each grain is placed at the scan position ± random **jitter** scaled to the loop length.
- Grain density, size, jitter, and pitch are global and adjustable at runtime:

```supercollider
~grainRate   = 20;    // grains per second  (higher = smoother / more CPU)
~grainDur    = 0.08;  // grain size in seconds
~grainSpread = 0.06;  // position jitter as fraction of loop region
~grainPitch  = 1.0;   // pitch ratio  (0.5 = octave down, 2.0 = octave up)
```

Change any of these in the SC interpreter and toggle granular off/on to apply.

---

## Keyboard Shortcuts (no monome needed)

Evaluate the **keyboard shortcuts block** at the bottom of the file, then keep the
small `sdl keys` window focused.

| Key | Action |
|---|---|
| `p` | Play / Stop transport |
| `1`–`4` | Toggle record on track 0–3 |
| `q` `w` `e` `r` | Toggle overdub on track 0–3 |
| `z` `x` `v` `b` | Clear track 0–3 |
| `c` | Clear all tracks |
| `a` `s` `d` `f` | Toggle granular mode on track 0–3 |
| `[` | Toggle reverb |
| `]` | Toggle delay |
| `\` | Toggle bit crush |

---

## Stopping / Cleanup

Evaluate the **Cleanup block** (second block) in `super_duper_looper.scd`:

```supercollider
(
~stopTransport.();
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
```

---

## Tips

- Set `~loopDuration` **before** booting — changing it requires re-allocating buffers.
- For longer loops increase `~loopDuration` (e.g. `8.0` or `16.0`).
- Use `~inputBus` to select a specific hardware input channel.
- Overdub preserves previous audio while adding new input on top.
- Try **granular + reverb** together for ambient washes from a short recorded phrase.
- Try **granular + bit crush** for lo-fi, glitchy textures.
- Lower `~grainDur` (e.g. `0.02`) for smoother granular clouds; raise it (e.g. `0.2`) for choppier stutter.
- The live input monitor is routed through the effects chain — playing live into reverb/delay while looping is intentional.
