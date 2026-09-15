# CLAUDE.md — working on `spincam`

Guidance for AI agents and humans modifying this repository. `AGENT.md` is a symlink to
this file. User-facing documentation lives in `README.md`; developer background (architecture,
measurements, validation records, test suites) lives in `docs/`.

## 1. Hard rules

* **Write only inside this project folder.** Never create, modify or delete files
  elsewhere: not in `C:\Program Files`, not in `%TEMP%`, not in the MATLAB prefdir, not
  in the camera SDK folders. Reading SDK docs and headers outside the project is fine.
  Test outputs go to `tests/_output/` (git-ignored). Temporary build artefacts go to
  `native/obj/`.
* **Do not leave camera state modified.** Any tool or test that writes registers or nodes
  must restore them (FRAME_INFO `0x12F8`, strobe pattern `0x110C`/`0x1118+`, trigger
  mode, line modes). Never set a GPIO line to `Output` in a test unless the wiring is
  known to be safe. Currently only yellow/brown (Line0 opto input) are wired.
* **Always release Spinnaker.** Every code path that creates a `ManagedSystem` must
  clear camera lists, `DeInit`/`Dispose` cameras, then `Dispose` the system
  (`spincam.internal.SpinnakerSystem` does this with ref-counting). Leaked handles hang
  MATLAB at exit.
* Keep `README.md` in sync with public API changes (signatures, defaults, CSV columns).
  Keep it user-facing: benchmarks and validation runs go in `docs/performance.md`, test suites
  and counts in `docs/development.md`, backend internals in `docs/architecture.md`.

## 2. Environment idiosyncrasies (WSL ↔ Windows)

* The agent shell is **WSL2 Ubuntu**. MATLAB, the C# compiler and Spinnaker are **Windows**
  programs. Invoke them through `/mnt/c/...` paths, and always pass **Windows paths** as
  their arguments (`wslpath -w <path>`).
  * MATLAB: `"/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe" -batch "<cmd>"`, run
    from the project directory (`cd /mnt/c/Users/harrislab/Documents/MATLAB/SpinCam`; the
    folder was renamed from `spinnakerMatlab`).
    Its output goes to stdout. The exit code is non-zero on error.
  * C#: `/mnt/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe` (**C# 5 only**:
    no `?.`, `$""`, `nameof`, expression-bodied members, exception filters or
    auto-property initializers).
  * PowerShell: `powershell.exe -NoProfile -Command "..."`. Escape `$` as `\$` inside
    bash double quotes.
* Starting MATLAB with a `\\wsl.localhost\...` current folder prints a harmless
  "Unable to obtain a change notification handle" warning. Prefer running from the
  project folder.
* Windows programs cannot follow WSL symlinks created on `/mnt/c` (`AGENT.md` is one).
  Nothing in MATLAB code may depend on symlinks.
* User-supplied paths may be WSL-style (`/mnt/d/data`). All public entry points pass
  paths through `spincam.internal.toWindowsPath`.
