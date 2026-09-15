using System;
using System.Threading;

namespace SpinCam
{
    /// <summary>
    /// Deterministic camera simulator used by the mock backend and the tests.
    /// Ground truth:
    ///   camera counter c starts at 1000 and increments per exposure;
    ///   TTL(c) = (c / TtlHalfPeriodFrames) % 2 on TtlLine;
    ///   exposures with c % DropEvery == DropEvery - 1 are lost in transport;
    ///   every IncompleteEvery-th delivered frame is flagged incomplete;
    ///   FRAME_INFO header: frame counter then GPIO word (each only if enabled), big-endian.
    /// </summary>
    public sealed class SyntheticFrameSource : IFrameSource
    {
        public const long FirstCounter = 1000;

        private readonly string _id;
        private readonly object _sync = new object();
        private int _width;
        private int _height;
        private byte[] _pattern;
        private double _frameRate;
        private long _periodTicks;
        private long _nextDueTicks;
        private long _counter = FirstCounter;
        private long _frameId;
        private long _delivered;
        private long _lineStatus;
        private bool _acquiring;

        public int TtlLine = 0;
        public int TtlHalfPeriodFrames = 10;
        public int DropEvery = 0;
        public int IncompleteEvery = 0;
        public bool EmbedFrameCounter = true;
        public bool EmbedGpio = true;
        public long IdleLineStatus = 8;

        public SyntheticFrameSource(string id, int width, int height, double frameRate)
        {
            _id = id ?? "";
            BuildPattern(width, height);
            FrameRate = frameRate;
            _lineStatus = IdleLineStatus;
        }

        /// <summary>Changes the frame size (follows a crop on the mock camera). Not while acquiring.</summary>
        public void Resize(int width, int height)
        {
            lock (_sync)
            {
                if (_acquiring)
                {
                    throw new InvalidOperationException("Stop acquisition before resizing synthetic source " + _id + ".");
                }
                BuildPattern(width, height);
            }
        }

        private void BuildPattern(int width, int height)
        {
            if (width < 16 || height < 16)
            {
                throw new ArgumentException("Synthetic frames must be at least 16x16.");
            }
            byte[] pattern = new byte[width * height];
            for (int row = 0; row < height; row++)
            {
                int v = row * 255 / (height - 1);
                int start = row * width;
                for (int col = 0; col < width; col++)
                {
                    pattern[start + col] = (byte)((v + (col >> 3)) & 0xFF);
                }
            }
            _pattern = pattern;
            _width = width;
            _height = height;
        }

        public string Id
        {
            get { return _id; }
        }

        public int Width
        {
            get { return _width; }
        }

        public int Height
        {
            get { return _height; }
        }

        public long FramesDelivered
        {
            get { return Interlocked.Read(ref _delivered); }
        }

        public double FrameRate
        {
            get { lock (_sync) { return _frameRate; } }
            set
            {
                if (!(value > 0))
                {
                    throw new ArgumentOutOfRangeException("value", "Frame rate must be positive.");
                }
                lock (_sync)
                {
                    _frameRate = value;
                    _periodTicks = Math.Max(1L, (long)(HostClock.TickFrequency / value));
                }
            }
        }

        public static int TtlForCounter(long counter, int halfPeriodFrames)
        {
            if (halfPeriodFrames <= 0)
            {
                return 0;
            }
            return (int)((counter / halfPeriodFrames) % 2);
        }

        public void BeginAcquisition()
        {
            lock (_sync)
            {
                if (_acquiring)
                {
                    return;
                }
                _frameId = 0;
                _nextDueTicks = HostClock.NowTicks() + _periodTicks;
                _acquiring = true;
            }
            HostClock.AcquireHighResolutionTimer();
        }

        public void EndAcquisition()
        {
            bool wasAcquiring;
            lock (_sync)
            {
                wasAcquiring = _acquiring;
                _acquiring = false;
            }
            if (wasAcquiring)
            {
                HostClock.ReleaseHighResolutionTimer();
            }
        }

