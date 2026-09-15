using System;
using System.Text;
using System.Threading;

namespace SpinCam
{
    /// <summary>
    /// Continuous acquisition for one camera on a background grab thread: drop detection,
    /// TTL decoding, preview snapshots and (optionally) a Recording.
    /// Configure the public fields before Start(); MATLAB never touches frames per-frame.
    /// </summary>
    public sealed class CameraStream : IDisposable
    {
        public int TtlLine = 0;
        public TtlSource TtlMode = TtlSource.Embedded;
        /// <summary>Byte offset of the embedded frame counter, or -1 when not embedded.</summary>
        public int EmbeddedFrameCounterOffset = -1;
        /// <summary>Byte offset of the embedded GPIO word, or -1 when not embedded.</summary>
        public int EmbeddedGpioOffset = -1;
        public bool ScrubEmbeddedPixels = true;
        public double PreviewMaxHz = 30.0;
        public int GrabTimeoutMs = 200;
        public int PollIntervalMs = 1;

        private readonly IFrameSource _source;
        private readonly string _cameraId;
        private readonly BufferPool _pool = new BufferPool();
        private readonly object _stateSync = new object();
        private readonly object _previewSync = new object();
        private readonly object _errorSync = new object();
        private Thread _grabThread;
        private Thread _pollThread;
        private volatile bool _running;
        private volatile bool _faulted;
        private volatile Recording _recording;
        private volatile Recording _lastRecording;
        private Recording _stopping;
        private volatile ExportSink _export;
        private string _lastError = "";

        private long _framesReceived;
        private long _framesMissed;
        private long _framesIncomplete;
        private long _grabTimeouts;
        private long _lastFrameId = -1;
        private long _lastTimestampNs;
        private long _lastHostTicks = -1;
        private long _polledLineStatus = -1;
        private int _lastTtl = -1;
        private int _lastGpio = -1;
        private double _fps;

        private byte[] _preview;
        private int _previewWidth;
        private int _previewHeight;
        private int _previewTtl = -1;
        private long _previewFrameId = -1;
        private long _previewSequence;
        private long _lastPreviewTicks = -1;

        public CameraStream(IFrameSource source)
        {
            if (source == null)
            {
                throw new ArgumentNullException("source");
            }
            _source = source;
            _cameraId = source.Id;
        }

        public string CameraId
        {
            get { return _cameraId; }
        }

        public bool IsRunning
        {
            get { return _running; }
        }

        public bool IsRecording
        {
            get { return _recording != null; }
        }

        public bool IsArmed
        {
            get
            {
                Recording r = _recording;
                return r != null && !r.GateOpen;
            }
        }

        public bool Faulted
        {
            get { return _faulted; }
        }

        public string LastError
        {
            get { lock (_errorSync) { return _lastError; } }
        }

        public long FramesReceived
        {
            get { return Interlocked.Read(ref _framesReceived); }
        }

        public void Start()
        {
            lock (_stateSync)
            {
                if (_running)
                {
                    return;
                }
                if (TtlLine < 0 || TtlLine > 3)
                {
                    throw new ArgumentOutOfRangeException("TtlLine", "TtlLine must be 0..3.");
                }
                _faulted = false;
                lock (_errorSync)
                {
                    _lastError = "";
                }
                Interlocked.Exchange(ref _framesReceived, 0);
                Interlocked.Exchange(ref _framesMissed, 0);
                Interlocked.Exchange(ref _framesIncomplete, 0);
                Interlocked.Exchange(ref _grabTimeouts, 0);
                Interlocked.Exchange(ref _lastFrameId, -1);
                Interlocked.Exchange(ref _polledLineStatus, -1);
                _fps = 0;
                _lastTtl = -1;
                _lastGpio = -1;

                _source.BeginAcquisition();
                _running = true;
                if (TtlMode == TtlSource.Polled)
                {
                    HostClock.AcquireHighResolutionTimer();
                    _pollThread = new Thread(PollLoop);
                    _pollThread.IsBackground = true;
                    _pollThread.Name = "SpinCam TTL poll " + _cameraId;
                    _pollThread.Start();
                }
                _grabThread = new Thread(GrabLoop);
                _grabThread.IsBackground = true;
                _grabThread.Priority = ThreadPriority.AboveNormal;
                _grabThread.Name = "SpinCam grab " + _cameraId;
                _grabThread.Start();
            }
        }

