// QR codes for the links, so a phone can open one by pointing its camera at the screen. Windows has nothing built
// in for making them, so this is the standard method in brief: text as bytes, medium error correction (15% of the
// code can be covered or misread), versions 1 to 40, the mask with the fewest problem patterns.
// Follows the layout in ISO/IEC 18004 as described by Project Nayuki's reference generator.
using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class QrCode
{
    // Per version (1-40), for medium error correction
    static readonly int[] EccPerBlock = { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 };
    static readonly int[] Blocks = { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 };
    const int MediumFormatBits = 0;

    // true = dark, [y, x]
    public static bool[,] Encode(string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        int version = 1;
        for (; version <= 40; version++)
        {
            int capacity = DataCodewords(version) * 8;
            if (4 + (version < 10 ? 8 : 16) + bytes.Length * 8 <= capacity) break;
        }
        if (version > 40) throw new ArgumentException("Too long for a QR code");

        // Byte mode, length, the bytes, then end marker and padding
        var bits = new List<bool>();
        Append(bits, 4, 4);
        Append(bits, bytes.Length, version < 10 ? 8 : 16);
        foreach (byte b in bytes) Append(bits, b, 8);
        int capacityBits = DataCodewords(version) * 8;
        Append(bits, 0, Math.Min(4, capacityBits - bits.Count));
        Append(bits, 0, (8 - bits.Count % 8) % 8);
        for (int pad = 0xEC; bits.Count < capacityBits; pad ^= 0xEC ^ 0x11) Append(bits, pad, 8);
        var data = new byte[bits.Count / 8];
        for (int i = 0; i < bits.Count; i++) if (bits[i]) data[i >> 3] |= (byte)(0x80 >> (i & 7));

        var qr = new Matrix(version);
        qr.DrawFunctionPatterns();
        qr.DrawCodewords(AddEccAndInterleave(data, version));

        // Try every mask and keep the one with the lowest penalty
        int best = 0;
        long bestPenalty = long.MaxValue;
        for (int mask = 0; mask < 8; mask++)
        {
            qr.ApplyMask(mask);
            qr.DrawFormatBits(mask);
            long penalty = qr.Penalty();
            if (penalty < bestPenalty) { best = mask; bestPenalty = penalty; }
            qr.ApplyMask(mask);   // undoes it
        }
        qr.ApplyMask(best);
        qr.DrawFormatBits(best);
        return qr.Modules;
    }

    // Black on white with the 4-module quiet zone scanners need around it
    public static BitmapSource ToBitmap(bool[,] modules, int scale)
    {
        int n = modules.GetLength(0), border = 4, size = (n + border * 2) * scale;
        var pixels = new byte[size * size];
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
            {
                int mx = x / scale - border, my = y / scale - border;
                bool dark = mx >= 0 && my >= 0 && mx < n && my < n && modules[my, mx];
                pixels[y * size + x] = dark ? (byte)0 : (byte)255;
            }
        var bitmap = BitmapSource.Create(size, size, 96, 96, PixelFormats.Gray8, null, pixels, size);
        bitmap.Freeze();
        return bitmap;
    }

    static void Append(List<bool> bits, int value, int count)
    {
        for (int i = count - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0);
    }

    static int RawDataModules(int version)
    {
        int result = (16 * version + 128) * version + 64;
        if (version >= 2)
        {
            int align = version / 7 + 2;
            result -= (25 * align - 10) * align - 55;
            if (version >= 7) result -= 36;
        }
        return result;
    }

    static int DataCodewords(int version)
    {
        return RawDataModules(version) / 8 - EccPerBlock[version] * Blocks[version];
    }

    static byte[] AddEccAndInterleave(byte[] data, int version)
    {
        int numBlocks = Blocks[version], eccLen = EccPerBlock[version];
        int raw = RawDataModules(version) / 8;
        int numShort = numBlocks - raw % numBlocks;
        int shortLen = raw / numBlocks;
        byte[] divisor = RsDivisor(eccLen);
        var blocks = new byte[numBlocks][];
        for (int i = 0, k = 0; i < numBlocks; i++)
        {
            int datLen = shortLen - eccLen + (i < numShort ? 0 : 1);
            var dat = new byte[datLen];
            Array.Copy(data, k, dat, 0, datLen);
            k += datLen;
            var block = new byte[shortLen + 1];
            Array.Copy(dat, block, datLen);
            byte[] ecc = RsRemainder(dat, divisor);
            Array.Copy(ecc, 0, block, block.Length - eccLen, eccLen);
            blocks[i] = block;
        }
        var result = new byte[raw];
        for (int i = 0, k = 0; i < blocks[0].Length; i++)
            for (int j = 0; j < numBlocks; j++)
                if (i != shortLen - eccLen || j >= numShort) result[k++] = blocks[j][i];
        return result;
    }

    static byte[] RsDivisor(int degree)
    {
        var result = new byte[degree];
        result[degree - 1] = 1;
        int root = 1;
        for (int i = 0; i < degree; i++)
        {
            for (int j = 0; j < degree; j++)
            {
                result[j] = (byte)Multiply(result[j], root);
                if (j + 1 < degree) result[j] ^= result[j + 1];
            }
            root = Multiply(root, 2);
        }
        return result;
    }

    static byte[] RsRemainder(byte[] data, byte[] divisor)
    {
        var result = new byte[divisor.Length];
        foreach (byte b in data)
        {
            int factor = b ^ result[0];
            Array.Copy(result, 1, result, 0, result.Length - 1);
            result[result.Length - 1] = 0;
            for (int i = 0; i < result.Length; i++) result[i] ^= (byte)Multiply(divisor[i], factor);
        }
        return result;
    }

    static int Multiply(int x, int y)
    {
        int z = 0;
        for (int i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return z & 0xFF;
    }

    class Matrix
    {
        public readonly bool[,] Modules;
        readonly bool[,] isFunction;
        readonly int size, version;

        public Matrix(int version)
        {
            this.version = version;
            size = version * 4 + 17;
            Modules = new bool[size, size];
            isFunction = new bool[size, size];
        }

        void Set(int x, int y, bool dark) { Modules[y, x] = dark; isFunction[y, x] = true; }

        public void DrawFunctionPatterns()
        {
            for (int i = 0; i < size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
            Finder(3, 3); Finder(size - 4, 3); Finder(3, size - 4);
            int[] align = AlignmentPositions();
            int last = align.Length - 1;
            for (int i = 0; i < align.Length; i++)
                for (int j = 0; j < align.Length; j++)
                    if (!(i == 0 && j == 0 || i == 0 && j == last || i == last && j == 0)) Alignment(align[i], align[j]);
            DrawFormatBits(0);   // reserves the area; drawn for real once the mask is chosen
            if (version >= 7)
            {
                int rem = version;
                for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
                int bits = version << 12 | rem;
                for (int i = 0; i < 18; i++)
                {
                    bool bit = ((bits >> i) & 1) != 0;
                    int a = size - 11 + i % 3, b = i / 3;
                    Set(a, b, bit);
                    Set(b, a, bit);
                }
            }
        }

        void Finder(int x, int y)
        {
            for (int dy = -4; dy <= 4; dy++)
                for (int dx = -4; dx <= 4; dx++)
                {
                    int dist = Math.Max(Math.Abs(dx), Math.Abs(dy)), xx = x + dx, yy = y + dy;
                    if (xx >= 0 && xx < size && yy >= 0 && yy < size) Set(xx, yy, dist != 2 && dist != 4);
                }
        }

        void Alignment(int x, int y)
        {
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++)
                    Set(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
        }

        int[] AlignmentPositions()
        {
            if (version == 1) return new int[0];
            int count = version / 7 + 2;
            int step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
            var result = new int[count];
            result[0] = 6;
            for (int i = count - 1, pos = size - 7; i >= 1; i--, pos -= step) result[i] = pos;
            return result;
        }

        public void DrawFormatBits(int mask)
        {
            int data = MediumFormatBits << 3 | mask;
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            int bits = (data << 10 | rem) ^ 0x5412;
            Func<int, bool> bit = i => ((bits >> i) & 1) != 0;
            for (int i = 0; i <= 5; i++) Set(8, i, bit(i));
            Set(8, 7, bit(6));
            Set(8, 8, bit(7));
            Set(7, 8, bit(8));
            for (int i = 9; i < 15; i++) Set(14 - i, 8, bit(i));
            for (int i = 0; i < 8; i++) Set(size - 1 - i, 8, bit(i));
            for (int i = 8; i < 15; i++) Set(8, size - 15 + i, bit(i));
            Set(8, size - 8, true);
        }

        public void DrawCodewords(byte[] data)
        {
            int i = 0;
            for (int right = size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (int vert = 0; vert < size; vert++)
                    for (int j = 0; j < 2; j++)
                    {
                        int x = right - j;
                        bool upward = ((right + 1) & 2) == 0;
                        int y = upward ? size - 1 - vert : vert;
                        if (!isFunction[y, x] && i < data.Length * 8)
                        {
                            Modules[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                            i++;
                        }
                    }
            }
        }

        public void ApplyMask(int mask)
        {
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    bool invert;
                    switch (mask)
                    {
                        case 0: invert = (x + y) % 2 == 0; break;
                        case 1: invert = y % 2 == 0; break;
                        case 2: invert = x % 3 == 0; break;
                        case 3: invert = (x + y) % 3 == 0; break;
                        case 4: invert = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: invert = x * y % 2 + x * y % 3 == 0; break;
                        case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (invert && !isFunction[y, x]) Modules[y, x] = !Modules[y, x];
                }
        }

        // Long runs, 2x2 blocks and an uneven balance of dark and light all make a code harder to scan
        public long Penalty()
        {
            long result = 0;
            for (int pass = 0; pass < 2; pass++)
                for (int a = 0; a < size; a++)
                {
                    int run = 0;
                    bool last = false;
                    for (int b = 0; b < size; b++)
                    {
                        bool m = pass == 0 ? Modules[a, b] : Modules[b, a];
                        if (b > 0 && m == last) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
                        else run = 1;
                        last = m;
                    }
                }
            for (int y = 0; y < size - 1; y++)
                for (int x = 0; x < size - 1; x++)
                {
                    bool m = Modules[y, x];
                    if (m == Modules[y, x + 1] && m == Modules[y + 1, x] && m == Modules[y + 1, x + 1]) result += 3;
                }
            int dark = 0;
            foreach (bool m in Modules) if (m) dark++;
            int total = size * size;
            int k = (Math.Abs(dark * 20 - total * 10) + total - 1) / total - 1;
            result += Math.Max(0, k) * 10;
            return result;
        }
    }
}
