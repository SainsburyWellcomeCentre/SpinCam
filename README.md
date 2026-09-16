# spincam — multi-camera acquisition, TTL sync and camera control for MATLAB

`spincam` is a MATLAB package for recording synchronized video from FLIR / Point Grey
USB3 cameras (developed on 2 × **Chameleon3 CM3-U3-13Y3M**, firmware 1.13.3.00). It
provides:

* a **headless API** (`spincam.CameraManager`) that behavioural-control code such as
  **Bpod** can drive programmatically,
* three **synchronization modes**: passive TTL logging (default), hardware-triggered
  capture, and strobe output,
* per-frame **CSV metadata** (hardware timestamp, host timestamp, TTL state, drop flags),
* **video recording** to `.avi` (MJPEG or uncompressed) or `.mp4` (H.264) on native
  threads, lossless disk-speed `.raw`, or `.avi` through MATLAB's `VideoWriter`,
* an organised **storage layout**: `D:\videoData\<subject>\<session>\`, with each camera's
  video and CSV sharing one name, `<camera>_<file name>_<yyyyMMdd_HHmmss>`
  (e.g. `topview_mouse01_20260915_143012.avi` + `.csv`),
* sensible **defaults**: 100 fps with MJPEG video (sustainable for hours with two full-frame
  cameras), cameras named `topview` / `sideview`, passive TTL logging on Line0,
* **cropping** (region of interest) for higher frame rates: two cameras record 1024×900 at
  120 fps or 960×720 at 150 fps without dropped frames,
* **any Spinnaker installation folder and version**: found automatically or chosen in
  `spincam.setup`; the engine is compiled against the installed assemblies,
* a **live viewer UI** (`spincam.LiveViewer`) with side-by-side preview, per-frame TTL
  indicators, camera property and crop controls, sync configuration and a record button,
* a **mock backend** to try the API and the viewer without cameras attached.

---

## Contents

1. [Requirements](#1-requirements)
2. [Installation](#2-installation)
3. [Hardware: GPIO pinout and wiring](#3-hardware-gpio-pinout-and-wiring)
4. [Quick start](#4-quick-start)
5. [Synchronization modes](#5-synchronization-modes)
6. [Bpod integration](#6-bpod-integration)
7. [Output files and CSV schema](#7-output-files-and-csv-schema)
8. [API reference](#8-api-reference)
9. [Performance and limits](#9-performance-and-limits)
10. [Troubleshooting](#10-troubleshooting)
11. [Developer documentation](#11-developer-documentation)

---

## 1. Requirements

| Item | Needed? |
|---|---|
| Windows 10/11, 64-bit | **Required** |
| MATLAB R2023b or newer | **Required** (developed on R2025b). No toolboxes: the Image Acquisition Toolbox and the GenICam / Point Grey support packages are **not** used |
| .NET Framework 4.8 | **Required**; part of Windows 10/11 |
| Spinnaker SDK or SpinView **with its .NET components** | **Required**, in any folder (§2). Verified with 4.2.0.83. Its SpinVideo component is needed only for the `avi-mjpeg`, `avi-raw` and `mp4-h264` formats; the default `avi-mjpeg-mt` does not use it |
| C# compiler `csc.exe` (.NET Framework 4.x) | Ships with Windows; `spincam.setup` uses it once to build the acquisition engine |
| FLIR / Point Grey USB3 Vision cameras | Developed on 2 × Chameleon3 CM3-U3-13Y3M. Per-frame embedded TTL needs the camera's FRAME_INFO register; otherwise use `TtlSource = 'polled'` (§5) |
| FlyCapture2 | Not used. It can stay installed, but do not switch the cameras to its driver |

No `PATH` changes are needed: `spincam` locates the Spinnaker assemblies itself. The audit of
the development workstation is in [docs/development.md](docs/development.md#workstation-dependency-audit).

---

## 2. Installation

1. Put the `SpinCam` folder anywhere (this workstation:
   `C:\Users\harrislab\Documents\MATLAB\SpinCam`). Nothing in spincam depends on its location.
2. Install the **Spinnaker SDK** (or SpinView) **with its .NET components**, in any folder.
3. In MATLAB:

   ```matlab
   cd('C:\Users\harrislab\Documents\MATLAB\SpinCam')   % wherever you put it
   spincam.setup('SavePath', true)   % adds spincam to the path, finds Spinnaker, builds the engine
   ```

   If Spinnaker is not in a standard location, tell setup where it is (once; it is remembered):

   ```matlab
   spincam.setup('SpinnakerDir', 'D:\Programs\Teledyne\Spinnaker')   % root, bin64 or bin64\vs2015
   spincam.setup('BrowseSpinnaker', true)                              % choose the folder in a dialog
   ```

   Run interactively, setup also opens that dialog by itself when it cannot find Spinnaker.
4. Close **SpinView** before acquiring. A camera can only be streamed by one process at a
   time.
5. Make sure the data drive exists (default data root `D:\videoData`; change it in the
   viewer or with `cm.DataRoot`). Sub-folders are created when recording starts.
6. Optional: `runTests()` checks the installation without cameras, and `runTests('hardware')`
   with cameras attached and SpinView closed ([docs/development.md](docs/development.md#tests)).

`spincam.setup` prints a checklist: spincam folder, MATLAB, .NET, where Spinnaker was found and
how, whether SpinVideo is available, compiler, engine build, Spinnaker version and cameras.
Because .NET assemblies cannot be unloaded, **restart MATLAB after the engine was rebuilt**.

### Where spincam looks for Spinnaker

| Order | Source | Set by |
|---|---|---|
| 1 | Environment variable `SPINCAM_SPINNAKER_BIN` | Windows, or `setenv` before first use |
| 2 | `SpinnakerDir` in `spincam_config.json` in the spincam folder (machine-specific, not versioned) | `spincam.setup('SpinnakerDir', …)` / `'BrowseSpinnaker'` |
| 3 | `<Program Files>\Teledyne\Spinnaker`, `\FLIR Systems\Spinnaker`, `\Point Grey Research\Spinnaker` | Spinnaker installer |

Each may point to the Spinnaker root, its `bin64` folder, or the folder holding
`SpinnakerNET_v<toolset>.dll`; the highest toolset found below it is used. A configured folder
(1 or 2) that contains no assemblies is reported by `spincam.setup` and skipped.

### Other Spinnaker versions

* The acquisition engine is **compiled on your machine against the installed** Spinnaker
  assemblies. After a Spinnaker update, or when spincam is pointed at another folder, it is
  rebuilt automatically the next time it loads; restart MATLAB afterwards.
* Without `SpinVideoNET` the engine is built without SpinVideo: `avi-mjpeg-mt`, `raw`,
  `matlab-avi`, `matlab-mjpeg` and `none` still work, while `avi-mjpeg`, `avi-raw` and `mp4-h264` raise
  `spincam:recorder:noSpinVideo`.
* **Verified with Spinnaker 4.2.0.83 only.** `spincam.setup` notes when another version is
  installed. If the engine build fails, the compiler message names the missing .NET member
  (§10). After installing another version, run `spincam.setup` and `runTests('hardware')` once.

---

## 3. Hardware: GPIO pinout and wiring

Chameleon3 USB3 9-pin JST GPIO connector (header BM09B-NSHSS-TBT, plug NSHR-09V-S).
Source: *Chameleon3 USB3 Technical Reference* v5.0, Table 6.1, numbered **as seen
looking at the rear of the camera**. The "reverse count" column numbers the same wires
from the other end of the connector, which is how the current BNC wiring was described
(yellow = pin 1, brown = pin 3).

| Manual pin | Reverse count | Wire | Function | Spinnaker line | Notes |
|:-:|:-:|---|---|---|---|
| 1 | 9 | Red | VEXT | – | External power 5–24 V DC |
| 2 | 8 | Black | GND | – | Ground for non-isolated I/O, VEXT, +3.3 V |
| 3 | 7 | White | +3.3 V | – | Output, fused at 150 mA |
| 4 | 6 | Green | GPIO3 | **Line3** | Input / Output (also serial Tx) |
| 5 | 5 | Purple | GPIO2 | **Line2** | Input / Output (also serial Rx) |
| 6 | 4 | Black | GND | – | Ground |
| 7 | **3** | **Brown** | **OPTO_GND** | – | Ground for opto-isolated pins |
| 8 | 2 | Orange | OPTO_OUT | **Line1** | Opto-isolated output (open collector) |
| 9 | **1** | **Yellow** | **OPTO_IN** | **Line0** | Opto-isolated input |

**Current wiring (yellow + brown → BNC) = opto-isolated input Line0 referenced to
OPTO_GND.** This is correct for Mode A (passive logging) and Mode B (trigger input). It
is the default `TtlLine = 'Line0'`.

Line capabilities reported by the camera (`LineMode` entries):

| Line | Input | Output | Trigger source | `LineSource` options when output |
|---|:-:|:-:|:-:|---|
| Line0 | ✔ | – | ✔ | – |
| Line1 | – | ✔ | – | `ExposureActive`, `ExternalTriggerActive`, `UserOutput1` |
| Line2 | ✔ | ✔ | ✔ | determined at runtime |
| Line3 | ✔ | ✔ | ✔ | determined at runtime |

Electrical limits (Technical Reference v5.0, §6.7, Tables 6.2 and 6.3; operating range).
FLIR gives the opto-isolated limits for a camera powered over USB, not through VEXT:

* Opto-isolated **input** (Line0): 0–30 V (absolute max −70 V / +40 V), with over-current
  protection. The input is not a logic gate: OPTO_IN drives a series diode and a FET current
  limiter into an optocoupler LED that returns on OPTO_GND (Figure 6.2). FLIR publishes
  **no input-low/high threshold**.
  * **5 V TTL: use this.** Bpod BNC outputs (0 V / 5 V) connect directly, without a resistor.
  * **3.3 V logic: not guaranteed.** It lies inside the rated range, but the diode, limiter
    and LED consume part of it, and there is no published threshold. It has not been tested
    on this rig. Level-shift to 5 V (e.g. a 74HCT/74AHCT buffer powered from 5 V) or confirm
    with `spincam.tools.verifyTtlInput` before relying on it.
  * Higher signals (e.g. 12 V or 24 V) are within range.
* Opto-isolated **output**: 0–24 V, ≤ 25 mA, **open collector, so it needs a pull-up
  resistor**. For example, 1 kΩ from OPTO_OUT to an external +5 V, with the external
  ground on OPTO_GND.
* Non-isolated Line2/Line3: 0–24 V, ≤ 25 mA sinking. Use a pull-up when driving TTL
  inputs.
* ⚠ Connect **OPTO_GND first**, before applying voltage to an opto line.
* ⚠ Never connect a voltage source to a pin configured as an **output**.
* The camera rejects trigger pulses shorter than 16 pixel-clock ticks by default
  (debouncer).

### Wiring per mode

| Mode | Wires | Configuration |
|---|---|---|
| A: passive TTL logging | Yellow (Line0) = signal (5 V TTL; 3.3 V not guaranteed), Brown = OPTO_GND | `configureSync('passive')` (default) |
| B: hardware trigger | Yellow (Line0) = trigger (5 V TTL; 3.3 V not guaranteed), Brown = OPTO_GND | `configureSync('triggered')` |
| C: strobe out (isolated) | Orange (Line1) = output + pull-up, Brown = OPTO_GND | `configureSync('strobe','StrobeLine','Line1')` |
| C: strobe out (non-isolated) | Purple (Line2) = output, Black = GND | `configureSync('strobe','StrobeLine','Line2')` |

Mode C can run alongside TTL logging on Line0: the yellow/brown input stays active.

---

## 4. Quick start

### GUI

```matlab
v = spincam.LiveViewer();                         % real cameras
v = spincam.LiveViewer('Backend', 'mock');        % no hardware needed
```

The viewer connects all attached cameras, sets them to **100 fps**, names them `topview` and
`sideview`, and selects passive TTL logging.

| Area | What it shows / does |
|---|---|
| **Header** | **▶ Preview** streams without saving. **● Record** saves every connected camera and turns into **■ Stop recording**. The badge shows `IDLE`, `PREVIEW`, `● REC mm:ss`, or `ARMED · waiting for TTL` (trigger type *start*). Messages and errors appear next to it. |
| **Camera tiles** (left) | Live image per camera titled `<name> · <serial>`, with frame number, measured fps and missed frames. The **TTL** badge turns green when the TTL input was high in the latest frame, which is a quick wiring check. |
| **Statistics table** | Per camera: fps, frames received / missed / written, writer drops, writer queue, last TTL state. |
| **Recording** tab | Cameras to connect and their names; where to save; format; a preview of the exact folder and file names. See the table below. |
| **Camera** tab | Frame rate, exposure, gain, black level, gamma: slider, number and *Auto* check-box. *Apply to* selects all cameras or one. **Crop**: X, Y, Width, Height (or *Centre on the sensor*), then *Apply crop* or *Full frame*. A dashed box previews the crop on the full-frame image, and the panel shows how fast MJPEG can record at that size. |
| **Sync** tab | Mode A / B / C with a description and wiring hint. **Only the fields the selected mode uses are enabled**; the others are greyed out, and their panel title says which mode uses them. See §5. |

**Recording tab fields**

| Field | Default | Meaning |
|---|---|---|
| Connect (check-box) | all attached cameras | Tick to open a camera, untick to release it. |
| Name (file prefix) | `topview` for the lower serial number, `sideview` for the next | Prepended to that camera's file names. Letters, digits, `-` and `_` (anything else becomes `_`); must be unique. On this rig, serial order gives 24226657 = `topview`, 24226887 = `sideview`. **Check the tiles and rename if the views are swapped.** |
| Data root | `D:\videoData` | Top-level folder. |
| Subject | *(empty — required)* | Animal / subject ID. Creates `<data root>\<subject>`. Record is refused until it is filled in. |
| Session | today, `yyyyMMdd` | Creates `<subject>\<session>`. Leave it empty to save directly in the subject folder. |
| File name | follows *Subject* | Middle part of every file name. Typing your own text stops it following the subject; clear it for `<camera>_<date_time>`. |
| Append _date_time | on | Adds the recording start time (`yyyyMMdd_HHmmss`) so repeated recordings never overwrite each other. |
| Format | `avi-mjpeg-mt` | Video format (see [§8 `VideoRecorder`](#spincamvideorecorder-handle)). |
| Files | – | Read-only preview of the folder and names the next recording will create. |

Typical session: check that each tile shows the view its name says → type the subject →
leave Sync on *A · Passive* → **Preview** and adjust exposure → **Record** → **Stop
recording**. Pending Sync-tab changes are applied automatically when you press Preview or
Record.

### Headless

```matlab
cm = spincam.CameraManager();                      % Backend 'spinnaker', DefaultFrameRate 100
disp(cm.listCameras())                             % Serial, Name, Model, Firmware, Speed, Connected
cm.connect();                                      % all cameras -> 100 fps, topview / sideview
cm.setCameraName('24226887', 'topview');           % optional: fix names to the physical views
cm.setCameraName('24226657', 'sideview');
cm.setProperty('ExposureTime', 5000);              % µs; switches ExposureAuto off (≤ 1/100 s)
cm.setProperty('Gain', 0);
cm.configureSync('passive', 'TtlLine', 'Line0');   % the default; shown for clarity

