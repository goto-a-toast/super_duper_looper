# super_duper_looper

SuperCollider looper for guitar / external audio input, controlled via **monome64** (mlr-style).

---

## 日本語ガイド

このリポジトリには 2 つの独立した SuperCollider パッチが入っています。

| ファイル | 概要 |
|---|---|
| `super_duper_looper.scd` | ギター等の外部入力をリアルタイムにルーピングする 4 トラック・ルーパー |
| `ambient_machine.scd` | サンプル＋ライブ入力を素材に自律的にアンビエント音楽を生成するマシン |

---

### super_duper_looper.scd の使い方

#### 起動手順

1. **serialosc を起動**し、monome64 を USB で接続する。
2. SuperCollider で `super_duper_looper.scd` を開き、**最初のブロック**（`( ... )`）を評価（`Cmd+Enter` または `Ctrl+Enter`）する。
3. monome の全 LED が一瞬点灯してから消え、プレイヘッド表示に切り替わったら起動完了。

#### 基本操作（monome64）

```
Col:   0    1    2    3    4      5       6     7
       ──────────────────────────────────────────
Row 0: [  Track 0 ループ範囲 ＆ 再生ヘッド        ]
Row 1: [  Track 1 ループ範囲 ＆ 再生ヘッド        ]
Row 2: [  Track 2 ループ範囲 ＆ 再生ヘッド        ]
Row 3: [  Track 3 ループ範囲 ＆ 再生ヘッド        ]
       ──────────────────────────────────────────
Row 4: [T0][T1][T2][T3][ONS][AMP][½×][2×]   ← 録音 Arm / モード切替
Row 5: [T0][T1][T2][T3][C0] [C1] [C2][C3]   ← オーバーダブ | クリア
Row 6: [▶/■][●][R0][R1][R2] [R3]  · [✕all] ← トランスポート | リバース
Row 7: [G0][G1][G2][G3][RV] [DL] [BC]  ·    ← グラニュラー | エフェクト
```

**Row 0–3（ループ範囲）**

- 1 回タップ → タップした列からループ開始（終端まで）
- 1 つ目を押したまま 2 つ目をタップ → その 2 点間をループ範囲に設定
- 点灯している列がループ範囲、暗い移動スポットが再生ヘッド

**Row 4（録音 Arm）**

| ボタン | 通常時 | Onset-rec モード ON 時 |
|---|---|---|
| Col 0–3 | トラック 0–3 の即時録音開始/停止 | オンセット Arm のオン/オフ |
| Col 4 | **オンセット録音モード** 切替 | — |
| Col 5 | **Amp-FX モード** 切替 | — |
| Col 6 | **½× 速度** 切替 | — |
| Col 7 | **2× 速度** 切替 | — |

**Row 5（オーバーダブ ＆ クリア）**

| ボタン | 動作 |
|---|---|
| Col 0–3 | トラック 0–3 のオーバーダブ切替 |
| Col 4–7 | トラック 0–3 のバッファをクリア |

**Row 6（トランスポート）**

| ボタン | 動作 |
|---|---|
| Col 0 | 再生 / 停止 |
| Col 1 | 全トラック同時録音 |
| Col 2–5 | トラック 0–3 のリバース切替 |
| Col 7 | 全トラッククリア |

**Row 7（グラニュラー ＆ エフェクト）**

| ボタン | 動作 |
|---|---|
| Col 0–3 | トラック 0–3 のグラニュラーモード切替 |
| Col 4 | リバーブ ON/OFF |
| Col 5 | ディレイ (350 ms) ON/OFF |
| Col 6 | ビットクラッシュ (4-bit) ON/OFF |

#### キーボードショートカット（monome なしでテスト可）

最後のブロック（キーボード shortcuts ブロック）を評価し、`sdl keys` ウィンドウをフォーカスしてから使用：

