using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text;

namespace SpinCam
{
    /// <summary>How the per-frame TTL state is obtained.</summary>
    public enum TtlSource
    {
        None = 0,
        /// <summary>GPIO state embedded in the image by the camera (FRAME_INFO), latched at end of exposure.</summary>
        Embedded = 1,
        /// <summary>LineStatusAll sampled on a host thread.</summary>
        Polled = 2
    }

    public enum VideoFormat
    {
        None = 0,
        AviMjpg = 1,
        AviUncompressed = 2,
        Mp4H264 = 3,
        /// <summary>Frames are queued for MATLAB (VideoWriter) instead of being encoded natively.</summary>
        MatlabExport = 4,
        /// <summary>Lossless 8-bit frames appended to a .raw file with a JSON sidecar.</summary>
        Raw = 5
    }

    public enum RecordGate
    {
        None = 0,
        /// <summary>Recording starts with the first frame whose TTL is 1 after a frame with TTL 0.</summary>
        FirstRisingEdge = 1
    }

    /// <summary>A grabbed image plus acquisition metadata. The grab loop reuses one instance.</summary>
    public sealed class RawFrame
    {
        public byte[] Buffer;
        public int Width;
        public int Height;
        public long FrameId;
        public long TimestampNs;
        public long HostTicks;
        public bool Incomplete;
    }

    public interface IFrameSource : IDisposable
    {
        string Id { get; }
        void BeginAcquisition();
        void EndAcquisition();

        /// <summary>Waits for the next image and copies it (8-bit) into frame.Buffer. False on timeout.</summary>
        bool Grab(int timeoutMs, RawFrame frame);

        /// <summary>Current line status bitfield (bit k = Line k).</summary>
        long ReadLineStatusAll();
    }

    /// <summary>Per-recording settings; created and filled by MATLAB (spincam.VideoRecorder).</summary>
    public sealed class RecordingOptions
    {
        public string CameraId = "";
        /// <summary>Full video path without extension (SpinVideo appends it).</summary>
        public string VideoPath = "";
        public string CsvPath = "";
        public VideoFormat Format = VideoFormat.AviMjpg;
        public double FrameRate = 30.0;
        public int MjpgQuality = 75;
        public int H264BitrateBps = 8000000;
        public int H264Crf = 23;
        public int MaxFileSizeMB = 0;
        public int QueueCapacityFrames = 1500;
        public int ExportCapacityFrames = 1500;
        public RecordGate Gate = RecordGate.None;
        public bool CsvExtended = true;
    }

    internal sealed class FrameItem
    {
        public byte[] Buffer;
        public int Width;
        public int Height;
        public long FrameNumber;
        public long FrameId;
        public long EmbeddedCounter = -1;
        public long TimestampNs;
        public long HostTicks;
        public long MissedBefore;
        public int Gpio = -1;
        public int Ttl = -1;
        public bool Incomplete;
        public bool WriterDropped;
    }

    internal sealed class BufferPool
    {
        private const int MaxPooled = 64;
        private readonly ConcurrentBag<byte[]> _bag = new ConcurrentBag<byte[]>();

        public byte[] Rent(int size)
        {
            byte[] buffer;
            while (_bag.TryTake(out buffer))
            {
                if (buffer.Length == size)
                {
                    return buffer;
                }
            }
            return new byte[size];
        }

        public void Return(byte[] buffer)
        {
            if (buffer != null && _bag.Count < MaxPooled)
            {
                _bag.Add(buffer);
            }
        }
    }

    /// <summary>Encoding of FRAME_INFO data embedded in the first image bytes (big-endian quadlets).</summary>
    public static class EmbeddedData
    {
        public static uint ReadBE32(byte[] data, int offset)
        {
            return ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16) |
                   ((uint)data[offset + 2] << 8) | data[offset + 3];
        }

        public static void WriteBE32(byte[] data, int offset, uint value)
        {
            data[offset] = (byte)(value >> 24);
            data[offset + 1] = (byte)(value >> 16);
            data[offset + 2] = (byte)(value >> 8);
            data[offset + 3] = (byte)value;
        }

        /// <summary>Embedded GPIO word to line bitfield. The camera stores Line k at bit (31 - k).</summary>
        public static int EmbeddedGpioToLines(uint raw)
        {
            int lines = 0;
            for (int k = 0; k < 4; k++)
            {
                if (((raw >> (31 - k)) & 1u) != 0)
                {
                    lines |= 1 << k;
                }
            }
            return lines;
        }

        public static uint LinesToEmbeddedGpio(long lines)
        {
            uint raw = 0;
            for (int k = 0; k < 4; k++)
            {
                if (((lines >> k) & 1L) != 0)
                {
                    raw |= 1u << (31 - k);
                }
            }
            return raw;
        }
    }

    internal static class Json
    {
        public static string Str(string s)
        {
            if (s == null)
            {
                return "null";
            }
            StringBuilder sb = new StringBuilder(s.Length + 2);
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20)
                        {
                            sb.AppendFormat(CultureInfo.InvariantCulture, "\\u{0:x4}", (int)c);
                        }
                        else
                        {
                            sb.Append(c);
                        }
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        public static string Num(double v)
        {
            if (double.IsNaN(v) || double.IsInfinity(v))
            {
                return "null";
            }
            return v.ToString("R", CultureInfo.InvariantCulture);
        }

        public static string Num(long v)
        {
            return v.ToString(CultureInfo.InvariantCulture);
        }

        public static string Bool(bool v)
        {
            return v ? "true" : "false";
        }

        public static string StrArray(string[] items)
        {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; items != null && i < items.Length; i++)
            {
                if (i > 0)
                {
                    sb.Append(',');
                }
                sb.Append(Str(items[i]));
            }
            return sb.Append(']').ToString();
        }
    }
}