folder = cm.sessionFolder('mouse01', 'day1');      % D:\videoData\mouse01\day1
plan = cm.startRecording(folder, 'mouse01');       % topview_mouse01_<datetime>.avi + .csv, ...
pause(10);
summary = cm.stopRecording();                      % struct: files, frame counts, drops
delete(cm);                                        % releases cameras (always do this)
```

### Crop (region of interest)

Encoding speed and file size scale with the number of pixels, so a crop lets you record
faster. Crop on the viewer's Camera tab or in code. Cropping is refused while recording;
preview restarts by itself.

```matlab
cm.setRoi([0 0 1024 900], [], 'Center', true);    % all cameras: centred 1024×900
cm.setProperty('FrameRate', 120);                  % MJPEG keeps up at this size
cm.setRoi([200 100 960 720], {'sideview'});        % one camera: [x y width height]
cm.getRoi()                                        % one [x y width height] row per camera
cm.resetRoi();                                     % full frame again
```

* `x` and `y` are 0-based offsets from the top-left corner of the sensor. The Chameleon3
  requires width in steps of 16, height in steps of 2, `x` in steps of 8 and `y` in steps of 2.
  `setRoi` rounds down to those steps, keeps the crop on the sensor, returns what the camera
  accepted, and warns (`spincam:roi:adjusted`) if that differs from the request.
* The crop applies to preview, video and the embedded TTL (still decoded for every frame),
  and is saved in `_session.json` (`Width`, `Height`, `OffsetX`, `OffsetY`).
* The camera's own limit stays **150.7 fps** for every crop size; cropping helps the encoder
  and the shared USB controller keep up. Measured with both cameras and MJPEG (§9):
  1024×900 at 120 fps and 960×720 at 150 fps, 0 missed frames and 0 writer drops.
* The camera keeps a crop until it is changed or the camera is power-cycled, so a crop set
  in one session is still active in the next. The Camera tab shows the current crop.

### Mock (no cameras)

```matlab
cm = spincam.CameraManager('Backend', 'mock', 'NumCameras', 2);
cm.DataRoot = fullfile(tempdir, 'spincam_demo');
cm.connect();
cm.startRecording(cm.sessionFolder('mock01', 'test'), 'mock01');
pause(3); s = cm.stopRecording(); delete(cm);
T = spincam.io.mergeFrameLogs(s);                 % both cameras, with a Name column
```

---

## 5. Synchronization modes

Sync settings apply to every connected camera. In the viewer use the **Sync** tab; in code
call `cm.configureSync(mode, Name, Value, ...)` (or set properties on `cm.Sync` and call
`cm.applySync()`). Changing sync while previewing restarts the streams; it is refused while
recording. `spincam.SyncController.optionsFor(mode)` returns the options a mode uses — the
same list the viewer uses to enable fields. Options that a mode does not use are ignored.

### Which mode?

| Mode | Use it when | Who decides when frames are taken | Connect |
|---|---|---|---|
| **A · `passive`** (default) | You need to know, for every frame, whether a TTL (e.g. a Bpod trial or stimulus pulse) was high, so that video can be aligned to behaviour | The camera, free-running at *Frame rate* (100 fps) | TTL output → **yellow** (Line0), ground → **brown** |
| **B · `triggered`** | An external device must decide when each frame is exposed (`frame`), or when the recording starts (`start`) | The pulses (`frame`) / the camera (`start`) | Trigger output → **yellow** (Line0), ground → **brown** |
| **C · `strobe`** | Another device (LED driver, DAQ, Bpod input) needs a pulse for every frame, or every N-th frame | The camera, free-running | **Orange** (Line1) + pull-up → device input, ground → **brown** |

### Field reference

"Used in" is exactly when the Sync-tab field is enabled.

| Sync-tab field | `SyncController` option | Used in | Default | What it means |
|---|---|---|---|---|
| Mode | `Mode` | – | `'passive'` | `'passive'` / `'A'`, `'triggered'` / `'B'`, `'strobe'` / `'C'`. |
| TTL source | `TtlSource` | A, B, C | `'embedded'` | How each frame's `TTL_State` is obtained. **`embedded`**: the camera writes its GPIO pin state into the frame at the end of exposure (hardware-latched; exact; recommended). **`polled`**: a host thread reads `LineStatusAll` roughly every millisecond, and each frame gets the latest reading (host timing; fallback for cameras without FRAME_INFO). **`none`**: not logged; `TTL_State` = −1. |
| TTL line | `TtlLine` | A and C unless *TTL source* is `none`; always in B | `'Line0'` | The input whose state is logged, and in mode B also the trigger input. `Line0` = yellow wire (opto-isolated, the current BNC). `Line2` / `Line3` = purple / green (non-isolated). |
| *(code only)* | `EmbedFrameCounter` | A, B, C | `true` | Also embed the camera frame counter, a second detector for lost frames (`FramesMissedBefore`). |
| Trigger type | `TriggerType` | B | `'frame'` | **`frame`**: `TriggerMode=On`; each active edge on *TTL line* exposes one frame. The *Frame rate* setting is then ignored: frames arrive at the pulse rate, and pulses faster than the camera can expose are ignored by the camera. **`start`**: cameras free-run as in mode A, but after Record the recording is *armed* (badge `ARMED`). The first frame whose TTL is high after a low frame becomes frame 0 of the files. This is decided from the embedded GPIO state, so it is frame-accurate. (The CM3 has no `AcquisitionStart` trigger.) |
| Activation | `TriggerActivation` | B | `'RisingEdge'` | Edge that exposes a frame (type `frame`). The camera's factory default is FallingEdge; spincam always sets it. |
| Exposure mode | `ExposureMode` | B | `'Timed'` | **`Timed`**: each triggered exposure lasts *Exposure* from the Camera tab. **`TriggerWidth`**: the exposure lasts as long as the pulse is active (bulb). |
| Delay (µs) | `TriggerDelay_us` | B | `0` | Delay from the trigger edge to the start of exposure. |
| Strobe line | `StrobeLine` | C | `'Line1'` | Output line. **Line1** = orange, opto-isolated open collector: needs a pull-up (e.g. 1 kΩ to +5 V), with ground on brown. **Line2 / Line3** are switched to outputs: never connect a voltage source to them. Must differ from *TTL line*. |
| Signal | `StrobeSource` | C | `'ExposureActive'` | **`ExposureActive`**: the output is active while the sensor exposes. **`ExternalTriggerActive`**: active while the trigger input is active. |
| Every N frames | `StrobeEveryN` | C | `1` | 1–16. For N > 1 the camera's hardware strobe pattern (`GPIO_STRPAT_CTRL 0x110C`, Count_Period = N, first slot only) fires on every N-th frame. |
| Duration (µs) | `StrobeDuration_us` | C | `0` | Pulse length; 0 = as long as the exposure. |
| Delay (µs) | `StrobeDelay_us` | C | `0` | Delay after the start of exposure. |
| Invert | `StrobeInvert` | C | `false` | Active-low output (`LineInverter`). |

### Mode A: `'passive'` — TTL logging (default)

The cameras free-run at *Frame rate*. For every frame the camera latches its input pins at
the **end of that frame's exposure**, and the engine writes them to the frame's CSV row:

* `TTL_State` — state of *TTL line* (0 or 1; −1 if unavailable),
* `GPIO_LineStatus` — all four lines as a bitfield (bit *k* = Line *k*).

Unconnected non-isolated lines float high, so `GPIO_LineStatus` is typically 8 or 12 even
with no TTL; only `TTL_State` matters.

```matlab
cm.configureSync('passive');                                % TtlLine Line0, TtlSource embedded
...
T = spincam.io.readFrameLog(summary.Cameras(1).CsvFile);
onsetRows = find(diff([0; T.TTL_State]) == 1);              % first frame with TTL high
onsetVideoFrames = T.VideoFrameIndex(onsetRows);            % 0-based frame in the .avi
onsetTimes_us = T.HardwareTimestamp_us(onsetRows);          % camera clock
```

* **Timing resolution**: a TTL edge lies between the end of exposure of the previous frame
  and the end of exposure of the onset frame, i.e. within one frame period (10 ms at
  100 fps, 8.3 ms at 120 fps).
* **Pulse-width rule**: a pulse is only seen if it is high at some end-of-exposure instant.
  Use pulses **longer than one frame period**, ≥ 1.5× recommended: **≥ 15 ms at 100 fps**
  (≥ 12.5 ms at 120 fps, ≥ 10 ms at 150 fps).
  The Bpod example uses 50 ms.
* **Checking the wiring**: in the viewer, pulse the input and watch the tiles' **TTL**
  badge; or run `spincam.tools.verifyTtlInput(10)` and pulse during the 10 s. It reports
  rising and falling edges per camera.

The camera writes the pin state into the first pixels of each frame, so the TTL state is
latched by camera hardware rather than sampled by the host
([docs/architecture.md](docs/architecture.md#how-per-frame-ttl-state-is-captured)). Those
pixels are restored in the saved video (`ScrubEmbeddedPixels`).

Embedded TTL decoding was verified on both cameras at 100 and 120 fps full frame and with
cropped frames up to 150 fps, but **no TTL source was connected** during those checks: detection of
real edges is so far covered only by the synthetic-camera tests. Confirm your wiring once with
Bpod pulses and `verifyTtlInput`. Details:
[docs/performance.md](docs/performance.md#hardware-validation-records).

### Mode B: `'triggered'`

```matlab
cm.configureSync('triggered', 'TriggerType', 'frame', 'TriggerActivation', 'RisingEdge');
cm.configureSync('triggered', 'TriggerType', 'start');      % free-run, start at first rising edge
```

* In `'frame'` mode the TTL state is still logged, but it is sampled at the end of
  exposure, which may be after a short trigger pulse has already fallen.
* In `'frame'` mode the video container frame rate cannot be read from the camera; set
  `cm.Recorder.FrameRate` to the pulse rate, otherwise 30 fps is written to the file (the
  CSV timestamps are unaffected).
* No pulses → no frames. The viewer then shows no image, and the CSV stays empty.

### Mode C: `'strobe'`

```matlab
cm.configureSync('strobe', 'StrobeLine', 'Line1', 'StrobeEveryN', 1);
```

TTL logging on *TTL line* continues exactly as in mode A. Check the output waveform on an
oscilloscope before relying on it experimentally.

---

## 6. Bpod integration

Acquisition runs on native threads, so it keeps going while `RunStateMachine` blocks
MATLAB. A typical wiring is **Bpod BNC output 1 → camera Line0 (yellow/brown)**; Bpod BNC
outputs are 5 V TTL, which the opto-isolated input accepts directly (§3). Each
trial raises the BNC for 50 ms, and the per-frame `TTL_State` column then marks trial
onsets in the video.

```matlab
function SpinCamBpodProtocol
global BpodSystem