| キー | 動作 |
|---|---|
| `p` | 再生 / 停止 |
| `1`–`4` | トラック 0–3 録音 Arm |
| `q` `w` `e` `r` | オーバーダブ切替 |
| `a` `s` `d` `f` | グラニュラーモード切替 |
| `g` `h` `j` `k` | リバース切替 |
| `z` `x` `v` `b` | トラッククリア |
| `c` | 全クリア |
| `-` / `=` | 0.5× / 2× 速度 |
| `[` `]` `\` | リバーブ / ディレイ / ビットクラッシュ |
| `o` | オンセット録音モード |
| `m` | Amp-FX モード |

---

### ambient_machine.scd の使い方

`super_duper_looper.scd` とは**完全に独立したファイル**です。同時に起動することもできます。

#### サンプルの準備（任意）

`samples/` フォルダに `.wav` / `.aif` / `.flac` ファイルを置くと、起動時に自動ロードされます。  
サンプルがなくてもライブ入力とスナップショットだけで動作します。

#### 起動手順

1. `ambient_machine.scd` を SuperCollider で開く。
2. メインブロック（`( ... )`）を評価する。
3. コンソールに `loaded N samples` と `monome found` が表示され、LED が一瞬点灯したら起動完了。
4. monome の **Row 6 Col 0**（▶/■）を押してエンジンをスタートする。

> エンジンはスタートするまで音を出しません。サンプルのロードや FX の初期化は自動で行われます。

#### monome64 レイアウト

```
Col:    0    1    2    3    4    5    6    7
        ──────────────────────────────────────
Row 0:  [ Voice 0 アクティビティメーター        ]
Row 1:  [ Voice 1 アクティビティメーター        ]
Row 2:  [ Voice 2 アクティビティメーター        ]
Row 3:  [ Voice 3 アクティビティメーター        ]
        ──────────────────────────────────────
