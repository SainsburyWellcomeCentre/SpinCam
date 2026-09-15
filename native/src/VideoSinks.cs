using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
#if !NO_SPINVIDEO
using SpinnakerNET;
using SpinnakerNET.Video;
#endif

namespace SpinCam
{
    internal interface IVideoSink : IDisposable
    {
        /// <summary>True when an accepted buffer must not be returned to the pool.</summary>
        bool TakesOwnership { get; }

        /// <summary>Writes an 8-bit frame; returns its 0-based index in the video, or -1 if rejected.</summary>
        long Write(byte[] buffer, int width, int height);

        void Close();

        string[] Files { get; }
    }

    internal static class VideoSinkFactory
    {
        /// <summary>SpinVideo writer; NotSupportedException when the engine was built without SpinVideoNET.</summary>
        public static IVideoSink CreateSpinVideo(RecordingOptions options)
        {
#if NO_SPINVIDEO
            throw new NotSupportedException("This engine was built without SpinVideoNET (not found in the " +
                "Spinnaker installation); record with Raw, MATLAB export or None.");
#else
            return new SpinVideoSink(options);
#endif
        }
    }

#if !NO_SPINVIDEO
    /// <summary>Native encoder (SpinVideo / ffmpeg): MJPEG AVI, uncompressed AVI, H.264 MP4.</summary>
    internal sealed class SpinVideoSink : IVideoSink
    {
        // SpinVideo wraps ffmpeg 3.x (avcodec-57), whose codec open/close is not thread-safe
        // without a lock manager. Two cameras starting together hung a writer and later crashed
        // MATLAB inside SpinVideo::Open, so all sinks serialize Open/Close (Append stays parallel).
        private static readonly object CodecLock = new object();

        private readonly RecordingOptions _options;
        private IManagedSpinVideo _video;
        private long _count;
        private string[] _files = new string[0];

        public SpinVideoSink(RecordingOptions options)
        {
            _options = options;
            if (string.IsNullOrEmpty(options.VideoPath))
            {
                throw new ArgumentException("VideoPath is empty.");
            }
            string dir = Path.GetDirectoryName(options.VideoPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
        }

        public bool TakesOwnership
        {
            get { return false; }
        }

        public string[] Files
        {
            get { return _files; }
        }

        public unsafe long Write(byte[] buffer, int width, int height)
        {
            if (_video == null)
            {
                lock (CodecLock)
                {
                    Open(width, height);
                }
            }
            fixed (byte* pixels = buffer)
            {
                using (ManagedImage image = new ManagedImage((uint)width, (uint)height, 0, 0, PixelFormatEnums.Mono8, (void*)pixels))
                {
                    _video.Append(image);
                }
            }
            return _count++;
        }

        public void Close()
        {
            if (_video == null)
            {
                return;
            }
            try
            {
                lock (CodecLock)
                {
                    try
                    {
                        _video.Close();
                    }
                    finally
                    {
                        _video.Dispose();
                    }
                }
            }
            finally
            {
                _video = null;
                _files = FindFiles();
            }
        }

        public void Dispose()
        {
            Close();
        }

        private void Open(int width, int height)
        {
            IManagedSpinVideo video = new ManagedSpinVideo();
            try
            {
                // Option member types (int/uint/float) and some members differ between Spinnaker
                // releases, so they are set by name; the engine then compiles against any SpinVideo.
                MethodInfo setMaximumFileSize = video.GetType().GetMethod("SetMaximumFileSize");
                if (setMaximumFileSize != null && setMaximumFileSize.GetParameters().Length == 1)
                {
                    Type parameter = setMaximumFileSize.GetParameters()[0].ParameterType;
                    setMaximumFileSize.Invoke(video, new object[] {
                        Convert.ChangeType(Math.Max(0, _options.MaxFileSizeMB), parameter, CultureInfo.InvariantCulture) });
                }
                switch (_options.Format)
                {
                    case VideoFormat.AviUncompressed:
                    {
                        object option = new AviOption();
                        SetOption(option, "frameRate", _options.FrameRate, true);
                        SetOption(option, "width", width, false);
                        SetOption(option, "height", height, false);
                        video.Open(_options.VideoPath, (AviOption)option);
                        break;
                    }
                    case VideoFormat.AviMjpg:
                    {
                        object option = new MJPGOption();
                        SetOption(option, "frameRate", _options.FrameRate, true);
                        SetOption(option, "quality", Math.Max(1, Math.Min(100, _options.MjpgQuality)), true);
                        SetOption(option, "width", width, false);
                        SetOption(option, "height", height, false);
                        video.Open(_options.VideoPath, (MJPGOption)option);
                        break;
                    }
                    case VideoFormat.Mp4H264:
                    {
                        object option = new H264Option();
                        SetOption(option, "frameRate", _options.FrameRate, true);
                        SetOption(option, "bitrate", Math.Max(1, _options.H264BitrateBps), true);
                        SetOption(option, "crf", Math.Max(0, _options.H264Crf), false);
                        SetOption(option, "width", width, false);
                        SetOption(option, "height", height, false);
                        SetOption(option, "useMP4", true, false);
                        video.Open(_options.VideoPath, (H264Option)option);
                        break;
                    }
                    default:
                        throw new InvalidOperationException("SpinVideoSink cannot write format " + _options.Format);
                }
            }
            catch
            {
                video.Dispose();
                throw;
            }
            _video = video;
        }

        /// <summary>Sets a field or property by name, converting to its type (boxed structs are updated in place).</summary>
        private static void SetOption(object option, string name, object value, bool required)
        {
            Type type = option.GetType();
            FieldInfo field = type.GetField(name);
            if (field != null)
            {
                field.SetValue(option, Convert.ChangeType(value, field.FieldType, CultureInfo.InvariantCulture));
                return;
            }
            PropertyInfo property = type.GetProperty(name);
            if (property != null && property.CanWrite)
            {
                property.SetValue(option, Convert.ChangeType(value, property.PropertyType, CultureInfo.InvariantCulture), null);
                return;
            }
            if (required)
            {
                throw new NotSupportedException("This Spinnaker version's " + type.Name + " has no '" + name + "' setting.");
            }
        }

        private string[] FindFiles()
        {
            List<string> files = new List<string>();
            string dir = Path.GetDirectoryName(_options.VideoPath);
            string stem = Path.GetFileName(_options.VideoPath);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
            {
                return files.ToArray();
            }
            foreach (string file in Directory.GetFiles(dir, stem + "*"))
            {
                string ext = Path.GetExtension(file).ToLowerInvariant();
                string name = Path.GetFileNameWithoutExtension(file);
                bool sameStem = name == stem || name.StartsWith(stem + "-", StringComparison.Ordinal);
                if (sameStem && (ext == ".avi" || ext == ".mp4"))
                {
                    files.Add(file);
                }
            }
            files.Sort(StringComparer.Ordinal);
            return files.ToArray();
        }
    }

#endif