%% --- camera setup (once per session) ---
subject = BpodSystem.GUIData.SubjectName;
[~, session] = fileparts(BpodSystem.Path.CurrentDataFile);   % e.g. mouse01_Task_20260915_143012
cm = spincam.CameraManager();              % 100 fps, cameras named topview / sideview
cm.connect();
cm.setProperty('ExposureTime', 4000);
cm.configureSync('passive', 'TtlLine', 'Line0');    % Bpod BNC1 -> yellow/brown
cm.Recorder.Format = 'avi-mjpeg-mt';       % native, multi-core encoder: safe while MATLAB is blocked
cm.startRecording(cm.sessionFolder(subject, session), subject);
cleanup = onCleanup(@() stopCameras(cm));  % runs even if the protocol errors

MaxTrials = 200;
for currentTrial = 1:MaxTrials
    sma = NewStateMachine();
    sma = AddState(sma, 'Name', 'SyncPulse', 'Timer', 0.05, ...
        'StateChangeConditions', {'Tup', 'ITI'}, ...
        'OutputActions', {'BNC1', 1});                % 50 ms TTL -> camera Line0
    sma = AddState(sma, 'Name', 'ITI', 'Timer', 2, ...
        'StateChangeConditions', {'Tup', 'exit'}, 'OutputActions', {});
    SendStateMachine(sma);
    cm.logEvent('TrialStart', currentTrial);          % host-clock marker
    RawEvents = RunStateMachine;                      % MATLAB blocks; cameras keep recording
    if ~isempty(fieldnames(RawEvents))
        BpodSystem.Data = AddTrialEvents(BpodSystem.Data, RawEvents);
        SaveBpodSessionData;
    end
    HandlePauseCondition;
    if BpodSystem.Status.BeingUsed == 0
        return
    end
