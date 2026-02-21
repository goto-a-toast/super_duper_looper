# super_duper_looper

SuperCollider looper for guitar / external audio input, controlled via **monome64** (mlr-style).

## Features

- **4 tracks**, each with an independent audio buffer
- **mlr-style loop region control**: tap buttons on the grid to set loop start/end per track
- **Overdub** mode per track
- **Record arm** per track (or all at once)
- **Clear** per track or all
- Live **input monitor** passthrough
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
~loopDuration = 4.0;       // loop length in seconds
~inputBus     = 0;         // hardware input channel (0 = first input)
~outBus       = 0;         // hardware output channel
~monomeSendPort    = 12002; // your device's OSC port
~monomePrefix      = "/monome"; // your device's prefix
```

### 4. Boot the looper

Select all (`Ctrl+A`) in `super_duper_looper.scd` and evaluate (`Ctrl+Enter` or `Cmd+Enter`).

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
Row 4: [T0] [T1] [T2] [T3]  ·    ·    ·    ·    ← Record arm toggle
Row 5: [T0] [T1] [T2] [T3] [C0] [C1] [C2] [C3]  ← Overdub | Clear
Row 6: [▶/■]  [●all]  ·    ·    ·    ·    ·  [✕all] ← Transport
Row 7: (unused)
```

### Row 0–3: Loop region (per track)

- **Tap a column** to set the loop start point for that track.
- **Tap a column to the right** of the current start to extend the loop end.
- **Tap the same column twice** to collapse to a single-segment loop.
- The **playhead** lights up the current playback position.
- The **active loop range** is lit; everything outside is dark.

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

---

## Keyboard Shortcuts (no monome needed)

| Key | Action |
|---|---|
| `p` | Play / Stop transport |
| `1`–`4` | Toggle record on track 0–3 |
| `q`–`r` | Toggle overdub on track 0–3 |
| `z`–`v` | Clear track 0–3 |
| `c` | Clear all tracks |

> Note: keyboard shortcuts require focus in the SuperCollider IDE. Evaluate the
> shortcut block separately after booting.

---

## Stopping / Cleanup

Evaluate the **Cleanup** block at the bottom of `super_duper_looper.scd`:

```supercollider
(
~stopTransport.();
~monitorNode !? { ~monitorNode.free };
OSCdef(\monomeGrid).free;
~buffers.do { |b| b !? { b.free } };
~clearLeds.();
"super_duper_looper stopped".postln;
)
```

---

## Tips

- Set `~loopDuration` **before** booting. Changing it requires re-allocating buffers.
- For longer loops, increase `~loopDuration` (e.g. `8.0` or `16.0`).
- Use `~inputBus` to select a specific hardware input if you have an audio interface with multiple inputs.
- Overdub preserves previous audio (`preLevel: 1.0`) while adding new input on top.