        /// <summary>Stops grabbing, ends acquisition and finalizes any active recording.</summary>
        public string Stop()
        {
            Thread grab, poll;
            lock (_stateSync)
            {
                _running = false;
                grab = _grabThread;
                poll = _pollThread;
                _grabThread = null;
                _pollThread = null;
            }
            if (grab != null && !grab.Join(Math.Max(5000, GrabTimeoutMs * 10)))
            {
                SetError("Grab thread did not stop in time.");
            }
            if (poll != null)
            {
                poll.Join(2000);
                HostClock.ReleaseHighResolutionTimer();
            }
            try
            {
                _source.EndAcquisition();
            }
            catch (Exception ex)
            {
                SetError("EndAcquisition failed: " + ex.Message);
            }
            bool pending;
            lock (_stateSync)
            {
                pending = _recording != null || _stopping != null;
            }
            if (pending)
            {
                return StopRecording(120000);
            }
            return "{}";
        }

        public void StartRecording(RecordingOptions options)
        {
            if (options == null)
            {
                throw new ArgumentNullException("options");
            }
            lock (_stateSync)
            {
                if (_recording != null)
                {
                    throw new InvalidOperationException("Camera " + _cameraId + " is already recording.");
                }
                if (!_running)
                {
                    throw new InvalidOperationException("Camera " + _cameraId + " is not streaming; call Start() first.");
                }
                if (options.Gate != RecordGate.None && TtlMode == TtlSource.None)
                {
                    throw new InvalidOperationException("A TTL-gated recording requires a TTL source.");
                }
                if (string.IsNullOrEmpty(options.CameraId))
                {
                    options.CameraId = _cameraId;
                }
                Recording recording = new Recording(options, TtlMode, _pool);
                _export = recording.Export;
                _lastRecording = recording;
                _recording = recording;
            }
        }

        /// <summary>
        /// Detaches the active recording and signals its writer to drain, without waiting.
        /// Call on every camera first, then EndStopRecording, so all logs end together.
        /// </summary>
        public void BeginStopRecording()
        {
            Recording recording;
            lock (_stateSync)
            {
                recording = _recording;
                _recording = null;
                if (recording != null)
                {
                    _stopping = recording;
                }
            }
            if (recording != null)
            {
                recording.RequestClose();
            }
        }

        /// <summary>Waits for a recording detached by BeginStopRecording; returns its summary JSON.</summary>
        public string EndStopRecording(int timeoutMs)
        {
            Recording recording;
            lock (_stateSync)
            {
                recording = _stopping;
                _stopping = null;
            }
            if (recording == null)
            {
                Recording last = _lastRecording;
                return last == null ? "{}" : last.ToJson();
            }
            recording.Close(timeoutMs);
            return recording.ToJson();
        }

        /// <summary>Finalizes the active recording; returns its summary as JSON.</summary>
        public string StopRecording(int timeoutMs)
        {
            BeginStopRecording();
            return EndStopRecording(timeoutMs);
        }

        public bool TryDequeueExport(out byte[] data, out int width, out int height, out long videoIndex)
        {
            data = null;
            width = 0;
            height = 0;
            videoIndex = -1;
            ExportSink export = _export;
            ExportFrame frame;
            if (export == null || !export.TryDequeue(out frame))
            {
                return false;
            }
            data = frame.Data;
            width = frame.Width;
            height = frame.Height;
            videoIndex = frame.VideoIndex;
            return true;
        }

        public int ExportQueueDepth
        {
            get
            {
                ExportSink export = _export;
                return export == null ? 0 : export.Count;
            }
        }

        public void ClearExport()
        {
            _export = null;
        }

