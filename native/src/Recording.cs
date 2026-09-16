using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace SpinCam
{
    /// <summary>
    /// One recording of one camera: bounded frame queue, writer thread, video sink and CSV log.
    /// Offer() is called only by the owning stream's grab thread.
    /// </summary>
    internal sealed class Recording
    {
        private readonly RecordingOptions _options;
        private readonly BufferPool _pool;
        private readonly Queue<FrameItem> _queue = new Queue<FrameItem>();
        private readonly Thread _writer;
        private readonly CsvFrameLog _csv;
        private readonly IVideoSink _sink;
        private readonly ExportSink _export;
        private readonly object _errorSync = new object();
        private string _error = "";
        private bool _closing;
        private bool _finished;
        private bool _sinkHealthy = true;
        private int _queuedImages;
        private int _queuePeak;
        private long _frameNumber;
        private int _previousTtl = -1;
        private volatile bool _gateOpen;
        private long _framesLogged;
        private long _framesWritten;
        private long _writerDrops;
        private long _framesMissed;
        private long _framesIncomplete;
        private long _firstHostTicks = -1;
        private long _lastHostTicks = -1;
        private long _gateOpenedTicks = -1;
        private string[] _files = new string[0];

        public Recording(RecordingOptions options, TtlSource ttlSource, BufferPool pool)
        {
            _options = options;
            _pool = pool;
            _gateOpen = options.Gate == RecordGate.None;
            _csv = new CsvFrameLog(options.CsvPath, options.CameraId, options.CsvExtended, ttlSource);
            try
            {
                switch (options.Format)
                {
                    case VideoFormat.None:
                        _sink = null;
                        break;
                    case VideoFormat.MatlabExport:
                        _export = new ExportSink(options.ExportCapacityFrames);
                        _sink = _export;
                        break;
                    case VideoFormat.Raw:
                        _sink = new RawSink(options);
                        break;
                    case VideoFormat.AviMjpgParallel:
                        _sink = new ParallelMjpegSink(options, pool);
                        break;
                    default:
                        _sink = VideoSinkFactory.CreateSpinVideo(options);
                        break;
                }
            }
            catch
            {
                _csv.Dispose();
                throw;
            }
            _writer = new Thread(WriterLoop);
            _writer.IsBackground = true;
            _writer.Name = "SpinCam writer " + options.CameraId;
            _writer.Start();
        }

        public bool GateOpen
        {
            get { return _gateOpen; }
        }

        public ExportSink Export
        {
            get { return _export; }
        }

        public string Error
        {
            get { lock (_errorSync) { return _error; } }
        }

        public int QueueDepth
        {
            get { lock (_queue) { return _queuedImages; } }
        }

        public void Offer(RawFrame frame, long embeddedCounter, int gpio, int ttl, long missedBefore)
        {
            if (!_gateOpen)
            {
                bool rising = _previousTtl == 0 && ttl == 1;
                _previousTtl = ttl;
                if (!rising)
                {
                    return;
                }
                Interlocked.Exchange(ref _gateOpenedTicks, frame.HostTicks);
                _gateOpen = true;
            }

            FrameItem item = new FrameItem();
            item.Width = frame.Width;
            item.Height = frame.Height;
            item.FrameId = frame.FrameId;
            item.TimestampNs = frame.TimestampNs;
            item.HostTicks = frame.HostTicks;
            item.Incomplete = frame.Incomplete;
            item.EmbeddedCounter = embeddedCounter;
            item.Gpio = gpio;
            item.Ttl = ttl;
            item.MissedBefore = missedBefore;

            bool wantImage = _sink != null && !frame.Incomplete && frame.Buffer != null;
            byte[] replacement = wantImage ? _pool.Rent(frame.Buffer.Length) : null;
            lock (_queue)
            {
                if (_closing)
                {
                    _pool.Return(replacement);
                    return;
                }
                item.FrameNumber = _frameNumber++;
                if (wantImage)
                {
                    if (_queuedImages < _options.QueueCapacityFrames)
                    {
                        item.Buffer = frame.Buffer;
                        frame.Buffer = replacement;
                        replacement = null;
                        _queuedImages++;
                        if (_queuedImages > _queuePeak)
                        {
                            _queuePeak = _queuedImages;
                        }
                    }
                    else
                    {
                        item.WriterDropped = true;
                    }
                }
                _queue.Enqueue(item);
                Monitor.Pulse(_queue);
            }
            if (replacement != null)
            {
                _pool.Return(replacement);
            }
        }

        /// <summary>Stops accepting frames and lets the writer drain; does not wait.</summary>
        public void RequestClose()
        {
            lock (_queue)
            {
                _closing = true;
                Monitor.PulseAll(_queue);
            }
        }

        /// <summary>Stops accepting frames, waits for the writer to drain and close files.</summary>
        public bool Close(int timeoutMs)
        {
            RequestClose();
            bool done = _writer.Join(timeoutMs <= 0 ? Timeout.Infinite : timeoutMs);
            if (!done)
            {
                SetError("Writer did not finish within " + timeoutMs + " ms; files may be incomplete.");
            }
            return done;
        }

        public string ToJson()
        {
            string[] files;
            bool finished;
            int queuePeak, queued;
            lock (_queue)
            {
                files = _files;
                finished = _finished;
                queuePeak = _queuePeak;
                queued = _queuedImages;
            }
            long first = Interlocked.Read(ref _firstHostTicks);
            long last = Interlocked.Read(ref _lastHostTicks);
            long gate = Interlocked.Read(ref _gateOpenedTicks);
            StringBuilder sb = new StringBuilder(512);
            sb.Append('{');
            sb.Append("\"cameraId\":").Append(Json.Str(_options.CameraId));
            sb.Append(",\"format\":").Append(Json.Str(_options.Format.ToString()));
            sb.Append(",\"videoPath\":").Append(Json.Str(_options.VideoPath));
            sb.Append(",\"csvPath\":").Append(Json.Str(_options.CsvPath));
            sb.Append(",\"files\":").Append(Json.StrArray(files));
            sb.Append(",\"framesLogged\":").Append(Json.Num(Interlocked.Read(ref _framesLogged)));
            sb.Append(",\"framesWritten\":").Append(Json.Num(Interlocked.Read(ref _framesWritten)));
            sb.Append(",\"writerDrops\":").Append(Json.Num(Interlocked.Read(ref _writerDrops)));
            sb.Append(",\"framesMissed\":").Append(Json.Num(Interlocked.Read(ref _framesMissed)));
            sb.Append(",\"framesIncomplete\":").Append(Json.Num(Interlocked.Read(ref _framesIncomplete)));
            sb.Append(",\"queueDepth\":").Append(Json.Num(queued));
            sb.Append(",\"queuePeak\":").Append(Json.Num(queuePeak));
            ParallelMjpegSink parallel = _sink as ParallelMjpegSink;
            sb.Append(",\"encoderThreads\":").Append(parallel == null ? "null" : Json.Num(parallel.ThreadCount));
            sb.Append(",\"gateOpen\":").Append(Json.Bool(_gateOpen));
            sb.Append(",\"gateOpenedHostTime_s\":").Append(gate < 0 ? "null" : Json.Num(HostClock.TicksToSeconds(gate)));
            sb.Append(",\"firstHostTime_s\":").Append(first < 0 ? "null" : Json.Num(HostClock.TicksToSeconds(first)));
            sb.Append(",\"lastHostTime_s\":").Append(last < 0 ? "null" : Json.Num(HostClock.TicksToSeconds(last)));
            sb.Append(",\"finished\":").Append(Json.Bool(finished));
            sb.Append(",\"error\":").Append(Json.Str(Error));
            sb.Append('}');
            return sb.ToString();
        }

        private void WriterLoop()
        {
            try
            {
                while (true)
                {
                    FrameItem item;
                    lock (_queue)
                    {
                        while (_queue.Count == 0 && !_closing)
                        {
                            Monitor.Wait(_queue);
                        }
                        if (_queue.Count == 0)
                        {
                            break;
                        }
                        item = _queue.Dequeue();
                        if (item.Buffer != null)
                        {
                            _queuedImages--;
                        }
                    }
                    Process(item);
                }
            }
            catch (Exception ex)
            {
                SetError("Writer thread failed: " + ex);
            }
            finally
            {
                Finish();
            }
        }

        private void Process(FrameItem item)
        {
            long videoIndex = -1;
            if (item.Buffer != null)
            {
                bool ownershipTaken = false;
                if (_sinkHealthy)
                {
                    try
                    {
                        videoIndex = _sink.Write(item.Buffer, item.Width, item.Height);
                        ownershipTaken = videoIndex >= 0 && _sink.TakesOwnership;
                    }
                    catch (Exception ex)
                    {
                        SetError("Video writer failed: " + ex.Message);
                        _sinkHealthy = false;
                        videoIndex = -1;
                    }
                }
                if (videoIndex < 0)
                {
                    item.WriterDropped = true;
                }
                if (!ownershipTaken)
                {
                    _pool.Return(item.Buffer);
                }
                item.Buffer = null;
            }

            if (videoIndex >= 0)
            {
                Interlocked.Increment(ref _framesWritten);
            }
            if (item.WriterDropped)
            {
                Interlocked.Increment(ref _writerDrops);
            }
            if (item.MissedBefore > 0)
            {
                Interlocked.Add(ref _framesMissed, item.MissedBefore);
            }
            if (item.Incomplete)
            {
                Interlocked.Increment(ref _framesIncomplete);
            }
            Interlocked.CompareExchange(ref _firstHostTicks, item.HostTicks, -1);
            Interlocked.Exchange(ref _lastHostTicks, item.HostTicks);

            try
            {
                _csv.Write(item, videoIndex);
            }
            catch (Exception ex)
            {
                SetError("CSV write failed: " + ex.Message);
            }
            Interlocked.Increment(ref _framesLogged);
        }

        private void Finish()
        {
            string[] files = new string[0];
            if (_sink != null)
            {
                try
                {
                    _sink.Close();
                    files = _sink.Files;
                }
                catch (Exception ex)
                {
                    SetError("Closing video failed: " + ex.Message);
                }
            }
            try
            {
                _csv.Dispose();
            }
            catch (Exception ex)
            {
                SetError("Closing CSV failed: " + ex.Message);
            }
            lock (_queue)
            {
                _files = files;
                _finished = true;
                while (_queue.Count > 0)
                {
                    FrameItem left = _queue.Dequeue();
                    _pool.Return(left.Buffer);
                }
                _queuedImages = 0;
            }
        }

        private void SetError(string message)
        {
            lock (_errorSync)
            {
                _error = string.IsNullOrEmpty(_error) ? message : _error + " | " + message;
            }
        }
    }
}