* `NET.addAssembly` locks `native/bin/SpinCamEngine.dll`. After changing C# sources,
  rebuild in a **fresh** MATLAB process (`matlab -batch "spincam.setup('ForceBuild',true)"`)
  before running tests in another fresh process.
  * A `-batch` process keeps the DLL locked for a few seconds after it prints its result; wait
    before rebuilding.
  * The user's **desktop MATLAB** may also have the engine loaded (build error `CS0016 … being
    used by another process`). Find the holder with the Windows Restart Manager API
    (`RmGetList`; module lists do not show IL-only assemblies). Never kill the user's session:
    rename the locked DLL (allowed for mapped images), e.g. to `SpinCamEngine.dll.old-inuse`,
    build, and tell the user to restart MATLAB. Delete the old file once it is no longer locked.
  * `NativeEngine.load` rebuilds a stale DLL, so a failed build makes **every** integration
    test class error in setup (unit tests still pass). Check the build log first.
* MATLAB `-batch` has no display for figures on some setups. UI tests call
  `assumeTrue(usejava('desktop') || spincam.internal.canCreateUIFigure())`.

## 3. Verified hardware / SDK facts (2026-09-15)

Treat these as ground truth unless re-verified; `spincam.tools.probeCameras` reproduces them.

| Fact | Value |
|---|---|
| Cameras | `Chameleon3 CM3-U3-13Y3M`, serials 24226887 and 24226657, FW `1.13.3.00`, FPGA 2.02, USB SuperSpeed, vendor string "Point Grey Research" |
| Driver / SDK | Spinnaker 4.2.0.83, .NET assemblies `SpinnakerNET_v140.dll`, `SpinVideoNET_v140.dll` in `C:\Program Files\Teledyne\Spinnaker\bin64\vs2015` (no C/C++ headers installed) |
| USB topology | Both cameras on one Renesas µPD720202 USB 3.0 PCIe controller |
| Sensor | 1280×1024, `PixelFormat` {Mono8, Mono12Packed, Mono12p, Mono16}, max 150.716 Hz |
| Frame rate nodes | `AcquisitionFrameRate` (writable only when `AcquisitionFrameRateAuto=Off` and `AcquisitionFrameRateEnabled=true`; note **Enabled**, not SFNC `Enable`) |
| Exposure/gain | `ExposureTime` µs (writable when `ExposureAuto=Off`), `Gain` dB (writable when `GainAuto=Off`), `BlackLevel` % writable, `Gamma`/`GammaEnabled` **unavailable**, `Sharpness` read-only |
| Trigger | `TriggerSelector` {FrameStart, ExposureActive}; `TriggerSource` {Software, Line0, Line2, Line3}; `TriggerActivation` {RisingEdge, FallingEdge}; `TriggerOverlap` unavailable while `TriggerMode=Off`; `ExposureMode` {Timed, TriggerWidth} |
| Lines | Line0 `LineMode` {Input}; Line1 {Output}, `LineSource` {ExposureActive, ExternalTriggerActive, UserOutput1}, `StrobeDuration`/`StrobeDelay` µs [0..65535], `LineInverter`; Line2/3 {Input, Output}; `LineStatusAll` bit k = Line k (idle reads 8 or 12: Line2/3 pulled high) |
| Opto input electrical (Line0) | *Chameleon3 USB3 Technical Reference* v5.0 §6.7 (not measured): operating 0–30 V, abs max −70/+40 V, over-current protected, specs valid when powered over USB. Circuit (Fig. 6.2): OPTO_IN → series diode → FET current limiter → optocoupler LED → OPTO_GND. **No logic threshold published.** 5 V TTL (Bpod BNC) is the supported level; 3.3 V is in range but not guaranteed and untested on the rig. Pinout colours in Fig. 6.2 confirm yellow = pin 9 OPTO_IN, brown = pin 7 OPTO_GND |
| Chunks | `ChunkSelector` has FrameCounter, Timestamp, ExposureTime, Gain, … but **no line status chunk** |
| Events | `EventSelector` {ExposureEnd} only (no line events) |
| Stream nodemap | `StreamBufferHandlingMode` default OldestFirst, `StreamBufferCountManual` 10 |
| Image | `IManagedImage.TimeStamp` ns (device clock), `FrameID` stream-relative from 0, `DataPtr` is `IntPtr`, `ChunkData` throws when chunks are off |
| IIDC registers | `cam.ReadPort(uint64 addr, System.Byte[] buf, uint64 len)`; base **`0xFFFFF0F00000`**; values **little-endian** (SERIAL `0x1F20` reads the serial) |
| FRAME_INFO `0x12F8` | default `0x87FF0000`. IIDC bit numbering is MSB-first (bit n ↔ `2^(31-n)`). Inquiry bits 6..15 ↔ enable bits 22..31. Enabled fields are packed in the order Timestamp(31), Gain(30), Shutter(29), Brightness(28), Exposure(27), WB(26), FrameCounter(25), StrobePattern(24), GPIO(23), ROI(22), 4 bytes each, **big-endian** in the image. GPIO state: Line k ↔ bit (31−k). Writing `0x87FF0140` gives frame counter at bytes 0–3 and GPIO at bytes 4–7 (verified). |
| GPIO_CTRL `0x1100` | `0x8004000X`: 4 pins; Value_k at bit (31−k), so the low nibble follows the live pin states (`0x80040008` on 24226887, `0x8004000C` on 24226657, matching `LineStatusAll` 8 / 12) |
| Strobe pattern | `GPIO_STRPAT_CTRL 0x110C` = `0x80000100` (Count_Period bits 19–23, value 1..16; Current_Count bits 28–31); `GPIO_STRPAT_MASK_PIN_{0..3}` `0x1118/0x1128/0x1138/0x1148` = `0x8000FFFF` (Enable_Mask bits 16–31; IIDC bit 16+c ↔ count c ↔ value `2^(15-c)`) |
| Timing | MATLAB `uint8(img.ManagedData)` ≈ 0.74 ms per frame; `LineStatusAll` read ≈ 0.67 ms; `GetNextImage` returns at camera rate |
| Trigger defaults | `TriggerActivation` factory state on both cameras is **FallingEdge**; tests must snapshot and restore trigger nodes |
| USB bandwidth | Each camera alone at 150 fps full frame: 0 missed. Both at 150 fps on the shared controller: 6–44 % frames skipped **on the camera** (FrameID/counter gaps, while Spinnaker `StreamDropped/LostFrameCount`, `TransmitFailureCount`, `USB3LinkRecoveryCount` all stay 0). Both at 120 or 100 fps: 0 missed. |
| SpinVideo | Output is `<VideoPath>-0000.avi/.mp4` even with `SetMaximumFileSize(0)`. "Uncompressed" AVI is **I420 yuv420p** (not bit-exact gray). ffmpeg/x264 logs are printed to stdout. `AviOption/MJPGOption/H264Option` fields `width`, `height`, `quality`, `bitrate` are `int`; `crf` is `uint`; `frameRate` is `float`. |
| SpinVideo threading | Bundles ffmpeg 3.x (`avcodec-57.dll`). In a full test run (2026-09-15) two cameras opening MJPEG writers at the same moment hung both writer threads inside `SpinVideo::Open` (0 frames, "Writer did not finish"); the next `Open` crashed MATLAB with `AccessViolationException` in `avcodec_flush_buffers`. Not reproducible on demand (20 concurrent-open rounds passed), consistent with ffmpeg 3.x `avcodec_open2/close` needing external locking. `SpinVideoSink` therefore serializes Open/Close with a static lock. |
| Encoder speed | 1280×1024 synthetic frames, frames/s per camera: **raw 3353** (disk speed), avi-raw 110–114, avi-mjpeg 115–116, mp4-h264 121–124, MATLAB Grayscale AVI 371–382 (MATLAB thread), MATLAB MJPEG 85–88. Real dual-camera recordings with 0 missed and 0 writer drops: avi-mjpeg 100 fps 15 s, avi-raw 100 fps 10 s, raw 120 fps 15 s (queue peak 1). |
| MATLAB/.NET interop | Enum nodes: set with `node.FromString('Sym')` (assigning `Value` needs an `EnumValue`); read with `char(node.ToString())`. Generic `GetNode<T>` is called with `NET.invokeGenericMethod(nm,'GetNode',{'SpinnakerNET.GenApi.INode'},name)`, which returns concrete classes `SpinnakerNET.GenApi.{Float,Integer,BoolNode,Enumeration,StringReg,Command,Category}`. `NodeMap.ContainsKey` does **not** work. Nodes expose `IsAvailable/IsReadable/IsWritable`. `ManagedCameraList.GetByIndex(uint32)`. |
| Default names | Serial rank → `topview` = 24226657, `sideview` = 24226887 (not verified against the physical views) |
| 120 fps reality | `FrameRate` 120 reads back 120.0856 Hz, but `HardwareTimestamp_us` intervals are 8368 µs (**119.50 fps**, p1–p99 8364–8372) on both cameras; the video container gets 120.09. Dual-camera 10 s passive recording: 0 missed |
| Embedded GPIO vs pins | Per-frame `GPIO_LineStatus` = 8 (24226887) and 12 (24226657), equal to each camera's `LineStatusAll`; Line0 idle 0. No TTL generator wired during checks: real-edge detection not verified on the rig |
| Writers on real frames | 2 cameras, 120 fps, dark scene (auto gain 18 dB), 15 s each: `avi-mjpeg` Q75 queue +15 frames/s per camera (≈104 fps; +12 in a 10 s run), Q50 +14 (≈105), `mp4-h264` +49 (≈70, 46 MB/s), `raw` 0 (296 MB/s). Default 1200-frame queue fills after ~80–100 s → writer drops. `startRecording` warns `encoderMayNotKeepUp`. Only `raw` sustains 120 fps |
| Spinnaker install layout | `C:\Program Files\Teledyne\Spinnaker\bin64\vs2015` holds `SpinnakerNET_v140.dll`, `SpinVideoNET_v140.dll` plus debug (`…NETd_v140`) and GUI (`SpinnakerNETGUI_v140`) variants that must be ignored; `bin64\vs2017` exists but has no .NET assemblies. Other versions/layouts are **not** available on this machine (only 4.2.0.83 tested) |
| ROI (crop) | `Width` [16..1280] inc **16**, `Height` [2..1024] inc **2**, `OffsetX` inc **8**, `OffsetY` inc **2**; `OffsetX.Max = 1280 − Width`. `SensorWidth/SensorHeight` and `WidthMax/HeightMax` exist (read-only). Width/Height are **not writable while acquiring** (TLParamsLocked). `AcquisitionFrameRate` max stays **150.716** for every crop size. Crops persist in the camera across MATLAB sessions until changed or power-cycled. `BinningVertical` writable 1–2, `BinningHorizontal` read-only (unused) |
| Default-settings soak | 30 min, both cameras, 1280×1024 @ 100 fps (node 100.058), `avi-mjpeg`, passive: 179 597 / 179 596 frames, 0 missed, 0 writer drops, queue peak 3, fps 99.6–99.8, hw interval 10036 µs (max 10041), MATLAB memory flat 2.0 GB, videos 5.42 + 6.74 GB (≈ 24 GB/h together), `VideoReader.NumFrames` = CSV rows |
| Frame-rate quantization | Writing 120 reads 120.0856; writing 120.0856 reads **120.1772**. Restore frame rates by writing the originally *requested* value, not the read-back |
| Cropped / 100 fps MJPEG (real frames) | Both cameras, 20 s each, queue growth per camera: 1280×1024 @ 100 fps **0** (hw interval 10036 µs = 99.64 fps; 2.9–3.7 MB/s per camera); 1024×900 @ 120 fps **0** (2.6–3.1 MB/s); 960×720 @ 150 fps 0 to +0.4 frames/s (2.3–2.7 MB/s); all 0 missed, 0 writer drops, embedded GPIO decoded (8 / 12) |
| Spinnaker error codes | −1011 timeout (`GetNextImage`), −2006 GenICam AccessException, −1008 bad port address |

## 4. Architecture decisions

1. **Backend = Spinnaker .NET + C# engine** (see `docs/architecture.md`). MATLAB does control-plane
   work only (settings, sync, UI, file naming). The per-frame data plane lives in
   `native/src` (grab → decode → queue → encode/log) on background threads. Reasons:
   MATLAB is single-threaded, Bpod's `RunStateMachine` blocks it, and per-frame .NET→MATLAB
   copies cost ~0.7 ms.
2. **Per-frame TTL from embedded GPIO (FRAME_INFO)**, not host polling. Polling is kept as
   a fallback (`TtlSource='polled'`).
3. **Drop detection** = max(FrameID gap, embedded frame-counter gap). Writer overflow and
   incomplete images are flagged separately. Nothing is dropped silently.
4. **Abstractions for testability**:
   * `spincam.internal.NodeMapAdapter` → `SpinnakerNodeMap` | `MockNodeMap` (CM3 rules:
     auto-off gating, selectors, TriggerSource requires TriggerMode=Off, line capabilities).
   * `spincam.internal.RegisterPort` → `SpinnakerRegisterPort` | `MockRegisterPort`.
   * C# `IFrameSource` → `SpinnakerFrameSource` | `SyntheticFrameSource` (deterministic TTL
     square wave, drops, incomplete frames, embedded header). The mock backend therefore
     exercises the *real* engine threads, CSV writer and video sinks.
5. **Video**: SpinVideo (MJPEG/uncompressed AVI, H.264 MP4) runs in the engine's writer
   thread. MATLAB `VideoWriter` is supported through an engine export queue drained by a
   MATLAB timer; it is not Bpod-safe. The class is named `spincam.VideoRecorder` so it
   doesn't shadow MATLAB's built-in `VideoWriter`.
6. **One host clock**: C# `SpinCam.HostClock` (Stopwatch anchored to wall time at load).
   The CSV `HostTime_s`, `_events.csv` and `CameraManager.hostTime()` all use it.
7. **Hardware strobe every N**: IIDC strobe pattern registers (N ≤ 16). No software
   toggling fallback, because host-timed jitter would be misleading.
8. **Sync changes require stopped streams**. The manager restarts preview automatically
   and refuses changes while recording.
9. **Native lossless `raw` format** (`RawSink`: `.raw` + `.raw.json`). No SpinVideo
   format keeps up with 150 fps full frame, and SpinVideo "uncompressed" is not bit-exact.
   Raw writing is disk-speed, bit-exact and Bpod-safe. `spincam.io.rawToAvi` converts
   afterwards.
10. **Warnings, not silent loss**: `spincam:manager:usbBandwidth` (combined data rate
    above what a shared USB 3.0 controller sustained) and
    `spincam:recorder:encoderMayNotKeepUp` (frame rate above the measured encoder speed).
    Update `VideoRecorder.MeasuredCapacity` if benchmarks change.
11. **Storage layout and file names** (user requirement, 2026-09-15). Folder
    `<DataRoot>\<subject>\<session>` (`CameraManager.sessionFolder`, `DataRoot` default
    `D:\videoData`). Per camera: `<camera name>_<fileName>_<yyyyMMdd_HHmmss>` for **both**
    the video and the CSV (`<stem>.avi` + `<stem>.csv`); shared `<fileName>_<datetime>_events.csv`
    and `_session.json`. SpinVideo always writes `<stem>-0000.avi`, so
    `VideoRecorder.finalizeFiles` renames the single segment after the writer closes (MATLAB
    side, no engine change); split recordings keep numbered segments. `CameraManager.plannedFileNames`
    is the single source of these names (the viewer's file preview uses it too).
12. **Camera names** live on `CameraDevice.Name` (settable only by `CameraManager`).
    Defaults `DefaultCameraNames = {'topview','sideview'}` are assigned by **ascending serial
    rank among attached cameras**, not connect order, so a physical camera keeps its default
    however it is connected; `setCameraName` names are remembered per manager across
    disconnect/reconnect. `camera(id)` and every `ids` argument accept names.
13. **Default frame rate 100 fps** (user decision 2026-09-15, after 120 fps + MJPEG proved
    unsustainable on real frames): `CameraManager('FrameRate', 100)` sets `DefaultFrameRate`,
    applied in `connect()` to each newly opened camera (manual exposure longer than the frame
    period is shortened first, because the CM3 caps the frame rate by exposure).
    `'FrameRate', []` leaves cameras untouched (hardware tests use this so the settings
    snapshot is the camera's own state). The default format stays `avi-mjpeg`: 100 fps full
    frame keeps the writer queue flat, and `raw` (~0.9 TB/h) does not fit multi-hour sessions.
    Higher rates are reached by cropping, not by changing the default.
15. **Crop = GenICam ROI through `CameraDevice.setRoi`** (`[x y w h]`, `'Center'`). Order:
    offsets to 0, then Width/Height (rounded **down** to increments), then offsets (clamped to
    the sensor). `applySettings` restores crops through `setRoi`, so any crop can replace any
    other. `CameraManager.setRoi/resetRoi` stop and restart preview like other
    stopped-stream changes and refuse while recording. `VideoRecorder.MeasuredCapacity` scales
    with pixel count, which is what makes the encoder warning crop-aware. The mock follows
    the crop because `CameraDevice.syncMockSource` calls `SyntheticFrameSource.Resize`.
16. **Spinnaker location and versions**: `spincam.internal.SpinnakerLocator` searches
    `SPINCAM_SPINNAKER_BIN` → `spincam_config.json` (`SpinnakerDir`, written by
    `spincam.setup('SpinnakerDir'|'BrowseSpinnaker')`, git-ignored) → standard roots, and accepts a
    root, `bin64` or toolset folder (highest `SpinnakerNET_v<toolset>.dll` wins). `NativeEngine`
    compiles against exactly those files and writes `native/bin/SpinCamEngine.build.json`; a
    different installation makes the engine stale. Without `SpinVideoNET` the build defines
    `NO_SPINVIDEO` (`Engine.HasSpinVideo` false; SpinVideo formats error in MATLAB before
    recording). SpinVideo option members and `SetMaximumFileSize` are set by reflection because
    their types differ between releases. Only 4.2.0.83 is verified
    (`NativeEngine.VerifiedSpinnakerVersion`); update it after a hardware run on another version.
14. **Viewer sync fields follow `SyncController.optionsFor(mode, ttlSource)`**. Adding a sync
    option means: property on `SyncController`, entry in `optionsFor`, a field in
    `LiveViewer.buildSyncTab`, a row in README §5's field reference. Pending (unapplied)
    sync edits are applied automatically on Preview/Record.

## 5. Layout

```
+spincam/                 public classes: CameraManager, CameraDevice, SyncController,
                          VideoRecorder, LiveViewer; setup.m, version.m