        /// <summary>Copy of the most recent preview snapshot (empty array if none yet).</summary>
        public byte[] GetLatestFrame(out int width, out int height, out long frameId, out int ttl, out long sequence)
        {
            lock (_previewSync)
            {
                width = _previewWidth;
                height = _previewHeight;
                frameId = _previewFrameId;
                ttl = _previewTtl;
                sequence = _previewSequence;
                if (_preview == null)
                {
                    return new byte[0];
                }
                return (byte[])_preview.Clone();
            }
        }

        public string GetStatsJson()
        {
            Recording active = _recording;
            Recording shown = active ?? _lastRecording;
            StringBuilder sb = new StringBuilder(1024);
            sb.Append('{');
            sb.Append("\"cameraId\":").Append(Json.Str(_cameraId));
            sb.Append(",\"running\":").Append(Json.Bool(_running));
            sb.Append(",\"recording\":").Append(Json.Bool(active != null));
            sb.Append(",\"armed\":").Append(Json.Bool(active != null && !active.GateOpen));
            sb.Append(",\"faulted\":").Append(Json.Bool(_faulted));
            sb.Append(",\"lastError\":").Append(Json.Str(LastError));
            sb.Append(",\"framesReceived\":").Append(Json.Num(Interlocked.Read(ref _framesReceived)));
            sb.Append(",\"framesMissed\":").Append(Json.Num(Interlocked.Read(ref _framesMissed)));
            sb.Append(",\"framesIncomplete\":").Append(Json.Num(Interlocked.Read(ref _framesIncomplete)));
            sb.Append(",\"grabTimeouts\":").Append(Json.Num(Interlocked.Read(ref _grabTimeouts)));
            sb.Append(",\"fps\":").Append(Json.Num(_fps));
            sb.Append(",\"lastFrameId\":").Append(Json.Num(Interlocked.Read(ref _lastFrameId)));
            sb.Append(",\"lastTimestampNs\":").Append(Json.Num(Interlocked.Read(ref _lastTimestampNs)));
            long lastHost = Interlocked.Read(ref _lastHostTicks);
            sb.Append(",\"lastHostTime_s\":").Append(lastHost < 0 ? "null" : Json.Num(HostClock.TicksToSeconds(lastHost)));
            sb.Append(",\"lastTtl\":").Append(Json.Num(_lastTtl));
            sb.Append(",\"lastGpio\":").Append(Json.Num(_lastGpio));
            sb.Append(",\"exportQueue\":").Append(Json.Num(ExportQueueDepth));
            sb.Append(",\"queueDepth\":").Append(Json.Num(active == null ? 0 : active.QueueDepth));
            sb.Append(",\"lastRecording\":").Append(shown == null ? "null" : shown.ToJson());
            sb.Append('}');
            return sb.ToString();
        }

        public void Dispose()
        {
            Stop();
        }

