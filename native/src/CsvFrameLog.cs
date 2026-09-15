using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace SpinCam
{
    /// <summary>Per-camera frame metadata CSV. Column contract is documented in README section 7.</summary>
    internal sealed class CsvFrameLog : IDisposable
    {
        public const string RequiredHeader =
            "FrameNumber,CameraID,HardwareTimestamp_us,HostTimestamp_datetime,TTL_State,DroppedFrameFlag";

        public const string ExtendedHeader =
            ",DeviceFrameID,EmbeddedFrameCounter,FramesMissedBefore,HostTime_s,GPIO_LineStatus," +
            "TTL_Source,VideoFrameIndex,WriterDropFlag,IncompleteFlag";

        private readonly StreamWriter _writer;
        private readonly bool _extended;
        private readonly string _cameraId;
        private readonly string _ttlSourceName;
        private readonly StringBuilder _line = new StringBuilder(256);

        public CsvFrameLog(string path, string cameraId, bool extended, TtlSource ttlSource)
        {
            if (string.IsNullOrEmpty(path))
            {
                throw new ArgumentException("CsvPath is empty.");
            }
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            _cameraId = (cameraId ?? "").Replace(",", "_").Replace("\"", "_");
            _extended = extended;
            _ttlSourceName = ttlSource.ToString().ToLowerInvariant();
            FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16);
            _writer = new StreamWriter(stream, new UTF8Encoding(false), 1 << 16);
            _writer.NewLine = "\n";
            _writer.WriteLine(extended ? RequiredHeader + ExtendedHeader : RequiredHeader);
        }

        public void Write(FrameItem item, long videoIndex)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;
            int dropped = (item.MissedBefore > 0 || item.Incomplete || item.WriterDropped) ? 1 : 0;
            _line.Length = 0;
            _line.Append(item.FrameNumber.ToString(inv)).Append(',')
                 .Append(_cameraId).Append(',')
                 .Append((item.TimestampNs / 1000).ToString(inv)).Append(',')
                 .Append(HostClock.FormatIso(item.HostTicks)).Append(',')
                 .Append(item.Ttl.ToString(inv)).Append(',')
                 .Append(dropped.ToString(inv));
            if (_extended)
            {
                _line.Append(',').Append(item.FrameId.ToString(inv))
                     .Append(',').Append(item.EmbeddedCounter.ToString(inv))
                     .Append(',').Append(item.MissedBefore.ToString(inv))
                     .Append(',').Append(HostClock.TicksToSeconds(item.HostTicks).ToString("F6", inv))
                     .Append(',').Append(item.Gpio.ToString(inv))
                     .Append(',').Append(item.Ttl < 0 ? "none" : _ttlSourceName)
                     .Append(',').Append(videoIndex.ToString(inv))
                     .Append(',').Append(item.WriterDropped ? '1' : '0')
                     .Append(',').Append(item.Incomplete ? '1' : '0');
            }
            _writer.WriteLine(_line.ToString());
        }

        public void Dispose()
        {
            _writer.Flush();
            _writer.Dispose();
        }
    }
}