end
end

function stopCameras(cm)
if isvalid(cm)
    if strcmp(cm.State, 'recording'), cm.stopRecording(); end
    delete(cm);
end
end
```

A runnable copy is in `examples/bpod/SpinCamBpodProtocol.m`. Aligning trials afterwards:

```matlab
folder = 'D:\videoData\mouse01\mouse01_Task_20260915_143012';
info = dir(fullfile(folder, '*_session.json'));
session = jsondecode(fileread(fullfile(folder, info(1).name)));
T = spincam.io.mergeFrameLogs(folder, session.Recording.BaseName);
top = T(T.Name == "topview", :);
onsets = top(diff([0; top.TTL_State]) == 1, :);   % first frame of each 50 ms trial pulse
```

---

## 7. Output files and CSV schema

### Folder and file names

`plan = cm.startRecording(folder, fileName)` records every connected camera into `folder`
(created if necessary). The viewer, the examples and `cm.sessionFolder(subject, session)`
use the layout `<DataRoot>\<subject>\<session>`:

```
D:\videoData\mouse01\20260915\
├── topview_mouse01_20260915_143012.avi      video of camera "topview"
├── topview_mouse01_20260915_143012.csv      one row per frame of that camera
├── sideview_mouse01_20260915_143012.avi
├── sideview_mouse01_20260915_143012.csv
├── mouse01_20260915_143012_events.csv       cm.logEvent rows (shared host clock)
└── mouse01_20260915_143012_session.json     settings, sync, camera names, summary
```

Name parts, for camera stem `<camera>_<fileName>_<datetime>`:

| Part | Source | Notes |
|---|---|---|
| `<camera>` | `CameraDevice.Name` (`cm.setCameraName`, Recording tab) | Defaults `cm.DefaultCameraNames = {'topview','sideview'}`, assigned in ascending serial order among attached cameras; further cameras are `cam<serial>`. Names set with `setCameraName` are kept when a camera is disconnected and reconnected. |
| `<fileName>` | 2nd argument of `startRecording` / *File name* field | Optional. Characters other than letters, digits, `-`, `_` become `_`. |
| `<datetime>` | Recording start, `cm.DateTimeFormat` (`yyyyMMdd_HHmmss`) | Omitted when `cm.AppendDateTime = false`. |

`summary.BaseName` is `<fileName>_<datetime>` (`recording` if both are empty). It prefixes
the shared `_events.csv` / `_session.json` files and is what `mergeFrameLogs(folder, baseName)`
expects. `startRecording` refuses to overwrite existing files (`spincam:manager:filesExist`)
unless `cm.Overwrite = true`.

| File | Content |
|---|---|
| `<stem>.avi` / `<stem>.mp4` | `avi-mjpeg-mt` writes `<stem>.avi` directly, as one OpenDML (AVI 2.0) file of any length. The SpinVideo formats (`avi-mjpeg`, `avi-raw`, `mp4-h264`) always write `<stem>-0000.avi` (or `.mp4`); when the recording stops, spincam renames it to `<stem>.avi` (`.mp4`) so it matches the CSV. With `MaxFileSizeMB > 0`, the numbered segments (`-0000`, `-0001`, …) are kept. The `matlab-*` formats write `<stem>.avi` directly. The final names are in `summary.Cameras(k).VideoFiles`. |
| `<stem>.raw` + `<stem>.raw.json` | `'raw'` format: 8-bit frames concatenated row-major (frame *i*, 0-based, starts at byte *i*·W·H), with geometry and frame rate in the JSON sidecar. Read it with `spincam.io.RawVideoReader`; convert it with `spincam.io.rawToAvi`. |
| `<stem>.csv` | One row per frame received while recording (schema below). |
| `<base>_events.csv` | `HostTime_s, HostTimestamp_datetime, Event, Value` rows from `cm.logEvent`, plus `RecordingStart` / `RecordingStop`. |
| `<base>_session.json` | Snapshot of camera settings and names, sync, recorder, versions, host-clock epoch, and the recording summary. |

### Frame log (`<stem>.csv`) columns

| Column | Type | Description |
|---|---|---|
| `FrameNumber` | int | 0-based index of rows in this recording |
| `CameraID` | string | Camera serial number (the camera name is in the file name and `_session.json`) |
| `HardwareTimestamp_us` | int | Camera timestamp (`IManagedImage.TimeStamp`, device clock) in µs |
| `HostTimestamp_datetime` | ISO-8601 | Host wall-clock time when the frame arrived, µs resolution with UTC offset (monotonic high-resolution clock anchored at engine start) |
| `TTL_State` | 0/1/−1 | State of `TtlLine` for this frame (−1 = not available) |
| `DroppedFrameFlag` | 0/1 | 1 if frames were lost immediately before this one, this frame was incomplete, or it could not be written to video |
| `DeviceFrameID` | int | Stream frame ID from the camera (gaps = lost frames) |
| `EmbeddedFrameCounter` | int | Camera-internal frame counter (−1 if disabled) |
| `FramesMissedBefore` | int | Number of frames lost between the previous row and this row |
| `HostTime_s` | float | Seconds on the shared host clock (the same clock as `_events.csv`) |
| `GPIO_LineStatus` | int | Bitfield, bit *k* = Line *k* (−1 unknown) |
| `TTL_Source` | string | `embedded`, `polled` or `none` |
| `VideoFrameIndex` | int | 0-based index into the video file, −1 if not written |
| `WriterDropFlag` | 0/1 | 1 if the writer queue overflowed |
| `IncompleteFlag` | 0/1 | 1 if Spinnaker reported an incomplete image |

The first six columns are always present, in this order. Set
`cm.Recorder.CsvExtended = false` to write only those six.

Reading helpers:

```matlab
T  = spincam.io.readFrameLog('D:\videoData\mouse01\20260915\topview_mouse01_20260915_143012.csv');
TT = spincam.io.mergeFrameLogs(summary);        % all cameras, Name column, sorted by HostTime_s
TT = spincam.io.mergeFrameLogs('D:\videoData\mouse01\20260915', 'mouse01_20260915_143012');
E  = spincam.io.readEventLog('D:\videoData\mouse01\20260915\mouse01_20260915_143012_events.csv');
```

---

## 8. API reference

### `spincam.CameraManager` (handle)

| Member | Description |
|---|---|
| `cm = spincam.CameraManager(Name,Value)` | `'Backend'` (`'spinnaker'` or `'mock'`); `'FrameRate'` (100) = `DefaultFrameRate`, `[]` to leave cameras unchanged. Mock only: `'NumCameras'` (2), `'Resolution'` ([1024 1280]), `'TtlHalfPeriodFrames'` (30), `'DropEvery'`, `'IncompleteEvery'` |
| `T = listCameras()` | Table: Serial, Name, Model, Firmware, Speed, Connected |
| `connect(ids)` / `disconnect(ids)` | `ids`: cellstr of serials or names, index vector, or omitted for all. `connect` names new cameras and sets `DefaultFrameRate` (shortening a manual exposure that would not fit in the frame period) |
| `cam = camera(id)` | `spincam.CameraDevice` by index, serial or name |
| `setCameraName(id, name)` | File-name prefix for a camera; must be unique; remembered across reconnects |
| `setProperty(name, value, ids)` | Friendly or raw GenICam name; applies to all cameras when `ids` is omitted |
| `v = getProperty(name, ids)` | Vector (numeric) or cell (enum/string) |
| `roi = setRoi([x y w h], ids, 'Center', tf)` | Crop (§4). Refused while recording; preview restarts. Returns one accepted `[x y w h]` row per camera |
| `roi = getRoi(ids)` / `roi = resetRoi(ids)` | Current crop / full frame |
| `configureSync(mode, Name,Value)` / `applySync()` | See §5 |
| `startPreview()` / `stopPreview()` | Stream without recording |
| `[frames, meta] = getLatestFrames(ids)` | Cell of `uint8` H×W images; `meta` struct array (FrameId, TTL, Width, Height) |
| `folder = sessionFolder(subject, session)` | `<DataRoot>\<subject>\<session>` (session optional; subject required). Does not create it |
| `n = plannedFileNames(fileName, when)` | `n.Cameras{k}` = stem for `Cameras(k)`, `n.Shared` = events/session prefix |
| `plan = startRecording(folder, fileName)` | Starts (or arms, for `TriggerType 'start'`) recording on all connected cameras. `plan`: Folder, BaseName, FileName, StartTime, Format, Gate, EventsFile, SessionFile, Cameras (Serial, Name, VideoFile, CsvFile) |
| `summary = stopRecording()` | Flushes, closes and renames files; returns plan fields plus Duration_s and per-camera Serial, Name, VideoFiles, CsvFile, FramesLogged, FramesWritten, WriterDrops, FramesMissed, FramesIncomplete, QueuePeak, GateOpened, Error |
| `T = getStats()` | Table: Serial, Name, fps, received, missed, written, writer drops, queue depth, TTL, state, errors |
| `logEvent(name, value)` | Appends to `<base>_events.csv` using the engine's host clock |
| `t = hostTime()` | Current host-clock time in seconds (the same clock as `HostTime_s`) |
| Settable properties | `DataRoot` (`'D:\videoData'`), `AppendDateTime` (true), `DateTimeFormat` (`'yyyyMMdd_HHmmss'`), `DefaultFrameRate` (100), `DefaultCameraNames` (`{'topview','sideview'}`), `Overwrite` (false), `PreviewMaxHz` (30), `StopTimeoutSeconds` (120), `ResetOnDisconnect` (true), `Recorder` (`spincam.VideoRecorder`), `Sync` (`spincam.SyncController`) |
| Read-only properties | `Cameras`, `State` (`idle`, `preview`, `recording`), `Backend`, `CurrentRecording`, `LastRecording` |
| `spincam.CameraManager.cleanName(text)` | The name cleaning used for camera names and file names |

### `spincam.CameraDevice` (handle; obtained from `cm.camera(...)`)

| Member | Description |
|---|---|
| `Serial`, `Model`, `Firmware`, `Name` | Identity; `Name` is set through `cm.setCameraName` |
| `v = get(name)` / `actual = set(name, value)` | Property access; `set` switches the related auto mode off, enables the feature node if needed, clamps to limits (with a warning), and returns the value read back |
| `T = describeProperties()` | Table of friendly properties: node, value, min, max, unit, available, writable |
| `s = getSettings()` / `applySettings(s)` | Struct round-trip for persisting setups (includes the crop). The frame rate is restored to the exact value read back, not re-quantized one step higher |
| `roi = getRoi()` / `roi = setRoi([x y w h], 'Center', tf)` / `roi = resetRoi()` / `sz = sensorSize()` | Crop of this camera (stream must be stopped for `setRoi`); `sensorSize` = full frame `[width height]` |
| `NodeMap`, `StreamNodeMap`, `Registers` | Low-level adapters (`get/set/info/execute`, `read/write`) |

Friendly property names (aliases in parentheses):

| Name | GenICam node(s) | Side effects of `set` |
|---|---|---|
| `FrameRate` | `AcquisitionFrameRate` | `AcquisitionFrameRateAuto=Off`, `AcquisitionFrameRateEnabled=true`. With manual exposure the maximum is limited by the exposure time. |
| `ExposureTime` (`Exposure`, `Shutter`) | `ExposureTime` [µs] | `ExposureAuto=Off`. The maximum is limited by the frame period (≈ 9.9 ms at 100 fps, 8266 µs at 120 fps). |
| `Gain` | `Gain` [dB] | `GainAuto=Off` |
| `BlackLevel` (`Brightness`) | `BlackLevel` [%] | `BlackLevelAuto=Off` if present |
| `Gamma` | `Gamma` | `GammaEnabled=true`. ⚠ Reported **unavailable** by CM3 firmware 1.13.3 in our tests; the UI greys it out. |
| `Sharpness` | `Sharpness` | `SharpnessEnabled=true`, `SharpnessAuto=Off` |
| `ExposureAuto`, `GainAuto`, `FrameRateAuto` | `…Auto` enums | `'Off'`, `'Once'`, `'Continuous'` |
| `PixelFormat`, `Width`, `Height`, `OffsetX`, `OffsetY` | same | Stream must be stopped. Recording requires `Mono8`. Use `setRoi` for crops: it sets offsets and size in a valid order. |
| `ThroughputLimit` | `DeviceLinkThroughputLimit` | USB bandwidth cap (bytes/s) |
| *any other node name* | passed through | none |

### `spincam.SyncController` (handle)

`s = spincam.SyncController('strobe','StrobeEveryN',2)`. Its properties are listed in
§5. Methods:

* `validate(device)`: throws `spincam:sync:*` errors for impossible configurations
* `plan = apply(device)`: returns the engine TTL settings
* `describe()`: one-line summary (shown in the viewer)
* `spincam.SyncController.optionsFor(mode, ttlSource)`: options used by a mode
* `spincam.SyncController.reset(device)`: free-run, strobe pattern period 1, embedding off

### `spincam.VideoRecorder` (handle)

| Property | Default | Values |
|---|---|---|
| `Format` | `'avi-mjpeg-mt'` | `'avi-mjpeg-mt'` (MJPEG AVI encoded by the engine on `EncoderThreads` cores per camera; no SpinVideo needed); `'avi-mjpeg'`, `'avi-raw'`, `'mp4-h264'` (SpinVideo, one native writer thread per camera); `'raw'` (lossless 8-bit, native thread, disk speed); `'matlab-avi'` (VideoWriter *Grayscale AVI*, bit-exact 8-bit), `'matlab-mjpeg'` (VideoWriter *Motion JPEG AVI*); `'none'` (CSV only) |
| `JpegQuality` | 30 | `avi-mjpeg-mt` quality 1–100 on the IJG/libjpeg scale (MATLAB `imwrite`'s). 30 gives the file size of SpinVideo's `Quality` 75 on real frames and is closer to the sensor values (§9) |
| `EncoderThreads` | 0 | `avi-mjpeg-mt` encoder threads per camera; 0 = logical processors / 4, between 2 and 8. `Recorder.encoderThreadCount()` gives the number used |
| `Quality` | 75 | MJPEG quality 1–100 of `avi-mjpeg` (SpinVideo) and `matlab-mjpeg`; not the same scale as `JpegQuality` |
| `H264BitrateMbps`, `H264Crf` | 8, 23 | H.264 settings |
| `FrameRate` | `[]` | Container frame rate. `[]` uses the camera's `AcquisitionFrameRate` (30 in triggered mode if unknown) |
| `MaxFileSizeMB` | 0 | Split size of the SpinVideo formats; 0 = no split. `avi-mjpeg-mt` ignores it (one OpenDML file) |
| `AviRiffSizeMB` | 0 | `avi-mjpeg-mt` OpenDML segment size; 0 = 1024. For tests only |
| `QueueSeconds` | 10 | Writer queue depth, in seconds of video, before frames are dropped (flagged) |
| `CsvExtended` | `true` | Write the extended CSV columns |
| `ScrubEmbeddedPixels` | `true` | Restore the 8 embedded-data pixels in the video |

The `matlab-*` formats are drained by a MATLAB timer. They are **not** suitable while
MATLAB is blocked (for example inside Bpod `RunStateMachine`); use `avi-mjpeg-mt`, the
SpinVideo formats or `raw` there. The SpinVideo formats need `SpinVideoNET` in the Spinnaker installation;
without it `startRecording` raises `spincam:recorder:noSpinVideo`.

> ⚠ SpinVideo's "uncompressed" AVI (`'avi-raw'`) is stored as **I420 (yuv420p)**, not
> 8-bit grayscale. Luma keeps full resolution, but decoded gray levels can differ from the
> sensor values by a few counts. For bit-exact pixel values use `'raw'`, which is native and
> Bpod-safe, then `spincam.io.rawToAvi` afterwards if you need AVI. `'matlab-avi'` is also
> exact, but MATLAB must not be blocked. The per-frame CSV metadata is exact in every format.
>
> `startRecording` warns (`spincam:recorder:encoderMayNotKeepUp`) when the frame rate
> exceeds the encoder speed measured for the frame size (see §9).

### `spincam.LiveViewer`

`v = spincam.LiveViewer(cm)` attaches to an existing manager.
`v = spincam.LiveViewer(Name,Value)` creates its own manager with the same options as
`CameraManager` (plus `'Visible'`). Closing the window stops preview. It does **not**
disconnect a manager you passed in.

Programmatic equivalents of the UI actions (used by the tests): `togglePreview(on)`,
`toggleRecording(on)`, `setProperty(name, value)`, `setAuto(name, on)`, `setTarget(id)`,
`setOutput('DataRoot',…,'Subject',…,'Session',…,'FileName',…,'Format',…,'AppendDateTime',…)`,
`folder = outputFolder()`, `setCameraName(serial, name)`, `setSync(mode, Name,Value)`,
`states = syncFieldStates()`, `setCrop([x y w h], 'Center', tf)`, `resetCrop()`,
`selectCamera(serial, connected)`, `refresh()`, `tileImages()`.

### Utilities

| Function | Purpose |
|---|---|
| `spincam.setup(Name,Value)` | Environment check, Spinnaker location and engine build: `'SpinnakerDir'`, `'BrowseSpinnaker'`, `'SavePath'`, `'ForceBuild'`, `'ListCameras'`, `'Quiet'` (§2). Returns a report struct |
| `spincam.tools.probeCameras()` | Dumps identity, key nodes, line capabilities, FRAME_INFO / strobe-pattern registers |
| `spincam.tools.verifyTtlInput(seconds)` | Streams at 100 fps (`'FrameRate'`) in passive mode and prints per-camera TTL edges and lines that were high (apply a TTL to check the wiring) |
| `spincam.tools.benchmarkWriters()` | Throughput of each video format with synthetic frames |
| `spincam.io.readFrameLog(csv)`, `readEventLog(csv)` | Typed readers |
| `spincam.io.mergeFrameLogs(summary)` / `(folder, baseName)` | All camera logs of one recording with a `Name` column, sorted by host time |
| `r = spincam.io.RawVideoReader(file)` | `r.read(k)` / `r.read([first last])` → H×W(×N) `uint8`. Properties: `Width`, `Height`, `NumFrames`, `FrameRate`, `CameraId` |
| `spincam.io.rawToAvi(rawFile, aviFile, 'Profile', ...)` | Converts `.raw` to *Grayscale AVI* (lossless, default) or *Motion JPEG AVI*; frame order and indices are preserved |

---

## 9. Performance and limits

Measured on the development rig (2 × CM3-U3-13Y3M on one shared USB 3.0 controller,
i7-14700K, NVMe SSD). The full measurements are in [docs/performance.md](docs/performance.md).

**Recommended settings**

| Goal | Settings |
|---|---|
| Long sessions (hours), full frame | **Defaults**: 100 fps, `avi-mjpeg-mt` |
| 120 fps, full frame | `avi-mjpeg-mt` (120 fps is the most two full-frame cameras deliver on one USB 3.0 controller) |
| 150 fps (camera maximum) | Crop to 960×720 or smaller (USB bandwidth), `avi-mjpeg-mt` |
| Bit-exact pixels, short recordings | `raw`, then `spincam.io.rawToAvi` |

**Limits**

* **USB bandwidth.** Two full-frame cameras on one USB 3.0 controller sustain at most
  120 fps; at 150 fps 6–44 % of frames are skipped on the cameras. Crop, or use separate
  controllers. Missed frames are always reported in `FramesMissedBefore`, and `CameraManager`
  warns (`spincam:manager:usbBandwidth`) above ≈ 340 MB/s combined.
* **MJPEG encoders.** `avi-mjpeg-mt` encodes each camera's frames on several threads
  (≈ 180 fps per thread at full frame, scaling with threads), so its writer queue stays flat at
  120 fps full frame even with one thread and MATLAB busy drawing. SpinVideo's `avi-mjpeg`
  encodes one frame at a time at ≈ 104 fps per camera, only 4 % above the 100 fps default: with
  a live preview and a busy MATLAB its queue grew by 1–2 frames/s and would overflow within
  about 15 minutes. Use it only cropped (1024×900 at 120 fps, 960×720 at 150 fps).
  `startRecording` warns (`spincam:recorder:encoderMayNotKeepUp`) when the frame rate exceeds
  the measured capacity for the format, frame size and threads. Frames that overflow the writer
  queue (`QueueSeconds`) are flagged (`WriterDropFlag`), never lost silently.
* **`raw`** keeps up at any camera rate (disk speed) and is bit-exact, but needs ≈ 0.9 TB per
  hour at 100 fps.
* A 17.5-minute Bpod session with the defaults (camera window open) had 0 missed frames, 0 writer
  drops and a writer queue of at most 2 frames; a 30-minute passive recording with SpinVideo
  `avi-mjpeg` had flat MATLAB memory.

**Long sessions: disk, RAM and CPU** (two cameras, full frame, 100 fps, `avi-mjpeg-mt`)

* **Disk:** ≈ 7.5 MB/s together, i.e. ≈ 27 GB per hour or ≈ 110–165 GB for a 4–6 h session
  (depends on the scene). The CSV frame logs add ≈ 0.7 GB per 6 h. `raw` at 100 fps would need
  ≈ 0.9 TB per hour, which is why it only suits short recordings.
* **Converting `raw`:** `spincam.io.rawToAvi(file, '', 'Profile', 'Motion JPEG AVI', 'Quality', 90)`
  runs at ≈ 85 fps on one core (MATLAB `VideoWriter`), i.e. slower than recording; the default
  profile (*Grayscale AVI*) is lossless but as large as the raw file.
* **RAM:** frames are buffered only while the encoder is behind. The queue is capped by
  `QueueSeconds` (10 s ≈ 1.25 GB per camera at full frame, 100 fps) and `MaxQueueMB` (2 GB);
  steady state uses < 200 MB.
* **CPU:** about half a core of JPEG encoding per camera at 100 fps, spread over its encoder
  threads, plus a muxer and grab threads per camera, all outside MATLAB, so Bpod's `RunStateMachine` does not affect recording. Running the viewer in a
  separate MATLAB session from Bpod keeps its preview responsive.

**Timing**

* The video container's frame rate is the camera's `AcquisitionFrameRate` node, while the
  cameras deliver slightly fewer frames (measured 99.64 fps with the node at 100, 119.50 fps
  with it at 120.0856). Video playback time is therefore up to ≈ 0.5 % off. Always take timing
  from `HardwareTimestamp_us`, never from the video frame rate.
* `HostTimestamp_datetime` is the frame **arrival** time on the host, so it includes
  exposure, readout and USB transfer. Use `HardwareTimestamp_us` for inter-frame timing
  and `HostTime_s` / `_events.csv` for alignment with MATLAB-side events.

---

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `Spinnaker: Could not read remote Port on device [-1008]` | Wrong register address. IIDC registers live at `0xFFFFF0F00000 + offset`. |
| `AccessException … Node is not readable [-2006]` | The node is unavailable in the current state (auto mode on, wrong selector, or not supported, e.g. `Gamma`). Check `cam.describeProperties()`. |
| Camera not listed / "in use" | Close SpinView and any other MATLAB session. Unplug and replug. |
| MATLAB hangs on exit | A Spinnaker system was not released. Always `delete(cm)`, and use `onCleanup` in scripts. |
| Rebuilt engine not picked up | .NET assemblies cannot be unloaded. Restart MATLAB. |
| `Engine build failed: error CS0016 … being used by another process` | Another MATLAB session has `SpinCamEngine.dll` loaded. Close that session (or rename the DLL, e.g. to `SpinCamEngine.dll.old`, which Windows allows), then run `spincam.setup('ForceBuild',true)` again. |
| "Enter a subject name" when pressing Record | Fill in *Subject* on the Recording tab (`sessionFolder` needs it). |
| `topview` / `sideview` are swapped | Defaults follow serial order, not physical position. Rename the cameras on the Recording tab or with `cm.setCameraName`. |
| Video file still ends in `-0000.avi` | The rename after recording failed (warning `spincam:recorder:renameFailed`, e.g. the file was open in a player) or `MaxFileSizeMB > 0`. The data are complete; rename by hand. |
| `spincam:property:clamped` for FrameRate on connect | Manual exposure is too long for the default frame rate and could not be shortened. Lower `ExposureTime` or set `cm.DefaultFrameRate`. |
| `Spinnaker .NET assemblies (SpinnakerNET_v*.dll) not found` | Install Spinnaker with its .NET components, or point spincam at it: `spincam.setup('SpinnakerDir', '<Spinnaker folder>')` or `spincam.setup('BrowseSpinnaker', true)`. Setup lists configured folders that contain no assemblies. |
| `spincam:recorder:noSpinVideo` | The Spinnaker installation has no `SpinVideoNET`. Use `raw`, `matlab-avi` or `matlab-mjpeg`, or install Spinnaker's video components and run `spincam.setup`. |
| Engine build fails after a Spinnaker update | The installed .NET API no longer has a member spincam uses; the compiler message names it. Reinstall the verified version (4.2.0.83) or report the message. |
| `spincam:roi:adjusted` | The crop was rounded to the camera's steps or moved onto the sensor; the returned `[x y w h]` is what the camera uses. |
| Unexpected image size / cropped view | A crop from an earlier session is still active (cameras keep it until power-cycled). Click *Full frame* on the Camera tab or run `cm.resetRoi()`. |
| Frames missed at > 120 fps with two cameras (`FramesMissedBefore` > 0, while Spinnaker's `StreamLostFrameCount` stays 0) | The frames are skipped on the cameras because both share one USB 3.0 controller. Use separate controllers, or ≤ 120 fps / a smaller ROI; see §9. |
| "Writer did not finish within … ms" with 0 frames written, or MATLAB crashing in `SpinVideo::Open` / `avcodec-57.dll` | SpinVideo's ffmpeg 3.x is not safe when several writers open or close at the same moment. Since 2026-09-15 the engine serializes these calls; make sure `native\bin\SpinCamEngine.dll` is rebuilt (`spincam.setup('ForceBuild',true)` in a fresh MATLAB) and restart MATLAB. |
| `WriterDropFlag` = 1 / writer drops in the summary | The encoder is slower than the camera. Lower the frame rate (≤ 100 fps at full frame), crop (`setRoi`), or use `raw`; see §9. |
| TTL never changes in CSV / TTL badge stays grey | Run `spincam.tools.verifyTtlInput(10)` while pulsing. Check yellow/brown polarity, that the source drives 5 V (3.3 V logic may not switch the opto-isolated input; §3), and that the pulse is longer than a frame period (≥ 15 ms at 100 fps). |
| Warning "Unable to obtain a change notification handle" | Harmless. MATLAB started from a `\\wsl.localhost` path; start it from the Windows project folder instead. |

---

## 11. Developer documentation

Background that is not needed to use spincam lives in [`docs/`](docs/):

* [docs/architecture.md](docs/architecture.md): backend choice, layering, how per-frame TTL
  state is captured, how the engine is built against Spinnaker
* [docs/performance.md](docs/performance.md): benchmark and soak-test measurements, hardware
  validation records
* [docs/development.md](docs/development.md): test suites, workstation dependency audit,
  internal utilities
* [CLAUDE.md](CLAUDE.md): contributor rules, verified hardware facts, design decisions and
  coding conventions