        private void GrabLoop()
        {
            RawFrame frame = new RawFrame();
            long lastId = -1;
            long lastCounter = -1;
            long lastTicks = -1;
            try
            {
                while (_running)
                {
                    if (!_source.Grab(GrabTimeoutMs, frame))
                    {
                        Interlocked.Increment(ref _grabTimeouts);
                        continue;
                    }
                    Interlocked.Increment(ref _framesReceived);

                    long missed = 0;
                    if (lastId >= 0 && frame.FrameId > lastId + 1)
                    {
                        missed = frame.FrameId - lastId - 1;
                    }
                    lastId = frame.FrameId;

                    bool haveData = !frame.Incomplete && frame.Buffer != null;
                    int counterOffset = EmbeddedFrameCounterOffset;
                    int gpioOffset = EmbeddedGpioOffset;
                    long counter = -1;
                    if (!haveData)
                    {
                        // An incomplete frame was received, not lost: skip the next counter comparison
                        // (FrameID continuity still detects real losses).
                        lastCounter = -1;
                    }
                    else if (counterOffset >= 0 && counterOffset + 4 <= frame.Buffer.Length)
                    {
                        counter = EmbeddedData.ReadBE32(frame.Buffer, counterOffset);
                        if (lastCounter >= 0 && counter > lastCounter + 1)
                        {
                            missed = Math.Max(missed, counter - lastCounter - 1);
                        }
                        lastCounter = counter;
                    }

                    int gpio = -1;
                    if (TtlMode == TtlSource.Embedded)
                    {
                        if (haveData && gpioOffset >= 0 && gpioOffset + 4 <= frame.Buffer.Length)
                        {
                            gpio = EmbeddedData.EmbeddedGpioToLines(EmbeddedData.ReadBE32(frame.Buffer, gpioOffset));
                        }
                    }
                    else if (TtlMode == TtlSource.Polled)
                    {
                        long status = Interlocked.Read(ref _polledLineStatus);
                        gpio = status < 0 ? -1 : (int)(status & 0xF);
                    }
                    int ttl = gpio < 0 ? -1 : (gpio >> TtlLine) & 1;

                    if (missed > 0)
                    {
                        Interlocked.Add(ref _framesMissed, missed);
                    }
                    if (frame.Incomplete)
                    {
                        Interlocked.Increment(ref _framesIncomplete);
                    }
                    if (haveData && ScrubEmbeddedPixels)
                    {
                        Scrub(frame, Math.Max(counterOffset, gpioOffset));
                    }

                    if (lastTicks >= 0 && frame.HostTicks > lastTicks)
                    {
                        double instantaneous = (double)HostClock.TickFrequency / (frame.HostTicks - lastTicks);
                        _fps = _fps <= 0 ? instantaneous : 0.95 * _fps + 0.05 * instantaneous;
                    }
                    lastTicks = frame.HostTicks;
                    Interlocked.Exchange(ref _lastFrameId, frame.FrameId);
                    Interlocked.Exchange(ref _lastTimestampNs, frame.TimestampNs);
                    Interlocked.Exchange(ref _lastHostTicks, frame.HostTicks);
                    _lastTtl = ttl;
                    _lastGpio = gpio;

                    if (haveData)
                    {
                        UpdatePreview(frame, ttl);
                    }

                    Recording recording = _recording;
                    if (recording != null)
                    {
                        recording.Offer(frame, counter, gpio, ttl, missed);
                    }
                }
            }
            catch (Exception ex)
            {
                _faulted = true;
                SetError("Grab loop failed: " + ex.Message);
            }
        }

        private void PollLoop()
        {
            try
            {
                while (_running)
                {
                    Interlocked.Exchange(ref _polledLineStatus, _source.ReadLineStatusAll());
                    Thread.Sleep(Math.Max(1, PollIntervalMs));
                }
            }
            catch (Exception ex)
            {
                SetError("TTL polling failed: " + ex.Message);
            }
        }

        private void UpdatePreview(RawFrame frame, int ttl)
        {
            double maxHz = PreviewMaxHz;
            if (maxHz <= 0)
            {
                return;
            }
            long minInterval = (long)(HostClock.TickFrequency / maxHz);
            if (_lastPreviewTicks >= 0 && frame.HostTicks - _lastPreviewTicks < minInterval)
            {
                return;
            }
            _lastPreviewTicks = frame.HostTicks;
            lock (_previewSync)
            {
                if (_preview == null || _preview.Length != frame.Buffer.Length)
                {
                    _preview = new byte[frame.Buffer.Length];
                }
                Buffer.BlockCopy(frame.Buffer, 0, _preview, 0, frame.Buffer.Length);
                _previewWidth = frame.Width;
                _previewHeight = frame.Height;
                _previewFrameId = frame.FrameId;
                _previewTtl = ttl;
                _previewSequence++;
            }
        }

        private static void Scrub(RawFrame frame, int lastOffset)
        {
            if (lastOffset < 0)
            {
                return;
            }
            int bytes = lastOffset + 4;
            if (frame.Height >= 2 && frame.Width >= bytes)
            {
                Buffer.BlockCopy(frame.Buffer, frame.Width, frame.Buffer, 0, bytes);
            }
        }

        private void SetError(string message)
        {
            lock (_errorSync)
            {
                _lastError = string.IsNullOrEmpty(_lastError) ? message : _lastError + " | " + message;
            }
        }
    }
}
