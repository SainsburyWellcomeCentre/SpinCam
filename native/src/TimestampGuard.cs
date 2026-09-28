using System;

namespace SpinCam
{
    /// <summary>
    /// Removes the spurious steps of a whole multiple of 128 s from a camera's hardware timestamps.
    /// The Chameleon3 (FW 1.13.3.00) through Spinnaker 4.2.0.83 now and then reports a frame
    /// 128 s later than it was taken, and every later frame with it: the camera's clock counts
    /// seconds modulo 128 and its wrap is counted twice. Seen on 2026-09-26 and 2026-09-28, always
    /// where the clock crossed a multiple of 64 s, with FrameID and the embedded counter advancing
    /// by one. A real interval between two frames is followed by the host clock too, so a step in
    /// the hardware interval that the host interval does not show, and that is a whole number of
    /// 128 s periods within ToleranceNs, is taken out of this and every later timestamp.
    /// One per stream, used from the grab thread only.
    /// </summary>
    internal sealed class TimestampGuard
    {
        /// <summary>The period of the camera clock's seconds counter.</summary>
        public const long WrapNs = 128000000000L;

        /// <summary>How far the leftover may be from a whole number of wraps: host arrival jitter.</summary>
        public const long ToleranceNs = 2000000000L;

        private long _lastRawNs;
        private long _lastHostTicks = -1;
        private long _offsetNs;

        /// <summary>Frames whose timestamp needed a new correction since Reset.</summary>
        public long Corrections;

        public void Reset()
        {
            _lastHostTicks = -1;
            _offsetNs = 0;
            Corrections = 0;
        }

        /// <summary>Corrects frame.TimestampNs in place; true when this frame started a new correction.</summary>
        public bool Apply(RawFrame frame)
        {
            long raw = frame.TimestampNs;
            bool corrected = false;
            if (_lastHostTicks >= 0)
            {
                long hardwareNs = raw - _lastRawNs;
                long hostNs = (long)(HostClock.TicksToSeconds(frame.HostTicks - _lastHostTicks) * 1e9);
                long excess = hardwareNs - hostNs;
                long wraps = (long)Math.Round((double)excess / WrapNs);
                if (wraps != 0 && Math.Abs(excess - wraps * WrapNs) < ToleranceNs)
                {
                    _offsetNs -= wraps * WrapNs;
                    Corrections++;
                    corrected = true;
                }
            }
            _lastRawNs = raw;
            _lastHostTicks = frame.HostTicks;
            frame.TimestampNs = raw + _offsetNs;
            return corrected;
        }
    }
}