        /// <summary>Renders the moving test pattern for a frame index (no header, no TTL marker).</summary>
        public void Render(long frameIndex, byte[] buffer)
        {
            int shift = (int)((frameIndex * 3) % _height);
            Buffer.BlockCopy(_pattern, shift * _width, buffer, 0, (_height - shift) * _width);
            if (shift > 0)
            {
                Buffer.BlockCopy(_pattern, 0, buffer, (_height - shift) * _width, shift * _width);
            }
        }

        public bool Grab(int timeoutMs, RawFrame frame)
        {
            long timeoutTicks = (long)(timeoutMs * (double)HostClock.TickFrequency / 1000.0);
            lock (_sync)
            {
                if (!_acquiring)
                {
                    throw new InvalidOperationException("Synthetic source " + _id + " is not acquiring.");
                }
                if (_nextDueTicks - HostClock.NowTicks() > timeoutTicks)
                {
                    Monitor.Wait(_sync, Math.Max(1, timeoutMs));
                    return false;
                }
            }

            long counter, id, exposureTicks;
            lock (_sync)
            {
                counter = _counter++;
                id = _frameId++;
                exposureTicks = _nextDueTicks;
                _nextDueTicks += _periodTicks;
                if (DropEvery > 0 && counter % DropEvery == DropEvery - 1)
                {
                    counter = _counter++;
                    id = _frameId++;
                    exposureTicks = _nextDueTicks;
                    _nextDueTicks += _periodTicks;
                }
                long now = HostClock.NowTicks();
                if (now - _nextDueTicks > 10 * _periodTicks)
                {
                    _nextDueTicks = now + _periodTicks;
                }
            }
            WaitUntil(exposureTicks);

            int ttl = TtlForCounter(counter, TtlHalfPeriodFrames);
            long lines = (IdleLineStatus & ~(1L << TtlLine)) | ((long)ttl << TtlLine);
            Interlocked.Exchange(ref _lineStatus, lines);

            int size = _width * _height;
            if (frame.Buffer == null || frame.Buffer.Length != size)
            {
                frame.Buffer = new byte[size];
            }
            Render(id, frame.Buffer);
            if (ttl == 1)
            {
                DrawTtlMarker(frame.Buffer);
            }
            int offset = 0;
            if (EmbedFrameCounter)
            {
                EmbeddedData.WriteBE32(frame.Buffer, offset, (uint)counter);
                offset += 4;
            }
            if (EmbedGpio)
            {
                EmbeddedData.WriteBE32(frame.Buffer, offset, EmbeddedData.LinesToEmbeddedGpio(lines));
            }

            frame.Width = _width;
            frame.Height = _height;
            frame.FrameId = id;
            frame.TimestampNs = 5000000000000L + (long)(HostClock.TicksToSeconds(exposureTicks) * 1e9);
            frame.HostTicks = HostClock.NowTicks();
            long delivered = Interlocked.Increment(ref _delivered);
            frame.Incomplete = IncompleteEvery > 0 && delivered % IncompleteEvery == 0;
            return true;
        }

        public long ReadLineStatusAll()
        {
            return Interlocked.Read(ref _lineStatus);
        }

        public void Dispose()
        {
            EndAcquisition();
        }

        private void DrawTtlMarker(byte[] buffer)
        {
            int size = Math.Min(48, Math.Min(_width, _height) / 4);
            int top = Math.Min(8, _height - size);
            int left = Math.Max(0, _width - size - 8);
            for (int row = top; row < top + size; row++)
            {
                int start = row * _width + left;
                for (int col = 0; col < size; col++)
                {
                    buffer[start + col] = 255;
                }
            }
        }

        private static void WaitUntil(long ticks)
        {
            while (true)
            {
                long remaining = ticks - HostClock.NowTicks();
                if (remaining <= 0)
                {
                    return;
                }
                double ms = remaining * 1000.0 / HostClock.TickFrequency;
                if (ms > 1.5)
                {
                    Thread.Sleep((int)(ms - 1.0));
                }
                else
                {
                    Thread.Yield();
                }
            }
        }
    }
}
