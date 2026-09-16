using System;

namespace SpinCam
{
    /// <summary>
    /// Baseline JPEG encoder for 8-bit monochrome frames, written for speed on one core so that
    /// several instances can encode one camera's frames in parallel (ParallelMjpegSink).
    /// </summary>
    /// <remarks>
    /// Output is a three-component YCbCr 4:2:0 JFIF image whose chroma is constant (128): the
    /// same layout SpinVideo/ffmpeg write for Mono8 MJPEG (yuvj420p), so every MJPEG AVI reader
    /// (Media Foundation, ffmpeg, OpenCV) decodes it. Constant chroma blocks cost two Huffman
    /// codes each. Quantization follows the IJG quality scale with the Annex K tables; the
    /// forward DCT is the AAN floating-point transform. Not thread-safe: one instance per thread.
    /// </remarks>
    internal sealed class JpegEncoder
    {
        private static readonly byte[] ZigZag = {
            0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
            12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
            35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
            58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };

        private static readonly byte[] StdLuminanceQuant = {
            16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
            14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
            18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
            49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99 };

        private static readonly byte[] StdChrominanceQuant = {
            17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
            24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
            99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99 };

        // Annex K.3 Huffman tables: code counts per length (1..16), then symbols.
        private static readonly byte[] DcLuminanceBits = { 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
        private static readonly byte[] DcLuminanceValues = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
        private static readonly byte[] DcChrominanceBits = { 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
        private static readonly byte[] DcChrominanceValues = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
        private static readonly byte[] AcLuminanceBits = { 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
        private static readonly byte[] AcLuminanceValues = {
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
            0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
            0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
            0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
            0xf9, 0xfa };
        private static readonly byte[] AcChrominanceBits = { 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
        private static readonly byte[] AcChrominanceValues = {
            0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
            0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
            0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
            0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
            0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
            0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
            0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
            0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
            0xf9, 0xfa };

        private static readonly double[] AanScale = {
            1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379 };

        /// <summary>Worst case bytes one MCU can take (6 blocks, byte stuffing included).</summary>
        private const int MaxMcuBytes = 2400;

        private static readonly byte[] BitLength = BuildBitLength();

        private readonly int _quality;
        private readonly byte[] _lumQuant = new byte[64];     // natural order
        private readonly byte[] _chromQuant = new byte[64];
        private readonly float[] _divisors = new float[64];   // natural order, AAN scaled
        private readonly uint[] _dcCode = new uint[12];
        private readonly byte[] _dcSize = new byte[12];
        private readonly uint[] _acCode = new uint[256];
        private readonly byte[] _acSize = new byte[256];
        private readonly float[] _block = new float[64];
        private readonly int[] _coefficients = new int[64];
        private readonly uint _chromaMcuBits;                 // Cb then Cr: DC diff 0 + EOB, twice
        private readonly int _chromaMcuLength;

        // Bit writer state
        private byte[] _out;
        private int _pos;
        private ulong _bitBuffer;
        private int _bitCount;

        public JpegEncoder(int quality)
        {
            _quality = Math.Max(1, Math.Min(100, quality));
            int scale = _quality < 50 ? 5000 / _quality : 200 - 2 * _quality;
            for (int i = 0; i < 64; i++)
            {
                _lumQuant[i] = ScaleQuant(StdLuminanceQuant[i], scale);
                _chromQuant[i] = ScaleQuant(StdChrominanceQuant[i], scale);
            }
            for (int row = 0; row < 8; row++)
            {
                for (int col = 0; col < 8; col++)
                {
                    int i = row * 8 + col;
                    _divisors[i] = (float)(1.0 / (_lumQuant[i] * AanScale[row] * AanScale[col] * 8.0));
                }
            }
            BuildHuffman(DcLuminanceBits, DcLuminanceValues, _dcCode, _dcSize);
            BuildHuffman(AcLuminanceBits, AcLuminanceValues, _acCode, _acSize);

            uint[] dcChromCode = new uint[12];
            byte[] dcChromSize = new byte[12];
            uint[] acChromCode = new uint[256];
            byte[] acChromSize = new byte[256];
            BuildHuffman(DcChrominanceBits, DcChrominanceValues, dcChromCode, dcChromSize);
            BuildHuffman(AcChrominanceBits, AcChrominanceValues, acChromCode, acChromSize);
            uint one = (dcChromCode[0] << acChromSize[0]) | acChromCode[0];
            int oneLength = dcChromSize[0] + acChromSize[0];
            _chromaMcuBits = (one << oneLength) | one;
            _chromaMcuLength = 2 * oneLength;
        }

        public int Quality
        {
            get { return _quality; }
        }

        /// <summary>
        /// Encodes a width-by-height 8-bit frame (row-major) into output, growing it if needed.
        /// Returns the number of bytes written.
        /// </summary>
        public unsafe int Encode(byte[] pixels, int width, int height, ref byte[] output)
        {
            if (pixels == null || width <= 0 || height <= 0 || pixels.Length < width * height)
            {
                throw new ArgumentException("Frame buffer does not match its size.");
            }
            if (width > 65535 || height > 65535)
            {
                throw new ArgumentException("JPEG frames are limited to 65535 pixels a side.");
            }
            int mcuColumns = (width + 15) / 16;
            int mcuRows = (height + 15) / 16;
            int rowReserve = mcuColumns * MaxMcuBytes;
            int headerLength = HeaderLength();
            if (output == null || output.Length < headerLength + rowReserve + 16)
            {
                output = new byte[Math.Max(headerLength + rowReserve + 16, width * height / 2)];
            }
            _out = output;
            _pos = 0;
            WriteHeader(width, height);
            _bitBuffer = 0;
            _bitCount = 0;

            int dcPrevious = 0;
            fixed (byte* src = pixels)
            fixed (float* block = _block)
            fixed (float* divisors = _divisors)
            fixed (int* coefficients = _coefficients)
            {
                for (int mcuRow = 0; mcuRow < mcuRows; mcuRow++)
                {
                    if (_out.Length - _pos < rowReserve + 16)
                    {
                        Array.Resize(ref _out, Math.Max(_out.Length * 2, _pos + rowReserve + 16));
                    }
                    int y0 = mcuRow * 16;
                    for (int mcuColumn = 0; mcuColumn < mcuColumns; mcuColumn++)
                    {
                        int x0 = mcuColumn * 16;
                        for (int b = 0; b < 4; b++)
                        {
                            int bx = x0 + ((b & 1) << 3);
                            int by = y0 + ((b >> 1) << 3);
                            LoadBlock(src, width, height, bx, by, block);
                            ForwardDct(block);
                            for (int i = 0; i < 64; i++)
                            {
                                float v = block[i] * divisors[i];
                                coefficients[i] = (int)(v + 16384.5f) - 16384;
                            }
                            dcPrevious = EncodeBlock(coefficients, dcPrevious);
                        }
                        PutBits(_chromaMcuBits, _chromaMcuLength);
                    }
                }
            }
            FlushBits();
            _out[_pos++] = 0xFF;
            _out[_pos++] = 0xD9;
            output = _out;
            _out = null;
            return _pos;
        }

        private static unsafe void LoadBlock(byte* src, int width, int height, int bx, int by, float* block)
        {
            if (bx + 8 <= width && by + 8 <= height)
            {
                for (int y = 0; y < 8; y++)
                {
                    byte* row = src + (by + y) * width + bx;
                    float* dst = block + y * 8;
                    dst[0] = row[0] - 128f; dst[1] = row[1] - 128f; dst[2] = row[2] - 128f; dst[3] = row[3] - 128f;
                    dst[4] = row[4] - 128f; dst[5] = row[5] - 128f; dst[6] = row[6] - 128f; dst[7] = row[7] - 128f;
                }
                return;
            }
            // Edge blocks replicate the last column and row.
            for (int y = 0; y < 8; y++)
            {
                int sy = Math.Min(by + y, height - 1);
                byte* row = src + sy * width;
                for (int x = 0; x < 8; x++)
                {
                    int sx = Math.Min(bx + x, width - 1);
                    block[y * 8 + x] = row[sx] - 128f;
                }
            }
        }

        /// <summary>AAN forward DCT (jfdctflt.c), in place; output needs AanScale-aware quantization.</summary>
        private static unsafe void ForwardDct(float* data)
        {
            float* p = data;
            for (int r = 0; r < 8; r++, p += 8)
            {
                float tmp0 = p[0] + p[7], tmp7 = p[0] - p[7];
                float tmp1 = p[1] + p[6], tmp6 = p[1] - p[6];
                float tmp2 = p[2] + p[5], tmp5 = p[2] - p[5];
                float tmp3 = p[3] + p[4], tmp4 = p[3] - p[4];
                float tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3;
                float tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
                p[0] = tmp10 + tmp11;
                p[4] = tmp10 - tmp11;
                float z1 = (tmp12 + tmp13) * 0.707106781f;
                p[2] = tmp13 + z1;
                p[6] = tmp13 - z1;
                tmp10 = tmp4 + tmp5;
                tmp11 = tmp5 + tmp6;
                tmp12 = tmp6 + tmp7;
                float z5 = (tmp10 - tmp12) * 0.382683433f;
                float z2 = 0.541196100f * tmp10 + z5;
                float z4 = 1.306562965f * tmp12 + z5;
                float z3 = tmp11 * 0.707106781f;
                float z11 = tmp7 + z3, z13 = tmp7 - z3;
                p[5] = z13 + z2;
                p[3] = z13 - z2;
                p[1] = z11 + z4;
                p[7] = z11 - z4;
            }
            for (int c = 0; c < 8; c++)
            {
                float* q = data + c;
                float tmp0 = q[0] + q[56], tmp7 = q[0] - q[56];
                float tmp1 = q[8] + q[48], tmp6 = q[8] - q[48];
                float tmp2 = q[16] + q[40], tmp5 = q[16] - q[40];
                float tmp3 = q[24] + q[32], tmp4 = q[24] - q[32];
                float tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3;
                float tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
                q[0] = tmp10 + tmp11;
                q[32] = tmp10 - tmp11;
                float z1 = (tmp12 + tmp13) * 0.707106781f;
                q[16] = tmp13 + z1;
                q[48] = tmp13 - z1;
                tmp10 = tmp4 + tmp5;
                tmp11 = tmp5 + tmp6;
                tmp12 = tmp6 + tmp7;
                float z5 = (tmp10 - tmp12) * 0.382683433f;
                float z2 = 0.541196100f * tmp10 + z5;
                float z4 = 1.306562965f * tmp12 + z5;
                float z3 = tmp11 * 0.707106781f;
                float z11 = tmp7 + z3, z13 = tmp7 - z3;
                q[40] = z13 + z2;
                q[24] = z13 - z2;
                q[8] = z11 + z4;
                q[56] = z11 - z4;
            }
        }

        private unsafe int EncodeBlock(int* coefficients, int dcPrevious)
        {
            int dc = coefficients[0];
            int diff = dc - dcPrevious;
            int magnitude = diff < 0 ? -diff : diff;
            int size = magnitude < 4096 ? BitLength[magnitude] : 12;
            if (size > 11)
            {
                size = 11;
                diff = diff < 0 ? -2047 : 2047;
            }
            PutBits(_dcCode[size], _dcSize[size]);
            if (size > 0)
            {
                PutBits((uint)(diff < 0 ? diff - 1 : diff) & ((1u << size) - 1), size);
            }

            int run = 0;
            for (int k = 1; k < 64; k++)
            {
                int v = coefficients[ZigZag[k]];
                if (v == 0)
                {
                    run++;
                    continue;
                }
                while (run > 15)
                {
                    PutBits(_acCode[0xF0], _acSize[0xF0]);
                    run -= 16;
                }
                int m = v < 0 ? -v : v;
                int bits = m < 4096 ? BitLength[m] : 12;
                if (bits > 10)
                {
                    bits = 10;
                    v = v < 0 ? -1023 : 1023;
                }
                int symbol = (run << 4) | bits;
                PutBits(_acCode[symbol], _acSize[symbol]);
                PutBits((uint)(v < 0 ? v - 1 : v) & ((1u << bits) - 1), bits);
                run = 0;
            }
            if (run > 0)
            {
                PutBits(_acCode[0x00], _acSize[0x00]);
            }
            return dc;
        }

        private void PutBits(uint code, int length)
        {
            _bitBuffer = (_bitBuffer << length) | code;
            _bitCount += length;
            while (_bitCount >= 8)
            {
                _bitCount -= 8;
                byte b = (byte)(_bitBuffer >> _bitCount);
                _out[_pos++] = b;
                if (b == 0xFF)
                {
                    _out[_pos++] = 0;
                }
            }
        }

        private void FlushBits()
        {
            if (_bitCount > 0)
            {
                int pad = 8 - _bitCount;
                PutBits((1u << pad) - 1, pad);
            }
            _bitBuffer = 0;
            _bitCount = 0;
        }

        private static int HeaderLength()
        {
            // SOI 2, APP0 18, DQT 2x69, SOF0 19, DHT 4 tables, SOS 14
            return 2 + 18 + 138 + 19 + (4 + 12 + 17) * 2 + (4 + 162 + 17) * 2 + 14;
        }

        private void WriteHeader(int width, int height)
        {
            byte[] o = _out;
            int p = 0;
            o[p++] = 0xFF; o[p++] = 0xD8;
            // APP0 JFIF 1.01, no density
            o[p++] = 0xFF; o[p++] = 0xE0; o[p++] = 0; o[p++] = 16;
            o[p++] = (byte)'J'; o[p++] = (byte)'F'; o[p++] = (byte)'I'; o[p++] = (byte)'F'; o[p++] = 0;
            o[p++] = 1; o[p++] = 1; o[p++] = 0; o[p++] = 0; o[p++] = 1; o[p++] = 0; o[p++] = 1; o[p++] = 0; o[p++] = 0;
            p = WriteQuant(o, p, 0, _lumQuant);
            p = WriteQuant(o, p, 1, _chromQuant);
            // SOF0: 8 bit, 3 components, Y 2x2 sampling, Cb/Cr 1x1
            o[p++] = 0xFF; o[p++] = 0xC0; o[p++] = 0; o[p++] = 17; o[p++] = 8;
            o[p++] = (byte)(height >> 8); o[p++] = (byte)height;
            o[p++] = (byte)(width >> 8); o[p++] = (byte)width;
            o[p++] = 3;
            o[p++] = 1; o[p++] = 0x22; o[p++] = 0;
            o[p++] = 2; o[p++] = 0x11; o[p++] = 1;
            o[p++] = 3; o[p++] = 0x11; o[p++] = 1;
            p = WriteHuffman(o, p, 0x00, DcLuminanceBits, DcLuminanceValues);
            p = WriteHuffman(o, p, 0x10, AcLuminanceBits, AcLuminanceValues);
            p = WriteHuffman(o, p, 0x01, DcChrominanceBits, DcChrominanceValues);
            p = WriteHuffman(o, p, 0x11, AcChrominanceBits, AcChrominanceValues);
            // SOS
            o[p++] = 0xFF; o[p++] = 0xDA; o[p++] = 0; o[p++] = 12; o[p++] = 3;
            o[p++] = 1; o[p++] = 0x00;
            o[p++] = 2; o[p++] = 0x11;
            o[p++] = 3; o[p++] = 0x11;
            o[p++] = 0; o[p++] = 63; o[p++] = 0;
            _pos = p;
        }

        private static int WriteQuant(byte[] o, int p, int id, byte[] table)
        {
            o[p++] = 0xFF; o[p++] = 0xDB; o[p++] = 0; o[p++] = 67; o[p++] = (byte)id;
            for (int k = 0; k < 64; k++)
            {
                o[p++] = table[ZigZag[k]];
            }
            return p;
        }

        private static int WriteHuffman(byte[] o, int p, int classAndId, byte[] bits, byte[] values)
        {
            int length = 2 + 1 + 16 + values.Length;
            o[p++] = 0xFF; o[p++] = 0xC4; o[p++] = (byte)(length >> 8); o[p++] = (byte)length;
            o[p++] = (byte)classAndId;
            Buffer.BlockCopy(bits, 0, o, p, 16);
            p += 16;
            Buffer.BlockCopy(values, 0, o, p, values.Length);
            return p + values.Length;
        }

        private static byte ScaleQuant(int standard, int scale)
        {
            int q = (standard * scale + 50) / 100;
            return (byte)Math.Max(1, Math.Min(255, q));
        }

        private static void BuildHuffman(byte[] bits, byte[] values, uint[] codes, byte[] sizes)
        {
            uint code = 0;
            int k = 0;
            for (int length = 1; length <= 16; length++)
            {
                for (int i = 0; i < bits[length - 1]; i++)
                {
                    codes[values[k]] = code;
                    sizes[values[k]] = (byte)length;
                    code++;
                    k++;
                }
                code <<= 1;
            }
        }

        private static byte[] BuildBitLength()
        {
            byte[] table = new byte[4096];
            for (int v = 1; v < table.Length; v++)
            {
                int n = 0;
                for (int x = v; x > 0; x >>= 1)
                {
                    n++;
                }
                table[v] = (byte)n;
            }
            return table;
        }
    }
}