Row 4:  [G ][F ][R ][P ][--][--][--][--]   ← ボイスタイプ有効/無効
Row 5:  [D1][D2][D3][--][SB][SB][SB][SB]  ← 密度 1/2/3 ＋ ソースバイアス
Row 6:  [▶/■][SNAP][--][--][--][--][--][PANIC] ← トランスポート / スナップショット
Row 7:  [RV][DL][SAT][--][--][--][--][--]  ← グローバル FX
```

**Row 0–3（読み取り専用）**  
ボイスが発火するたびに点灯し、時間とともにフェードします。生成活動の視覚的なフィードバックです。

**Row 4（ボイスタイプ切替）**

| ボタン | ボイスタイプ | 内容 |
|---|---|---|
| Col 0 | **G** Granular | グラニュラー合成（GrainBuf） |
| Col 1 | **F** Freeze | スペクトル・フリーズ（PV_Freeze） |
| Col 2 | **R** Reverse | バッファの逆再生 |
| Col 3 | **P** Pitch | ピッチシフト再生 |

点灯 = 有効。すべて消すと音が出なくなります（少なくとも 1 つは ON にしてください）。

**Row 5（密度 ＆ ソースバイアス）**

| ボタン | 動作 |
|---|---|
| Col 0 | 密度 **1**（遅い、平均間隔 約 4 秒） |
| Col 1 | 密度 **2**（中程度、約 2.5 秒） |
| Col 2 | 密度 **3**（高密度、約 1 秒） |
| Col 4 | ソースバイアス 0（ライブ入力のみ） |
| Col 5 | ソースバイアス 1 |
| Col 6 | ソースバイアス 2 |
| Col 7 | ソースバイアス 3（サンプルのみ） |

**Row 6（トランスポート）**

| ボタン | 動作 |
|---|---|
| Col 0 | エンジン **スタート / ストップ** |
| Col 1 | **SNAP** — 今から 4 秒間ライブ入力をキャプチャ（次のボイス素材として使用） |
| Col 7 | **PANIC** — 現在鳴っている全ボイスを即時停止 |

**Row 7（グローバル FX）**

| ボタン | 動作 |
|---|---|
| Col 0 | **リバーブ** ON/OFF（大きなホール系） |
| Col 1 | **ディレイ** ON/OFF（3.5 秒ロングディレイ、フィードバックあり） |
| Col 2 | **サチュレーション** ON/OFF（ソフトな歪み） |

#### 演奏のヒント

- **Freeze + Reverb ON**: 一瞬の音が空間に溶ける、持続的なドローンに。
- **Granular + Density 3**: 音の霧。ループ素材を細かく刻んだ雲状テクスチャ。
- **SNAP してから Pitch**: 演奏した 4 秒をピッチシフトで変容させて空間に流す。
- **Density 1 + Reverse**: まばらに逆再生が現れる、夢の中のような空間。
- **Source Bias 0（ライブのみ）**: 今弾いている音がそのまま素材になる。インタラクティブなアンビエント。
- ソースバイアスを中間（Col 5–6）にすると、ライブ入力とサンプルが混在した予測不能な展開に。

#### 停止 ＆ クリーンアップ

ファイル末尾の **Cleanup ブロック**を評価する：

```supercollider
(
~aStopGen.();
~aCaptureNode !? { ~aCaptureNode.free };
~aFxNode      !? { ~aFxNode.free };
~voiceGroup   !? { ~voiceGroup.free };
~fxGroup      !? { ~fxGroup.free };
~mixBus       !? { ~mixBus.free };
~liveRollBuffer !? { ~liveRollBuffer.free };
~snapshotBuffers.do { |b| b !? { b.free } };
~sourcePool.do { |b| b !? { b.free } };
OSCdef(\aMonomeGrid).free;
~aClearLeds.();
"ambient_machine stopped".postln;
)
```

---

## Features

- **4 tracks** with independent audio buffers
- **mlr-style loop region control** — tap buttons to set loop start/end per track
- **Overdub** mode per track
- **Record arm** per track (or all at once)
- **Clear** per track or all
- Live **input monitor** through the effects chain
- **Granular mode** per track — slow-scan GrainBuf with position jitter
- **Global effects chain** — reverb, delay, bit crush
- **Amplitude-driven FX** — input level dynamically boosts reverb send and grain spread
- **Onset-triggered recording** — audio attack auto-starts recording on armed tracks
- **Reverse playback** per track
- **Variable speed** — 0.5×, 1×, or 2× global speed multiplier
- **Keyboard shortcuts** for testing without a monome

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

1. **Block 1** — queries serialosc for connected devices → note the reported port number.
2. **Block 2** — replace `devicePort` with the port from step 1, then run to get the prefix string.

### 3. Configure `super_duper_looper.scd`

Update the variables near the top of the file:

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
[ampAnalysis]                              ──► ~ampBus (kr)
[onsetDetect]                              ──► SendReply '/onset' ──► language

[inputMonitor / loopPlay / grainPlay]      ──► ~mixBus (ar mono)
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

**Reverse** (row 6 col 2–5 or `g`–`k`): scans backward through the loop region.
**Speed** (row 4 col 6–7 or `-`/`=`): multiplies the scan rate.

---

## Onset-Triggered Recording

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

## Amplitude-Driven FX

Press **row 4 col 5** (or `m`) to enable amp-fx mode.

- **Reverb send** is boosted when you play loudly (quiet = dry, loud = reverbed).
- **Grain spread** widens with input amplitude when granular mode is also active.

Combine with reverb toggle off for pure dynamic reverb (no constant wash).

---

## Reverse & Speed

| Control | Action |
|---|---|
| Row 6 col 2–5 | Toggle reverse for Track 0–3 |
| Row 4 col 6 | Half speed (0.5×) — press again to return to 1× |
| Row 4 col 7 | Double speed (2×) — press again to return to 1× |

Speed affects:
- `loopPlay`: phasor rate multiplied.
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
| `z` `x` `v` `b` | Clear T0–T3 |
| `c` | Clear all |
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
