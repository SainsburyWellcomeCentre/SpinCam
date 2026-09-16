# spincam performance measurements

Measurements behind the recommendations in [README §9](../README.md#9-performance-and-limits).

Measured 2026-09-15 on the development rig: i7-14700K, 64 GB RAM, Samsung 990 PRO NVMe,
Windows 11, 2 × CM3-U3-13Y3M at 1280×1024 Mono8, 3 ms exposure.

## Acquisition (camera → engine)

| Configuration | Result |
|---|---|
| One camera at 150 fps, 15 s (each camera tested alone) | 0 frames missed, 150–151 fps |
| Both cameras at 150 fps, 15–20 s | **6–44 % of frames missed** (skipped on the cameras) |
| Both cameras at 120 fps, 15 s | 0 missed |
| Both cameras at 120 fps (node reads 120.0856 Hz), 10 s, `avi-mjpeg`, passive sync | 0 missed; hardware frame interval 8368 µs, i.e. the cameras actually deliver **119.50 fps** |
| Both cameras at 100 fps, 15 s | 0 missed; hardware frame interval 9.998–10.002 ms; host arrival interval p99 ≈ 10.2 ms |
| Both cameras at the default 100 fps (full frame), 20 s, `avi-mjpeg` | 0 missed; hardware frame interval 10036 µs (99.64 fps) |
| Both cameras cropped to 960×720 at 150 fps, 20 s | 0 missed: smaller frames fit the shared controller |

Both cameras sit on **one Renesas µPD720202 USB 3.0 controller**. At 150 fps each camera
sends about 196 MB/s, and together they exceed what that controller carries. The lost
frames never leave the camera: Spinnaker's `StreamDroppedFrameCount`/`StreamLostFrameCount`
and the camera's `TransmitFailureCount` all stay 0. spincam's FrameID and embedded-counter
check still reports every gap in `FramesMissedBefore`. For two cameras above ~120 fps at
full frame, use separate USB 3.0 host controllers or a smaller ROI. `CameraManager` warns
(`spincam:manager:usbBandwidth`) above ~340 MB/s combined. So 120 fps is the highest
full-frame rate for two cameras on this controller; the **default is 100 fps** because of the
MJPEG encoder (below).

## Writers

`spincam.tools.benchmarkWriters`, 1280×1024 synthetic frames, frames/s per camera;
every camera has its own native writer thread.

| Format | Frames/s | Notes |
|---|---|---|
| `raw` | **3353** | Disk speed (≈ 4.2 GB/s), lossless |
| `avi-raw` | 110–114 | SpinVideo, I420 |
| `avi-mjpeg` | 115–116 | SpinVideo, ≈ 3 MB/s |
| `mp4-h264` | 121–124 | SpinVideo/x264 (the synthetic pattern compresses unusually well) |
| `matlab-avi` | 371–382 | MATLAB thread shared by all cameras; not Bpod-safe |
| `matlab-mjpeg` | 85–88 | MATLAB thread |

## Real camera frames

Both cameras recording together (auto exposure, auto gain 18 dB, dark scene; 15–20 s per
configuration, 2026-09-15). Writer-queue growth above 0 means the encoder
is slower than the camera:

| Frame size | Frame rate | Format | Writer queue growth per camera | Missed / writer drops | Video data per camera |
|---|---|---|---|---|---|
| 1280×1024 | **100 fps (default)** | `avi-mjpeg` Q75 | 0 (flat) | 0 / 0 | 2.9–3.7 MB/s |
| 1280×1024 | 120 fps | `avi-mjpeg` Q75 | +12 to +15 frames/s (≈ 104–108 fps encoded) | 0 / 0 in 15 s; drops start when the 1200-frame queue is full (~80–100 s) | ≈ 3.5 MB/s |
| 1280×1024 | 120 fps | `avi-mjpeg` Q50 | +14 frames/s | as above | ≈ 3 MB/s |
| 1280×1024 | 120 fps | `mp4-h264` | +49 frames/s (≈ 70 fps encoded) | as above, sooner | ≈ 23 MB/s |
| 1280×1024 | 120 fps | `raw` | 0 | 0 / 0 | 148 MB/s |
| **1024×900** | **120 fps** | `avi-mjpeg` Q75 | 0 (flat) | 0 / 0 | 2.6–3.1 MB/s |
| **960×720** | **150 fps** | `avi-mjpeg` Q75 | 0 to +0.4 frames/s | 0 / 0 | 2.3–2.7 MB/s |

On real frames MJPEG encodes ≈ 104 fps per camera at full frame (the synthetic benchmark
overstates this). Speed scales with the pixel count; `startRecording` uses that estimate
(`VideoRecorder.MeasuredCapacity`) for its `spincam:recorder:encoderMayNotKeepUp` warning.
Lowering MJPEG quality barely helps. The writer queue (`QueueSeconds`) absorbs bursts, and any
overflow is flagged per frame (`WriterDropFlag`), never silent. Earlier short runs with 0 missed
frames and 0 writer drops: 100 fps `avi-raw` (10 s) and 120 fps `raw` (15 s).

## Multi-core MJPEG (`avi-mjpeg-mt`, default since 2026-09-16)

**Why.** In a LuminoseFM session (Bpod emulator running trials, camera window at 5 Hz, plots) the
SpinVideo `avi-mjpeg` writer queue at 100 fps full frame peaked at 515 and 673 frames in 4.7 min;
with the window alone it grew +1.4 and +2.3 frames/s, which fills the 1200-frame queue in
~10–15 min. With MATLAB idle it stayed flat (peak 3): the single-threaded encoder has only ~4 %
headroom at 100 fps.

**Encoder speed** (`JpegEncoder`, synthetic 1280×1024 frame, Q75): one thread 184 fps
(5.4 ms/frame); 2 / 4 / 8 / 12 threads 364 / 729 / 1257 / 1642 fps.

**Real frames, both cameras, camera window open and MATLAB drawing** (45 s each):

| Frame rate | Encoder threads per camera | Queue peak | Missed / writer drops |
|---|---|---|---|
| 100 fps | 1 | 1 | 0 / 0 |
| 120 fps | 1 | 1 | 0 / 0 |
| 120 fps | 7 (automatic) | 2 | 0 / 0 |

**Quality and size** (60 real frames per camera, compared against a lossless `raw` clip of them):

| Encoder | sideview KB/frame | sideview PSNR | topview KB/frame | topview PSNR |
|---|---|---|---|---|
| SpinVideo `avi-mjpeg`, Quality 75 | 32.5 | 28.2 dB | 40.4 | 29.5 dB |
| `avi-mjpeg-mt`, JpegQuality 15 | 26.0 | 35.5 dB | 30.0 | 33.4 dB |
| `avi-mjpeg-mt`, JpegQuality 30 (default) | 32.6 | 36.7 dB | 42.4 | 34.4 dB |
| `avi-mjpeg-mt`, JpegQuality 75 | – | – | 134.1 | 35.8 dB |

The two quality scales differ (ffmpeg's versus IJG's); above ~30 the extra bits mostly encode
sensor noise. On a synthetic frame, JpegQuality 75 gives the same PSNR as MATLAB `imwrite` Q75.

**17.5-minute LuminoseFM session** (Bpod emulator, 300 trials, camera window, defaults: 100 fps
full frame, `avi-mjpeg-mt`, 7 threads per camera):

| Camera | Frames logged = written = `VideoReader.NumFrames` | Missed | Writer drops | Queue peak | Video file | Hardware frame interval |
|---|---|---|---|---|---|---|
| sideview (24226887) | 104 354 | 0 | 0 | 2 | 3.41 GB (3.25 MB/s) | median 10036 µs, max 10041 µs |
| topview (24226657) | 104 354 | 0 | 0 | 1 | 4.43 GB (4.23 MB/s) | median 10036 µs, max 10041 µs |

≈ 27 GB per hour for both. The topview file crosses 4 GB: frames at the end decode (random access
and sequential), and host arrival intervals stayed below 17 ms.

## 30-minute soak test with the defaults

2026-09-15 (SpinVideo `avi-mjpeg`, the default then); both cameras, 1280×1024, 100 fps, `avi-mjpeg`, passive sync, auto exposure/gain.

| Camera | Frames logged = written | Missed | Writer drops | Queue peak | Video file | Hardware frame interval |
|---|---|---|---|---|---|---|
| sideview (24226887) | 179 597 | 0 | 0 | 3 | 5.42 GB (3.08 MB/s) | median 10036 µs, max 10041 µs |
| topview (24226657) | 179 596 | 0 | 0 | 3 | 6.74 GB (3.83 MB/s) | median 10036 µs, max 10041 µs |

Measured fps stayed at 99.6–99.8 throughout, the writer queue never exceeded 3 frames, and
MATLAB's memory use stayed flat at 2.0 GB. Both videos open in `VideoReader` with exactly as
many frames as their CSV rows, and the embedded TTL was decoded for every frame. Together the
two videos grow by ≈ 24 GB per hour.

## Other measurements

* Copying .NET → MATLAB `uint8` costs about 0.74 ms per full frame. That is why per-frame
  work stays in the C# engine and preview is capped at `PreviewMaxHz` (30).
* A `LineStatusAll` read costs about 0.67 ms, which is why embedded GPIO is the default TTL
  source.

## Hardware validation records

### Passive sync (mode A)

**Verified 2026-09-15** on both cameras with passive sync (embedded TTL on Line0, `avi-mjpeg`)
at 120 fps, 10 s recording. The same checks passed at 100 fps full frame and with cropped
frames (1024×900 at 120 fps, 960×720 at 150 fps; see above).

* 1226 frames per camera, 0 missed, 0 incomplete, 0 writer drops; embedded frame counter continuous
* `TTL_State` decoded for every frame (`TTL_Source = embedded`)
* `GPIO_LineStatus` was 8 on 24226887 and 12 on 24226657, identical to each camera's live
  `LineStatusAll`, so the per-frame bits are the real pin states
* hardware frame interval 8368 µs (p1–p99: 8364–8372 µs)
* video frames = CSV rows, and video/CSV names identical

No TTL source was connected during this check, so detection of real **edges** is covered by the
synthetic-camera tests (`TTL_State` equals the ground-truth square wave frame by frame) but not yet
on the rig. Confirm your wiring once with Bpod pulses and `verifyTtlInput`.

### Strobe (mode C)

The strobe pattern registers were confirmed present on the connected cameras
(`GPIO_STRPAT_CTRL 0x110C = 0x80000100`, masks `0x8000FFFF`). Nothing is wired to the camera
outputs on the rig, so the output waveform itself has not been measured.
