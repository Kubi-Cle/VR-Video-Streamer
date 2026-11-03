// The screen viewers see between videos and while paused: the Double V logo and a line or two of text,
// drawn here and handed to PipePlayer as one ready-made frame of the stream's picture format.
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class IntermissionCard
{
    static SolidColorBrush Brush(byte r, byte g, byte b) { return new SolidColorBrush(Color.FromRgb(r, g, b)); }

    static void Vee(DrawingContext dc, double x, double y, double scale, Brush colour, double[] p)
    {
        var pen = new Pen(colour, 7 * scale) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        for (int i = 0; i + 3 < p.Length; i += 2)
            dc.DrawLine(pen, new Point(x + p[i] * scale, y + p[i + 1] * scale), new Point(x + p[i + 2] * scale, y + p[i + 3] * scale));
    }

    static void Line(DrawingContext dc, string text, double size, FontWeight weight, Brush colour, int width, double y)
    {
        if (string.IsNullOrEmpty(text)) return;
        var f = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, weight, FontStretches.Normal), size, colour, 1.0);
        f.MaxTextWidth = width * 0.8;
        f.MaxLineCount = 2;
        f.Trimming = TextTrimming.CharacterEllipsis;
        f.TextAlignment = TextAlignment.Center;
        dc.DrawText(f, new Point(width * 0.1, y));
    }

    // Returns the card as yuv420p, the player's frame format. Call from the window's thread.
    public static byte[] Make(int w, int h, string headline, string detail)
    {
        var visual = new DrawingVisual();
        using (DrawingContext dc = visual.RenderOpen())
        {
            dc.DrawRectangle(Brush(0x10, 0x18, 0x1A), null, new Rect(0, 0, w, h));
            double size = h * 0.3, scale = size / 64, x = (w - size) / 2, y = h * 0.16;
            dc.DrawRoundedRectangle(Brush(0x04, 0x34, 0x2C), null, new Rect(x, y, size, size), 14 * scale, 14 * scale);
            Vee(dc, x, y, scale, Brush(0x5D, 0xCA, 0xA5), new double[] { 12, 16, 32, 50, 52, 16 });
            Vee(dc, x, y, scale, Brushes.White, new double[] { 24, 16, 32, 30, 40, 16 });
            Line(dc, headline, h * 0.06, FontWeights.SemiBold, Brushes.White, w, h * 0.54);
            Line(dc, detail, h * 0.04, FontWeights.Normal, Brush(0x9F, 0xE1, 0xCB), w, h * 0.65);
        }
        var bitmap = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var bgra = new byte[w * h * 4];
        bitmap.CopyPixels(bgra, w * 4, 0);

        var yuv = new byte[w * h * 3 / 2];
        int uStart = w * h, vStart = uStart + w * h / 4;
        for (int row = 0; row < h; row++)
            for (int col = 0; col < w; col++)
            {
                int i = (row * w + col) * 4;
                int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                yuv[row * w + col] = (byte)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                if (row % 2 == 0 && col % 2 == 0)
                {
                    int c = row / 2 * (w / 2) + col / 2;
                    yuv[uStart + c] = (byte)(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                    yuv[vStart + c] = (byte)(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
                }
            }
        return yuv;
    }
}
