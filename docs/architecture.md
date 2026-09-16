# spincam architecture

Developer background. User documentation is in the [README](../README.md); contributor rules
and the full log of design decisions are in [CLAUDE.md](../CLAUDE.md) (§4).

## Options evaluated

| Backend | Verdict | Reason |
|---|---|---|
| **Spinnaker 4.2 via its .NET assembly (`SpinnakerNET_v140.dll`)** + a small C# acquisition engine | **Chosen** | Installed and working with these cameras (the cameras are bound to the Spinnaker "FLIR USB3 Vision Camera" driver). MATLAB loads .NET Framework 4.8 assemblies natively. Grabbing, GPIO line status and IIDC register access (needed for per-frame embedded TTL state) were all verified from MATLAB. A compiled C# engine runs grabbing, TTL decoding, CSV logging and video encoding on background threads, so acquisition keeps running while MATLAB is busy (e.g. inside Bpod's blocking `RunStateMachine`). |
| Spinnaker C/C++ API through MEX | Rejected | The installed Spinnaker package is the runtime/SpinView install: there are no headers or import libraries, and no C++ compiler is configured for MATLAB. It offers no latency advantage over the .NET path for this workload. |
| FlyCapture2 SDK 2.13 | Rejected | End-of-life SDK. It needs the legacy PGR USB driver, while the cameras are currently bound to the Spinnaker driver. It has no GenICam node map and no future support. |
| Image Acquisition Toolbox (`gentl` / `pointgrey` adaptors) | Rejected | Not installed (licensed but absent). The `pointgrey` adaptor depends on FlyCapture2. `gentl` exposes neither per-frame GPIO state nor register access. Frame delivery runs in MATLAB's thread, which a blocking Bpod protocol would starve. |

## Layering

```
 ┌───────────────────────── MATLAB (single thread) ─────────────────────────┐
 │  Bpod protocol / scripts            spincam.LiveViewer (uifigure + timer) │
 │            │                                   │                          │
 │            ▼                                   ▼                          │
 │  spincam.CameraManager ──► spincam.SyncController   spincam.VideoRecorder │
 │            │                     │ (node + register writes)   │           │
 │            ▼                     ▼                            │           │
 │  spincam.CameraDevice ── NodeMapAdapter / RegisterPort        │           │
 │   (property control)     (Spinnaker or Mock implementation)   │           │
 └────────────┬──────────────────────────────────────────────────┼───────────┘
              │ .NET interop (control only; no per-frame MATLAB work)
 ┌────────────▼────────────── SpinCamEngine.dll (C# 5, .NET 4.8) ─▼──────────┐
 │  CameraStream (one per camera)                                            │
 │    grab thread ──► TTL decode, drop detection ──► bounded queue           │
 │    writer thread ──► SpinVideo AVI/MP4 | raw | MATLAB queue ──► CSV log   │
 │                  └──► parallel MJPEG: N encoder threads ──► muxer ──► AVI │
 │    optional TTL poll thread (LineStatusAll)                               │
 │  IFrameSource: SpinnakerFrameSource | SyntheticFrameSource (mock/tests)   │
 └────────────┬──────────────────────────────────────────────────────────────┘
              ▼
   SpinnakerNET_v*.dll / SpinVideoNET_v*.dll (installed Spinnaker; verified 4.2.0.83) ─► USB3
```

## Multi-core MJPEG (`avi-mjpeg-mt`)

SpinVideo's MJPEG encoder (ffmpeg 3.x) runs on the recording's single writer thread and
exposes no threading option; on real full frames it encodes ≈ 104 fps, 4 % above the 100 fps
default, so a busy host made its queue grow. `avi-mjpeg-mt` encodes in the engine instead:

* `ParallelMjpegSink` (an `IVideoSink`) takes ownership of each frame buffer in `Write`, gives
  it the next video index and queues it for `EncoderThreads` worker threads, each with its own
  `JpegEncoder`. Workers return the pixel buffer to the pool and hand the JPEG to a muxer thread,
  which writes frames to `AviWriter` strictly in index order (a reorder dictionary keyed by
  index), outside any lock.