    /// <summary>
    /// Lossless writer: 8-bit frames appended row-major to VideoPath.raw with geometry in
    /// VideoPath.raw.json (spincam.io.RawVideoReader). No encoding, so it runs at disk speed.
    /// </summary>
    internal sealed class RawSink : IVideoSink
    {
        private readonly RecordingOptions _options;
        private readonly string _rawPath;
        private FileStream _stream;
        private long _count;
        private int _width;
        private int _height;
        private bool _opened;

        public RawSink(RecordingOptions options)
        {
            if (string.IsNullOrEmpty(options.VideoPath))
            {
                throw new ArgumentException("VideoPath is empty.");
            }
            _options = options;
            _rawPath = options.VideoPath + ".raw";
            string dir = Path.GetDirectoryName(_rawPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
        }

        public bool TakesOwnership
        {
            get { return false; }
        }

        public string[] Files
        {
            get { return _opened ? new string[] { _rawPath } : new string[0]; }
        }

        public long Write(byte[] buffer, int width, int height)
        {
            if (_stream == null)
            {
                _width = width;
                _height = height;
                _stream = new FileStream(_rawPath, FileMode.Create, FileAccess.Write, FileShare.Read,
                    1 << 22, FileOptions.SequentialScan);
                _opened = true;
                WriteSidecar();
            }
            if (width != _width || height != _height)
            {
                throw new InvalidOperationException("Frame size changed during a raw recording.");
            }
            _stream.Write(buffer, 0, width * height);
            return _count++;
        }

        public void Close()
        {
            if (_stream == null)
            {
                return;
            }
            try
            {
                _stream.Flush();
            }
            finally
            {
                _stream.Dispose();
                _stream = null;
                WriteSidecar();
            }
        }

        public void Dispose()
        {
            Close();
        }

        private void WriteSidecar()
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"format\":\"spincam-raw-v1\"");
            sb.Append(",\"cameraId\":").Append(Json.Str(_options.CameraId));
            sb.Append(",\"width\":").Append(Json.Num(_width));
            sb.Append(",\"height\":").Append(Json.Num(_height));
            sb.Append(",\"pixelFormat\":\"Mono8\"");
            sb.Append(",\"frameRate\":").Append(Json.Num(_options.FrameRate));
            sb.Append(",\"frames\":").Append(Json.Num(_count));
            sb.Append(",\"layout\":\"frame i (0-based) starts at byte i*width*height; rows top to bottom\"}");
            File.WriteAllText(_rawPath + ".json", sb.ToString());
        }
    }

    public sealed class ExportFrame
    {
        public byte[] Data;
        public int Width;
        public int Height;
        public long VideoIndex;
    }

    /// <summary>Hands frames to MATLAB (VideoWriter). Bounded; overflow is reported as a writer drop.</summary>
    internal sealed class ExportSink : IVideoSink
    {
        private readonly Queue<ExportFrame> _queue = new Queue<ExportFrame>();
        private readonly int _capacity;
        private long _next;

        public ExportSink(int capacity)
        {
            _capacity = Math.Max(1, capacity);
        }

        public bool TakesOwnership
        {
            get { return true; }
        }

        public string[] Files
        {
            get { return new string[0]; }
        }

        public int Count
        {
            get { lock (_queue) { return _queue.Count; } }
        }

        public long Write(byte[] buffer, int width, int height)
        {
            lock (_queue)
            {
                if (_queue.Count >= _capacity)
                {
                    return -1;
                }
                ExportFrame frame = new ExportFrame();
                frame.Data = buffer;
                frame.Width = width;
                frame.Height = height;
                frame.VideoIndex = _next++;
                _queue.Enqueue(frame);
                return frame.VideoIndex;
            }
        }

        public bool TryDequeue(out ExportFrame frame)
        {
            lock (_queue)
            {
                if (_queue.Count == 0)
                {
                    frame = null;
                    return false;
                }
                frame = _queue.Dequeue();
                return true;
            }
        }

        public void Close()
        {
        }

        public void Dispose()
        {
        }
    }
}
