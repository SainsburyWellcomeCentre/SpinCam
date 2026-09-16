using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SpinCam
{
    /// <summary>
    /// Writes one MJPEG video stream as an OpenDML (AVI 2.0) file, so a recording can pass the
    /// 1 GB RIFF limit: the first RIFF 'AVI ' carries the headers, a legacy idx1 index for old
    /// readers and a standard index; every further RIFF 'AVIX' carries frames and its own
    /// standard index (ix00), all listed in the stream's super index (indx). Frames are written
    /// as they come; sizes, counts and indexes are patched in Close. Not thread-safe.
    /// </summary>
    internal sealed class AviWriter : IDisposable
    {
        private const uint AvifHasIndex = 0x10;
        private const uint AviifKeyframe = 0x10;
        private const int SuperIndexEntries = 1024;
        private const int DmlhSize = 248;

        private readonly FileStream _file;
        private readonly BinaryWriter _w;
        private readonly int _width;
        private readonly int _height;
        private readonly uint _rate;
        private readonly uint _scale;
        private readonly long _riffLimit;

        private long _avihPos;
        private long _strhPos;
        private long _indxPos;
        private long _dmlhPos;

        private long _riffPos;       // position of the current 'RIFF' fourcc
        private long _moviPos;       // position of the current 'LIST' fourcc of movi
        private bool _firstRiff = true;
        private readonly List<long> _chunkOffsets = new List<long>();   // data offsets in this RIFF
        private readonly List<int> _chunkSizes = new List<int>();
        private readonly List<uint> _idx1 = new List<uint>();           // first RIFF: offset, size pairs
        private readonly List<long> _superOffsets = new List<long>();
        private readonly List<int> _superSizes = new List<int>();
        private readonly List<int> _superDurations = new List<int>();
        private long _frames;
        private long _firstRiffFrames;
        private int _maxChunk;
        private bool _closed;

        /// <param name="path">File to create (overwritten).</param>
        /// <param name="riffLimitBytes">Size at which a new RIFF starts; 1 GB for real files.</param>
        public AviWriter(string path, int width, int height, double frameRate, long riffLimitBytes)
        {
            if (width <= 0 || height <= 0)
            {
                throw new ArgumentException("AVI frame size must be positive.");
            }
            _width = width;
            _height = height;
            double fps = frameRate > 0 && !double.IsInfinity(frameRate) ? frameRate : 30.0;
            _scale = 1000;
            _rate = (uint)Math.Max(1, Math.Round(fps * _scale));
            _riffLimit = Math.Max(1L << 20, riffLimitBytes);
            _file = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 1 << 22,
                FileOptions.SequentialScan);
            _w = new BinaryWriter(_file, Encoding.ASCII);
            WriteHeaders();
        }

        public long Frames
        {
            get { return _frames; }
        }

        /// <summary>Appends one JPEG frame (bytes 0..length-1 of data).</summary>
        public void WriteFrame(byte[] data, int length)
        {
            if (_closed)
            {
                throw new ObjectDisposedException("AviWriter");
            }
            long chunkTotal = 8 + length + (length & 1);
            long pending = _file.Position + chunkTotal + 32 + 8L * (_chunkOffsets.Count + 1) +
                (_firstRiff ? 16L * (_idx1.Count / 2 + 1) + 8 : 0);
            if (_chunkOffsets.Count > 0 && pending - _riffPos > _riffLimit)
            {
                EndRiff();
                BeginAvix();
            }
            long chunkPos = _file.Position;
            WriteFourCC("00dc");
            _w.Write((uint)length);
            _w.Write(data, 0, length);
            if ((length & 1) != 0)
            {
                _w.Write((byte)0);
            }
            _chunkOffsets.Add(chunkPos + 8);
            _chunkSizes.Add(length);
            if (_firstRiff)
            {
                _idx1.Add((uint)(chunkPos - (_moviPos + 8)));
                _idx1.Add((uint)length);
            }
            if (length > _maxChunk)
            {
                _maxChunk = length;
            }
            _frames++;
        }

        public void Close()
        {
            if (_closed)
            {
                return;
            }
            _closed = true;
            try
            {
                EndRiff();
                PatchHeaders();
                _w.Flush();
            }
            finally
            {
                _w.Dispose();
            }
        }

        public void Dispose()
        {
            Close();
        }

        private void WriteHeaders()
        {
            _riffPos = 0;
            WriteFourCC("RIFF");
            _w.Write((uint)0);
            WriteFourCC("AVI ");

            long hdrl = BeginList("hdrl");
            WriteFourCC("avih");
            _w.Write((uint)56);
            _avihPos = _file.Position;
            _w.Write((uint)Math.Round(1e6 * _scale / _rate));   // dwMicroSecPerFrame
            _w.Write((uint)0);                                   // dwMaxBytesPerSec (patched)
            _w.Write((uint)0);                                   // dwPaddingGranularity
            _w.Write(AvifHasIndex);                              // dwFlags
            _w.Write((uint)0);                                   // dwTotalFrames (first RIFF, patched)
            _w.Write((uint)0);                                   // dwInitialFrames
            _w.Write((uint)1);                                   // dwStreams
            _w.Write((uint)0);                                   // dwSuggestedBufferSize (patched)
            _w.Write((uint)_width);
            _w.Write((uint)_height);
            for (int i = 0; i < 4; i++)
            {
                _w.Write((uint)0);
            }

            long strl = BeginList("strl");
            WriteFourCC("strh");
            _w.Write((uint)56);
            _strhPos = _file.Position;
            WriteFourCC("vids");
            WriteFourCC("MJPG");
            _w.Write((uint)0);                                   // dwFlags
            _w.Write((ushort)0);                                 // wPriority
            _w.Write((ushort)0);                                 // wLanguage
            _w.Write((uint)0);                                   // dwInitialFrames
            _w.Write(_scale);
            _w.Write(_rate);
            _w.Write((uint)0);                                   // dwStart
            _w.Write((uint)0);                                   // dwLength (patched)
            _w.Write((uint)0);                                   // dwSuggestedBufferSize (patched)
            _w.Write(uint.MaxValue);                             // dwQuality
            _w.Write((uint)0);                                   // dwSampleSize
            _w.Write((short)0);
            _w.Write((short)0);
            _w.Write((short)_width);
            _w.Write((short)_height);

            WriteFourCC("strf");
            _w.Write((uint)40);
            _w.Write((uint)40);
            _w.Write(_width);
            _w.Write(_height);
            _w.Write((ushort)1);
            _w.Write((ushort)24);
            WriteFourCC("MJPG");
            _w.Write((uint)(_width * 3 * _height));
            _w.Write(0);
            _w.Write(0);
            _w.Write((uint)0);
            _w.Write((uint)0);

            WriteFourCC("indx");
            _w.Write((uint)(24 + 16 * SuperIndexEntries));
            _indxPos = _file.Position;
            _w.Write(new byte[24 + 16 * SuperIndexEntries]);
            EndList(strl);
            EndList(hdrl);

            long odml = BeginList("odml");
            WriteFourCC("dmlh");
            _w.Write((uint)DmlhSize);
            _dmlhPos = _file.Position;
            _w.Write(new byte[DmlhSize]);
            EndList(odml);

            _moviPos = _file.Position;
            WriteFourCC("LIST");
            _w.Write((uint)0);
            WriteFourCC("movi");
        }

        private void BeginAvix()
        {
            _firstRiff = false;
            _riffPos = _file.Position;
            WriteFourCC("RIFF");
            _w.Write((uint)0);
            WriteFourCC("AVIX");
            _moviPos = _file.Position;
            WriteFourCC("LIST");
            _w.Write((uint)0);
            WriteFourCC("movi");
        }

        /// <summary>Writes this RIFF's ix00 inside movi (and idx1 in the first), then patches sizes.</summary>
        private void EndRiff()
        {
            if (_chunkOffsets.Count > 0)
            {
                if (_superOffsets.Count >= SuperIndexEntries)
                {
                    throw new InvalidOperationException("AVI super index is full.");
                }
                long ixPos = _file.Position;
                long baseOffset = _riffPos;
                int ixSize = 24 + 8 * _chunkOffsets.Count;
                WriteFourCC("ix00");
                _w.Write((uint)ixSize);
                _w.Write((ushort)2);                             // wLongsPerEntry
                _w.Write((byte)0);                               // bIndexSubType
                _w.Write((byte)1);                               // bIndexType: AVI_INDEX_OF_CHUNKS
                _w.Write((uint)_chunkOffsets.Count);
                WriteFourCC("00dc");
                _w.Write((ulong)baseOffset);
                _w.Write((uint)0);
                for (int i = 0; i < _chunkOffsets.Count; i++)
                {
                    _w.Write((uint)(_chunkOffsets[i] - baseOffset));
                    _w.Write((uint)_chunkSizes[i]);                // bit 31 clear: key frame
                }
                _superOffsets.Add(ixPos);
                _superSizes.Add(8 + ixSize);
                _superDurations.Add(_chunkOffsets.Count);
            }
            PatchSize(_moviPos);

            if (_firstRiff)
            {
                _firstRiffFrames = _chunkOffsets.Count;
                WriteFourCC("idx1");
                _w.Write((uint)(16 * (_idx1.Count / 2)));
                for (int i = 0; i < _idx1.Count; i += 2)
                {
                    WriteFourCC("00dc");
                    _w.Write(AviifKeyframe);
                    _w.Write(_idx1[i]);
                    _w.Write(_idx1[i + 1]);
                }
                _idx1.Clear();
            }
            PatchSize(_riffPos);
            _chunkOffsets.Clear();
            _chunkSizes.Clear();
        }

        private void PatchHeaders()
        {
            long end = _file.Position;
            uint suggested = (uint)(_maxChunk + 8 + (_maxChunk & 1));
            uint maxBytesPerSec = (uint)Math.Min(uint.MaxValue, Math.Ceiling((double)suggested * _rate / _scale));

            _file.Position = _avihPos + 4;
            _w.Write(maxBytesPerSec);
            _file.Position = _avihPos + 16;
            _w.Write((uint)Math.Min(uint.MaxValue, _firstRiffFrames));
            _file.Position = _avihPos + 28;
            _w.Write(suggested);

            _file.Position = _strhPos + 32;
            _w.Write((uint)Math.Min(uint.MaxValue, _frames));
            _w.Write(suggested);

            _file.Position = _dmlhPos;
            _w.Write((uint)Math.Min(uint.MaxValue, _frames));

            _file.Position = _indxPos;
            _w.Write((ushort)4);                                 // wLongsPerEntry
            _w.Write((byte)0);                                   // bIndexSubType
            _w.Write((byte)0);                                   // bIndexType: AVI_INDEX_OF_INDEXES
            _w.Write((uint)_superOffsets.Count);
            WriteFourCC("00dc");
            _w.Write((uint)0);
            _w.Write((uint)0);
            _w.Write((uint)0);
            for (int i = 0; i < _superOffsets.Count; i++)
            {
                _w.Write((ulong)_superOffsets[i]);
                _w.Write((uint)_superSizes[i]);
                _w.Write((uint)_superDurations[i]);
            }
            _w.Flush();
            _file.Position = end;
        }

        private long BeginList(string type)
        {
            long pos = _file.Position;
            WriteFourCC("LIST");
            _w.Write((uint)0);
            WriteFourCC(type);
            return pos;
        }

        private void EndList(long pos)
        {
            PatchSize(pos);
        }

        /// <summary>Sets the size field of the chunk or list whose fourcc is at pos to reach the current end.</summary>
        private void PatchSize(long pos)
        {
            _w.Flush();
            long end = _file.Position;
            _file.Position = pos + 4;
            _w.Write((uint)(end - pos - 8));
            _w.Flush();
            _file.Position = end;
        }

        private void WriteFourCC(string code)
        {
            _w.Write((byte)code[0]);
            _w.Write((byte)code[1]);
            _w.Write((byte)code[2]);
            _w.Write((byte)code[3]);
        }
    }
}
