using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace SpinCam
{
    /// <summary>
    /// MJPEG AVI encoded on several cores: Write hands the frame to a pool of JPEG encoder threads
    /// and returns its video index at once; a muxer thread writes the encoded frames to an
    /// OpenDML AVI (AviWriter) strictly in index order.
    /// </summary>
    /// <remarks>
    /// SpinVideo's MJPEG encoder (ffmpeg 3.x) runs on the recording's single writer thread and
    /// manages ~104 fps per camera at 1280x1024, barely above the default 100 fps. Here the
    /// encoding scales with cores (one JpegEncoder per thread, ~180 fps each on the rig).
    ///
    /// Backpressure: Write blocks while EncoderThreads x 2 frames are in flight, so a slow
    /// machine still backs up into the recording's own bounded queue, where overflow is counted
    /// as writer drops exactly as for the other formats. The sink owns the buffers it accepts and
    /// returns them to the pool after encoding. A failure on any thread faults the sink: later
    /// Writes throw, and frames not yet written are missing from the file (the error says so).
    /// </remarks>
    internal sealed class ParallelMjpegSink : IVideoSink
    {
        private const long DefaultRiffBytes = 1L << 30;

        private sealed class Job
        {
            public long Index;
            public byte[] Pixels;
            public int Width;
            public int Height;
        }

        private sealed class Encoded
        {
            public byte[] Data;
            public int Length;
        }

        private readonly RecordingOptions _options;
        private readonly BufferPool _pool;
        private readonly string _path;
        private readonly int _threadCount;
        private readonly int _maxInFlight;
        private readonly object _sync = new object();
        private readonly Queue<Job> _jobs = new Queue<Job>();
        private readonly Dictionary<long, Encoded> _done = new Dictionary<long, Encoded>();
        private readonly ConcurrentBag<byte[]> _outputPool = new ConcurrentBag<byte[]>();
        private Thread[] _encoders;
        private Thread _muxer;
        private AviWriter _avi;
        private long _nextIndex;
        private long _nextToWrite;
        private int _inFlight;
        private int _width;
        private int _height;
        private bool _closing;
        private bool _closed;
        private string _fault;
        private string[] _files = new string[0];

        public ParallelMjpegSink(RecordingOptions options, BufferPool pool)
        {
            if (string.IsNullOrEmpty(options.VideoPath))
            {
                throw new ArgumentException("VideoPath is empty.");
            }
            _options = options;
            _pool = pool;
            _path = options.VideoPath + ".avi";
            string dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            _threadCount = ResolveThreads(options.EncoderThreads);
            _maxInFlight = 2 * _threadCount;
        }

        /// <summary>Encoder threads used when RecordingOptions.EncoderThreads is 0.</summary>
        public static int AutoThreads
        {
            get { return Math.Max(2, Math.Min(8, Environment.ProcessorCount / 4)); }
        }

        public static int ResolveThreads(int requested)
        {
            return requested > 0 ? Math.Min(requested, 64) : AutoThreads;
        }

        public int ThreadCount
        {
            get { return _threadCount; }
        }

        public bool TakesOwnership
        {
            get { return true; }
        }

        public string[] Files
        {
            get { lock (_sync) { return _files; } }
        }

        public long Write(byte[] buffer, int width, int height)
        {
            lock (_sync)
            {
                ThrowIfUnusable();
                if (_avi == null)
                {
                    Start(width, height);
                }
                else if (width != _width || height != _height)
                {
                    throw new InvalidOperationException("Frame size changed during an MJPEG recording.");
                }
                while (_inFlight >= _maxInFlight && _fault == null)
                {
                    Monitor.Wait(_sync);
                }
                ThrowIfUnusable();
                Job job = new Job();
                job.Index = _nextIndex++;
                job.Pixels = buffer;
                job.Width = width;
                job.Height = height;
                _inFlight++;
                _jobs.Enqueue(job);
                Monitor.PulseAll(_sync);
                return job.Index;
            }
        }

        public void Close()
        {
            Thread[] encoders;
            Thread muxer;
            lock (_sync)
            {
                if (_closed)
                {
                    return;
                }
                _closed = true;
                _closing = true;
                encoders = _encoders;
                muxer = _muxer;
                Monitor.PulseAll(_sync);
            }
            if (encoders != null)
            {
                foreach (Thread t in encoders)
                {
                    t.Join();
                }
            }
            if (muxer != null)
            {
                muxer.Join();
            }
            string closeError = null;
            if (_avi != null)
            {
                try
                {
                    _avi.Close();
                }
                catch (Exception ex)
                {
                    closeError = "Closing MJPEG AVI failed: " + ex.Message;
                }
            }
            lock (_sync)
            {
                if (closeError != null)
                {
                    _fault = _fault == null ? closeError : _fault + " | " + closeError;
                }
                _files = _avi != null ? new string[] { _path } : new string[0];
                while (_jobs.Count > 0)
                {
                    _pool.Return(_jobs.Dequeue().Pixels);
                }
                _done.Clear();
            }
            if (closeError != null || _fault != null)
            {
                throw new IOException(_fault);
            }
        }

        public void Dispose()
        {
            try
            {
                Close();
            }
            catch (IOException)
            {
                // Already reported by Close to the recording.
            }
        }

        private void ThrowIfUnusable()
        {
            if (_fault != null)
            {
                throw new IOException(_fault);
            }
            if (_closing)
            {
                throw new ObjectDisposedException("ParallelMjpegSink");
            }
        }

        private void Start(int width, int height)
        {
            _width = width;
            _height = height;
            long riffBytes = _options.AviRiffSizeMB > 0 ? (long)_options.AviRiffSizeMB << 20 : DefaultRiffBytes;
            _avi = new AviWriter(_path, width, height, _options.FrameRate, riffBytes);
            _encoders = new Thread[_threadCount];
            for (int i = 0; i < _threadCount; i++)
            {
                Thread t = new Thread(EncoderLoop);
                t.IsBackground = true;
                t.Name = "SpinCam MJPEG encoder " + _options.CameraId + " #" + i;
                _encoders[i] = t;
                t.Start();
            }
            _muxer = new Thread(MuxerLoop);
            _muxer.IsBackground = true;
            _muxer.Name = "SpinCam MJPEG muxer " + _options.CameraId;
            _muxer.Start();
        }

        private void EncoderLoop()
        {
            JpegEncoder encoder = new JpegEncoder(_options.MjpgQuality);
            while (true)
            {
                Job job;
                lock (_sync)
                {
                    while (_jobs.Count == 0 && !_closing && _fault == null)
                    {
                        Monitor.Wait(_sync);
                    }
                    if (_jobs.Count == 0 || _fault != null)
                    {
                        return;
                    }
                    job = _jobs.Dequeue();
                }
                Encoded result = new Encoded();
                try
                {
                    byte[] output;
                    if (!_outputPool.TryTake(out output))
                    {
                        output = null;
                    }
                    result.Length = encoder.Encode(job.Pixels, job.Width, job.Height, ref output);
                    result.Data = output;
                }
                catch (Exception ex)
                {
                    Fail("MJPEG encoder failed on frame " + job.Index + ": " + ex.Message);
                    return;
                }
                finally
                {
                    _pool.Return(job.Pixels);
                }
                lock (_sync)
                {
                    _done[job.Index] = result;
                    Monitor.PulseAll(_sync);
                }
            }
        }

        private void MuxerLoop()
        {
            while (true)
            {
                Encoded next;
                lock (_sync)
                {
                    while (!_done.ContainsKey(_nextToWrite) && _fault == null &&
                           !(_closing && _nextToWrite >= _nextIndex))
                    {
                        Monitor.Wait(_sync);
                    }
                    if (_fault != null || !_done.TryGetValue(_nextToWrite, out next))
                    {
                        return;
                    }
                    _done.Remove(_nextToWrite);
                }
                try
                {
                    _avi.WriteFrame(next.Data, next.Length);
                }
                catch (Exception ex)
                {
                    Fail("Writing MJPEG AVI failed: " + ex.Message);
                    return;
                }
                if (_outputPool.Count < 2 * _maxInFlight)
                {
                    _outputPool.Add(next.Data);
                }
                lock (_sync)
                {
                    _nextToWrite++;
                    _inFlight--;
                    Monitor.PulseAll(_sync);
                }
            }
        }

        private void Fail(string message)
        {
            lock (_sync)
            {
                if (_fault == null)
                {
                    _fault = message;
                }
                Monitor.PulseAll(_sync);
            }
        }
    }
}