+spincam/+internal/       adapters, backends, engine loader, FrameInfo, PropertyRegistry,
                          path utils (not public API; may change)
+spincam/+io/             readFrameLog, mergeFrameLogs, readEventLog
+spincam/+tools/          probeCameras, verifyTtlInput, benchmarkWriters
native/src/*.cs           C# engine sources (namespace SpinCam)
native/bin/               build output SpinCamEngine.dll + SpinCamEngine.build.json (generated)
spincam_config.json       machine-specific Spinnaker folder written by spincam.setup (git-ignored)
examples/                 headless, mock, Bpod examples
docs/                     developer docs: architecture.md, performance.md, development.md
tests/unit|integration|hardware   matlab.unittest classes; runTests.m at root
```

## 6. Coding conventions

**MATLAB**

* `classdef` handle classes for stateful objects. Use `arguments` blocks for public method
  validation.
* Error identifiers are `spincam:<area>:<reason>` (for example
  `spincam:sync:lineNotInput`). Warnings use the same scheme and must be suppressible.
* No `global`s. The only singleton is `spincam.internal.SpinnakerSystem.instance()`.
* Public API names use UpperCamelCase properties and lowerCamelCase methods. Physical
  units go in the name when not obvious (`TriggerDelay_us`).
* Every `.NET` call that can throw Spinnaker exceptions goes through adapter methods that
  rethrow as `spincam:` MATLAB errors with the node or register name in the message.
* Keep per-frame loops out of MATLAB. When a per-frame feature is needed, add it to the
  engine.
* Comment *why*, not *what*. Help text (first comment block) is required on public
  classes and functions.

**C# (engine)**

* C# 5 / .NET Framework 4.8, `/platform:x64 /unsafe /optimize+`. No NuGet packages.
* Threads are background threads (`IsBackground = true`). All cross-thread state is under
  `lock` or `Interlocked`. No blocking calls while holding locks, except `Monitor.Wait`.
* Exceptions on worker threads are caught and surfaced via `LastError` / `Faulted`. Never
  let them escape a thread.
* Pixel buffers are pooled (`BufferPool`). Ownership passes grab → queue → writer →
  pool. The MATLAB export queue never returns buffers to the pool.
* Public members the MATLAB side uses must stay simple: primitives, strings, `byte[]`,
  enums, `out` parameters.

## 7. Workflow

1. Before hardware-related changes, run `spincam.tools.probeCameras` (read-only by default)
   and compare with §3.
2. Edit code. After C# edits:
   `matlab -batch "spincam.setup('ForceBuild',true)"` (fresh process). C# code must compile both
   with and without `NO_SPINVIDEO`; keep Spinnaker/SpinVideo types inside `#if !NO_SPINVIDEO`
   and go through `VideoSinkFactory` (`EngineBuildTest` compiles the variant without SpinVideo).
   Never write to `spincam_config.json` from tests: pass `'ConfigPath'` to `SpinnakerLocator`.
3. Run tests: `matlab -batch "runTests"`. With cameras attached (and SpinView closed):
   `matlab -batch "runTests('hardware')"`.
4. Update `README.md` (API tables, CSV schema), `docs/` (measurements, test counts) and §3 of
   this file if new facts were verified.

## 8. Testing guidelines

* Every bug fix gets a unit or integration test that fails without the fix.
* Unit tests must not need .NET. Use `MockNodeMap`/`MockRegisterPort` and assert the
  **ordered write log** (for example `TriggerMode=Off` before `TriggerSource`).
* Integration tests use the mock backend with `SyntheticFrameSource`. Keep runs short
  (≤ 3 s of streaming per test). Write into `tests/_output/<TestName>/` and delete it in
  teardown. Assert CSV content against the synthetic ground truth: the TTL half-period,
  drop period and embedded counter.
* Hardware tests `assumeTrue` cameras are present. They must restore every node/register
  they touch (`addTeardown`), including trigger nodes (`TriggerActivation`,
  `TriggerSource`, …) that `SyncController.reset` does not touch, and must not drive
  outputs. Afterwards, confirm with `spincam.tools.probeCameras`.
* Ad-hoc hardware experiments (stress/diagnostic scripts) live in the agent scratchpad,
  never in the repo. They write outputs under `tests/_output/` and delete them.
  * Write them as **functions** with explicit cleanup (a script's `onCleanup` only fires when
    MATLAB exits). **Stop and dispose every `CameraStream` before restoring nodes**: ROI and
    pixel-format nodes are not writable while acquiring. A probe that errored mid-benchmark
    once left a camera cropped because its stream was still running.
  * .NET strings from engine objects (`RecordingOptions.CsvPath`, …) must be wrapped in
    `char()` before passing them to `spincam.io` functions.
  * Restore the crop (`setRoi` to the snapshot) and the frame rate (requested value, see §3)
    and confirm with `spincam.tools.probeCameras`.
* Never edit `native/src` or classes used by a running MATLAB job. `NativeEngine.load`
  rebuilds a stale DLL on load, so edits during a run cause a mid-run rebuild.
* Tolerances: synthetic fps is limited by Windows timer resolution. Assert counts within
  ±20 %, never exact timing.
* Tests never write to `D:\videoData`: set `cm.DataRoot` (or the viewer's `setOutput('DataRoot', …)`)
  to the test's `tests/_output/...` folder. With `AppendDateTime = true` two recordings in the
  same second get the same name; tests that exercise `filesExist` set `AppendDateTime = false`.
* `LiveViewer` is tested headless through its public "programmatic UI actions"
  (`togglePreview`, `toggleRecording`, `setOutput`, `setCameraName`, `setSync`,
  `syncFieldStates`, `outputFolder`, …) with `'Visible','off'`. Keep new UI behaviour reachable
  through such a method. For a visual check, run a scratchpad script that calls
  `exportapp(v.Figure, 'tests/_output/…png')` in a fresh MATLAB, view the PNGs, then delete them.
