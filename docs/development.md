# spincam development

Tests, the development workstation and internal helpers. Contributor rules, workflow and coding
conventions are in [CLAUDE.md](../CLAUDE.md).

## Tests

```matlab
cd C:\Users\harrislab\Documents\MATLAB\SpinCam
results = runTests();              % unit + integration (mock backend; no cameras needed)
results = runTests('hardware');    % additionally runs tests/hardware (cameras attached)
```

From WSL:

```bash
cd /mnt/c/Users/harrislab/Documents/MATLAB/SpinCam
"/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe" -batch "runTests"
```

| Suite | Needs | Covers |
|---|---|---|
| `tests/unit` (69) | MATLAB only | FRAME_INFO bit maths (including bytes captured from the real cameras), GPIO decoding, strobe pattern registers, path conversion and name cleaning, mock node-map rules, property side effects and clamping, frame-rate restore under camera quantization, crop ordering/rounding/restore, sync-mode node/register write order and validation, per-mode sync options, finding Spinnaker in different install layouts (fake files) |
| `tests/integration` (44) | Windows + .NET + Spinnaker assemblies | C# engine with synthetic cameras: CSV schema, TTL versus ground truth, drop, incomplete and writer-overflow flags, TTL start gate, lossless `raw` read-back, exact video-index ↔ CSV-row mapping, SpinVideo, multi-core MJPEG (frame order across encoder threads, OpenDML segments, edge padding) and MATLAB `VideoWriter` output; engine build without SpinVideo and build stamp; `CameraManager` end-to-end including file naming, session folders, camera names, default frame rate, cropped recording and overwrite protection; `LiveViewer` recording into `<root>\<subject>\<session>`, crop from the Camera tab, mode-dependent sync fields, subject required |
| `tests/hardware` (10) | Cameras attached, SpinView closed | Identity, property round-trips, register layout, 60 fps preview, 3 s passive recording at 100 fps with embedded TTL, file naming and MJPEG frame count, multi-core MJPEG keeping up at 120 fps full frame, cropped 1024×900 recording at 120 fps, triggered-mode configuration, strobe pattern on Line1, repeated start/stop. Settings, crop and trigger nodes are restored afterwards. |

Last run (2026-09-15, engine 1.1.0 built by `spincam.setup` against Spinnaker 4.2.0.83): unit
68/68, integration 41/41, hardware 9/9 on both cameras, followed by the 30-minute soak test in
[performance.md](performance.md#30-minute-soak-test-with-the-defaults). Camera state (full frame, 120.0856 fps, FRAME_INFO, trigger nodes) was verified restored
afterwards with `spincam.tools.probeCameras`.

## Workstation dependency audit

Audit performed 2026-09-15 on this workstation.

| Item | Status | Needed? |
|---|---|---|
| MATLAB R2025b (25.2), win64 | Installed | **Required** (R2023b+ should work; developed on R2025b) |
| .NET Framework 4.8 (`NET.isNETSupported`, `dotnetenv` → framework 4.8.9345) | Present | **Required** |
| Spinnaker SDK / SpinView 4.2.0.83 (`C:\Program Files\Teledyne\Spinnaker\bin64\vs2015`) | Installed; on system `PATH` | **Required**: Spinnaker with its .NET API, any folder or version ([README §2](../README.md#2-installation)). Here: `SpinnakerNET_v140.dll`, `SpinVideoNET_v140.dll` (SpinVideo is optional) |
| C# compiler `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (C# 5) | Present (ships with Windows) | **Required** to build `SpinCamEngine.dll` once |
| `GENICAM_GENTL64_PATH` → Spinnaker `cti64\vs2015` | Set | Not used by spincam |
| Image Acquisition Toolbox | Licensed, **not installed** | **Not required** |
| MATLAB Support Package for GenICam / Point Grey | Not installed | **Not required** |
| Image Processing Toolbox, Parallel Computing Toolbox | Licensed, not installed | **Not required** |
| FlyCapture2 2.13.3.61 | Installed | **Not used** (can stay installed; do not rebind the cameras to its driver) |

**Nothing needs to be installed** on this workstation, and no `PATH` changes are needed:
`spincam` locates the Spinnaker assemblies itself. [README §2](../README.md#2-installation) covers
other install folders and Spinnaker versions.

## Internal utilities

Functions in `+spincam/+internal` are not public API and may change.

| Function | Purpose |
|---|---|
| `spincam.internal.toWindowsPath(p)` | Converts `/mnt/c/...` WSL paths to `C:\...` (applied to all user paths) |
