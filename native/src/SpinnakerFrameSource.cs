using System;
using System.Runtime.InteropServices;
using SpinnakerNET;
using SpinnakerNET.GenApi;

namespace SpinCam
{
    /// <summary>
    /// Frame source backed by a Spinnaker camera. MATLAB owns the camera lifecycle
    /// (Init/DeInit); this class only begins/ends acquisition and grabs.
    /// </summary>
    public sealed class SpinnakerFrameSource : IFrameSource
    {
        private const int SpinnakerErrorTimeout = -1011;
        private readonly IManagedCamera _camera;
        private readonly string _id;
        private readonly object _sync = new object();
        private IInteger _lineStatusAll;
        private bool _acquiring;

        public SpinnakerFrameSource(IManagedCamera camera, string id)
        {
            if (camera == null)
            {
                throw new ArgumentNullException("camera");
            }
            _camera = camera;
            _id = id ?? "";
        }

        public string Id
        {
            get { return _id; }
        }

        public bool IsAcquiring
        {
            get { lock (_sync) { return _acquiring; } }
        }

        public void BeginAcquisition()
        {
            lock (_sync)
            {
                if (_acquiring)
                {
                    return;
                }
                _camera.BeginAcquisition();
                _acquiring = true;
            }
        }

        public void EndAcquisition()
        {
            lock (_sync)
            {
                if (!_acquiring)
                {
                    return;
                }
                _acquiring = false;
                _camera.EndAcquisition();
            }
        }

        public bool Grab(int timeoutMs, RawFrame frame)
        {
            IManagedImage image;
            try
            {
                image = _camera.GetNextImage((ulong)Math.Max(1, timeoutMs));
            }
            catch (SpinnakerException ex)
            {
                if ((int)ex.ErrorCode == SpinnakerErrorTimeout)
                {
                    return false;
                }
                throw;
            }
            long hostTicks = HostClock.NowTicks();
            using (image)
            {
                frame.HostTicks = hostTicks;
                frame.FrameId = (long)image.FrameID;
                frame.TimestampNs = (long)image.TimeStamp;
                frame.Incomplete = image.IsIncomplete;
                int width = (int)image.Width;
                int height = (int)image.Height;
                frame.Width = width;
                frame.Height = height;
                if (frame.Incomplete)
                {
                    return true;
                }
                if (image.BitsPerPixel != 8)
                {
                    throw new InvalidOperationException("Camera " + _id + " streams " +
                        image.PixelFormatName + "; spincam requires an 8-bit format (Mono8).");
                }
                int stride = (int)image.Stride;
                int size = width * height;
                if (frame.Buffer == null || frame.Buffer.Length != size)
                {
                    frame.Buffer = new byte[size];
                }
                IntPtr data = image.DataPtr;
                if (stride == width)
                {
                    Marshal.Copy(data, frame.Buffer, 0, size);
                }
                else
                {
                    for (int row = 0; row < height; row++)
                    {
                        Marshal.Copy(new IntPtr(data.ToInt64() + (long)row * stride), frame.Buffer, row * width, width);
                    }
                }
            }
            return true;
        }

        public long ReadLineStatusAll()
        {
            IInteger node = _lineStatusAll;
            if (node == null)
            {
                node = _camera.GetNodeMap().GetNode<IInteger>("LineStatusAll");
                if (node == null)
                {
                    throw new InvalidOperationException("Camera " + _id + " has no LineStatusAll node.");
                }
                _lineStatusAll = node;
            }
            return node.Value;
        }

        public void Dispose()
        {
            try
            {
                EndAcquisition();
            }
            catch (SpinnakerException)
            {
            }
        }
    }
}
