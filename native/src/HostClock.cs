using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

namespace SpinCam
{
    /// <summary>
    /// Monotonic high-resolution host clock shared by all streams, the CSV logs and MATLAB
    /// (CameraManager.hostTime / events log). The wall-clock anchor is captured on a
    /// DateTime tick edge so its absolute error stays below the system clock resolution.
    /// </summary>
    public static class HostClock
    {
        private const string IsoFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffffzzz";
        private static readonly Stopwatch Watch;
        private static readonly DateTime AnchorUtc;
        private static readonly object HighResolutionSync = new object();
        private static int _highResolutionUsers;

        static HostClock()
        {
            DateTime first = DateTime.UtcNow;
            DateTime edge = first;
            Stopwatch guard = Stopwatch.StartNew();
            while (edge == first && guard.ElapsedMilliseconds < 50)
            {
                edge = DateTime.UtcNow;
            }
            Watch = Stopwatch.StartNew();
            AnchorUtc = edge;
        }

        public static long TickFrequency
        {
            get { return Stopwatch.Frequency; }
        }

        public static long NowTicks()
        {
            return Watch.ElapsedTicks;
        }

        public static double NowSeconds()
        {
            return TicksToSeconds(Watch.ElapsedTicks);
        }

        public static double TicksToSeconds(long ticks)
        {
            return (double)ticks / Stopwatch.Frequency;
        }

        public static DateTime ToLocalDateTime(long ticks)
        {
            long dotNetTicks = (long)(ticks * (10000000.0 / Stopwatch.Frequency));
            return AnchorUtc.AddTicks(dotNetTicks).ToLocalTime();
        }

        public static string FormatIso(long ticks)
        {
            return ToLocalDateTime(ticks).ToString(IsoFormat, CultureInfo.InvariantCulture);
        }

        public static string NowIso()
        {
            return FormatIso(Watch.ElapsedTicks);
        }

        /// <summary>Wall-clock time (local, ISO-8601) that corresponds to HostTime_s = 0.</summary>
        public static string AnchorIso
        {
            get { return AnchorUtc.ToLocalTime().ToString(IsoFormat, CultureInfo.InvariantCulture); }
        }

        [DllImport("winmm.dll")]
        private static extern uint timeBeginPeriod(uint period);

        [DllImport("winmm.dll")]
        private static extern uint timeEndPeriod(uint period);

        /// <summary>Requests 1 ms OS timer resolution (TTL polling, synthetic sources). Reference counted.</summary>
        public static void AcquireHighResolutionTimer()
        {
            lock (HighResolutionSync)
            {
                if (_highResolutionUsers++ == 0)
                {
                    timeBeginPeriod(1);
                }
            }
        }

        public static void ReleaseHighResolutionTimer()
        {
            lock (HighResolutionSync)
            {
                if (_highResolutionUsers > 0 && --_highResolutionUsers == 0)
                {
                    timeEndPeriod(1);
                }
            }
        }
    }
}
