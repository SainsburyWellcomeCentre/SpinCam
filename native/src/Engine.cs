using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace SpinCam
{
    public static class Engine
    {
        public static string Version
        {
            get { return "1.2.0"; }
        }

        /// <summary>False when built with NO_SPINVIDEO (SpinVideoNET missing from the Spinnaker install).</summary>
        public static bool HasSpinVideo
        {
#if NO_SPINVIDEO
            get { return false; }
#else
            get { return true; }
#endif
        }

        /// <summary>JPEG encoder threads per camera that format AviMjpgParallel uses for a request (0 = automatic).</summary>
        public static int MjpegEncoderThreads(int requested)
        {
            return ParallelMjpegSink.ResolveThreads(requested);
        }

        /// <summary>One 8-bit frame (row-major) as a JPEG file's bytes, as format AviMjpgParallel encodes it.</summary>
        public static byte[] EncodeJpeg(byte[] pixels, int width, int height, int quality)
        {
            byte[] output = null;
            int length = new JpegEncoder(quality).Encode(pixels, width, height, ref output);
            byte[] jpeg = new byte[length];
            Buffer.BlockCopy(output, 0, jpeg, 0, length);
            return jpeg;
        }

        /// <summary>
        /// Encodes synthetic frames with a native video format and reports throughput (JSON).
        /// Only encoder time is measured; pattern rendering is excluded.
        /// </summary>
        public static string BenchmarkWriter(string videoPathNoExtension, VideoFormat format, int width, int height,
            int frames, double frameRate, int mjpgQuality)
        {
            if (format == VideoFormat.None || format == VideoFormat.MatlabExport)
            {
                throw new ArgumentException("BenchmarkWriter supports native formats only (Raw, parallel MJPEG or SpinVideo).");
            }
            RecordingOptions options = new RecordingOptions();
            options.VideoPath = videoPathNoExtension;
            options.Format = format;
            options.FrameRate = frameRate;
            options.MjpgQuality = mjpgQuality;
            SyntheticFrameSource pattern = new SyntheticFrameSource("bench", width, height, frameRate);
            BufferPool pool = new BufferPool();
            byte[] buffer = new byte[width * height];
            Stopwatch encode = new Stopwatch();
            IVideoSink sink;
            if (format == VideoFormat.Raw)
            {
                sink = new RawSink(options);
            }
            else if (format == VideoFormat.AviMjpgParallel)
            {
                sink = new ParallelMjpegSink(options, pool);
            }
            else
            {
                sink = VideoSinkFactory.CreateSpinVideo(options);
            }
            string[] files;
            try
            {
                for (int i = 0; i < frames; i++)
                {
                    if (sink.TakesOwnership)
                    {
                        buffer = pool.Rent(width * height);
                    }
                    pattern.Render(i, buffer);
                    encode.Start();
                    sink.Write(buffer, width, height);
                    encode.Stop();
                }
                encode.Start();
                sink.Close();
                encode.Stop();
                files = sink.Files;
            }
            finally
            {
                sink.Dispose();
            }
            long bytes = 0;
            foreach (string file in files)
            {
                bytes += new FileInfo(file).Length;
            }
            double seconds = encode.Elapsed.TotalSeconds;
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"format\":").Append(Json.Str(format.ToString()));
            sb.Append(",\"width\":").Append(Json.Num(width));
            sb.Append(",\"height\":").Append(Json.Num(height));
            sb.Append(",\"frames\":").Append(Json.Num(frames));
            sb.Append(",\"seconds\":").Append(Json.Num(seconds));
            sb.Append(",\"fps\":").Append(Json.Num(seconds > 0 ? frames / seconds : 0));
            sb.Append(",\"bytes\":").Append(Json.Num(bytes));
            sb.Append(",\"files\":").Append(Json.StrArray(files));
            sb.Append('}');
            return sb.ToString();
        }
    }
}