* **Backpressure.** `Write` blocks while `2 × EncoderThreads` frames are in flight, so a
  machine that cannot keep up backs up into the recording's own bounded queue, where overflow is
  counted and flagged as writer drops exactly as for every other format. `VideoFrameIndex` in
  the CSV is the index assigned in `Write`, which is the frame's position in the file.
* **Failure.** An exception on an encoder or the muxer faults the sink: the next `Write`
  throws (the recording marks the sink unhealthy and logs later frames with index −1) and the
  error reaches `summary.Error`. Frames in flight at that moment are not in the file.
* `JpegEncoder`: baseline JPEG, AAN floating-point DCT, IJG quality scaling of the Annex K
  tables, standard Huffman tables, edge replication for sizes that are not multiples of 16.
  Mono8 is written as YCbCr 4:2:0 with constant chroma (the layout ffmpeg writes, yuvj420p),
  which every MJPEG AVI decoder reads; the chroma blocks cost two Huffman codes each. ≈ 5.4 ms
  per 1280×1024 frame on one core of the development rig (≈ 184 fps), linear with threads.
* `AviWriter`: OpenDML (AVI 2.0). The first `RIFF 'AVI '` holds `hdrl` (with a 1024-entry super
  index `indx` and `odml/dmlh`), its frames, a standard index `ix00` and a legacy `idx1`; each
  further `RIFF 'AVIX'` (1 GB by default, `AviRiffSizeMB` in tests) holds frames and its own
  `ix00`. Sizes, frame counts and indexes are patched on close, so a recording is readable
  only once it has been stopped (as with SpinVideo).
* It needs no SpinVideo, so it also works in `NO_SPINVIDEO` builds.

## How per-frame TTL state is captured

The Chameleon3 **FRAME_INFO register (IIDC `0x12F8`)** can embed image-specific data into
the first pixels of every frame. The camera latches the values *at the end of exposure*.
`spincam` enables two embedded fields:

* bytes 0–3: camera frame counter (big-endian), used as a second drop detector
* bytes 4–7: GPIO pin state (big-endian); **Line *k* ↔ bit (31 − k)**, so Line0 is the MSB

This gives a TTL state **latched by the camera's own hardware** for every frame, with no
host polling latency. The 8 overwritten pixels are restored cosmetically in the saved
video by copying the pixels from row 1 (`ScrubEmbeddedPixels`, on by default).

Verified on 2026-09-15: register base `0xFFFFF0F00000`, register values are little-endian
through `ReadPort`/`WritePort`, the embedded frame counter increments by 1 per frame, and
the embedded GPIO bits match `LineStatusAll` on both cameras.

A **polled** fallback (`TtlSource = 'polled'`) samples the `LineStatusAll` node on a
background thread. Each read takes about 0.7 ms (measured). The state is sampled on the
host rather than latched per exposure.

## Spinnaker versions and the engine build

* `spincam.internal.SpinnakerLocator` finds the assemblies (search order in
  [README §2](../README.md#where-spincam-looks-for-spinnaker)). `NativeEngine` compiles
  `SpinCamEngine.dll` against exactly the `SpinnakerNET` and `SpinVideoNET` files found and
  records them in `native\bin\SpinCamEngine.build.json`. A different installation makes the
  engine stale, and `NativeEngine.load` rebuilds a stale engine.
* SpinVideo option members and `SetMaximumFileSize` are set by reflection at run time,
  because their types differ between releases.
* Without `SpinVideoNET` the engine is compiled with `NO_SPINVIDEO` (`Engine.HasSpinVideo` is
  false), and the SpinVideo formats raise `spincam:recorder:noSpinVideo` in MATLAB before
  recording starts.
* Only Spinnaker 4.2.0.83 is verified (`NativeEngine.VerifiedSpinnakerVersion`). Other
  releases are expected to work if their .NET API still provides what spincam uses: camera
  list and node maps, `GetNextImage`, `ReadPort`/`WritePort`, `ManagedImage`,
  `ManagedSpinVideo`.
