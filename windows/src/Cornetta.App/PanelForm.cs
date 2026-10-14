using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Cornetta.App
{
    /// <summary>Colori dei pannelli, chiari o scuri come le app di Windows.</summary>
    internal sealed class Theme
    {
        public bool Dark { get; private set; }
        public Color Background { get; private set; }
        public Color Border { get; private set; }
        public Color Text { get; private set; }
        public Color SecondaryText { get; private set; }
        public Color Track { get; private set; }
        public Color NeutralButton { get; private set; }
        public Color NeutralButtonBorder { get; private set; }
        public Color NeutralButtonText { get; private set; }
        public Color Divider { get; private set; }

        public static readonly Color Red = Color.FromArgb(0xD4, 0x2A, 0x1F);      // --rec della pagina di download
        public static readonly Color Orange = Color.FromArgb(0xF7, 0x63, 0x0C);
        public static readonly Color Blue = Color.FromArgb(0x1F, 0x5F, 0xD6);     // --focus della pagina di download
        public static readonly Color MeterBlue = Color.FromArgb(0x2F, 0x7B, 0xF5);
        public static readonly Color MeterGreen = Color.FromArgb(0x2E, 0xA0, 0x43);

        public static Theme Current()
        {
            bool dark = false;
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    dark = key?.GetValue("AppsUseLightTheme") is int v && v == 0;
                }
            }
            catch (Exception) { }
            return dark
                ? new Theme
                {
                    Dark = true,
                    Background = Color.FromArgb(0x2B, 0x2B, 0x2B),
                    Border = Color.FromArgb(0x45, 0x45, 0x45),
                    Text = Color.White,
                    SecondaryText = Color.FromArgb(0xC8, 0xC8, 0xC8),
                    Track = Color.FromArgb(0x45, 0x45, 0x45),
                    NeutralButton = Color.FromArgb(0x3A, 0x3A, 0x3A),
                    NeutralButtonBorder = Color.FromArgb(0x50, 0x50, 0x50),
                    NeutralButtonText = Color.White,
                    Divider = Color.FromArgb(0x40, 0x40, 0x40),
                }
                : new Theme
                {
                    Background = Color.FromArgb(0xF9, 0xF9, 0xF9),
                    Border = Color.FromArgb(0xD5, 0xD5, 0xD5),
                    Text = Color.FromArgb(0x1B, 0x1B, 0x1B),
                    SecondaryText = Color.FromArgb(0x5C, 0x5C, 0x5C),
                    Track = Color.FromArgb(0xE3, 0xE3, 0xE3),
                    NeutralButton = Color.White,
                    NeutralButtonBorder = Color.FromArgb(0xCF, 0xCF, 0xCF),
                    NeutralButtonText = Color.FromArgb(0x1B, 0x1B, 0x1B),
                    Divider = Color.FromArgb(0xE5, 0xE5, 0xE5),
                };
        }
    }

    /// <summary>
    /// Pannello sempre in primo piano, senza bordo, che non ruba il focus all'app di chiamata.
    /// In alto a destra, si sposta trascinandolo.
    /// </summary>
    internal class PanelForm : Form
    {
        protected const string IconFont = "Segoe MDL2 Assets";
        protected readonly Theme theme = Theme.Current();
        protected readonly float scale;
        protected readonly ToolTip tips = new ToolTip();

        public PanelForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            DoubleBuffered = true;
            BackColor = theme.Background;
            ForeColor = theme.Text;
            Font = new Font("Segoe UI", 9f);
            using (var g = CreateGraphics()) scale = g.DpiX / 96f;
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_TOPMOST;
                cp.ClassStyle |= NativeMethods.CS_DROPSHADOW;
                return cp;
            }
        }

        protected int Px(float value) => (int)Math.Round(value * scale);

        private static bool IsWindows11 => Environment.OSVersion.Version.Major >= 10 && Environment.OSVersion.Version.Build >= 22000;

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            if (IsWindows11)
            {
                int round = NativeMethods.DWMWCP_ROUND;
                try { NativeMethods.DwmSetWindowAttribute(Handle, NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int)); }
                catch (Exception) { }
            }
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            if (!IsWindows11 && Width > 0 && Height > 0)
            {
                using (var path = RoundedRect(new Rectangle(0, 0, Width, Height), Px(8)))
                {
                    Region = new Region(path);
                }
            }
            Invalidate();
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(theme.Background);
            if (!IsWindows11)
            {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (var pen = new Pen(theme.Border))
                using (var path = RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Px(8)))
                {
                    e.Graphics.DrawPath(pen, path);
                }
            }
            e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            NativeMethods.ReleaseCapture();
            NativeMethods.SendMessage(Handle, NativeMethods.WM_NCLBUTTONDOWN, new IntPtr(NativeMethods.HTCAPTION), IntPtr.Zero);
            KeepOnScreen();
            OnMoved();
        }

        /// <summary>Chiamato dopo che l'utente ha spostato il pannello.</summary>
        protected virtual void OnMoved() { }

        /// <summary>In alto a destra, sotto il bordo dello schermo principale.</summary>
        public void PlaceTopRight()
        {
            var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
            Location = new Point(area.Right - Width - Px(16), area.Top + Px(16));
        }

        /// <summary>Se il pannello sborda, lo riporta dentro l'area visibile.</summary>
        public void KeepOnScreen()
        {
            var area = Screen.FromRectangle(Bounds).WorkingArea;
            int x = Math.Min(Math.Max(Left, area.Left + Px(8)), area.Right - Width - Px(8));
            int y = Math.Min(Math.Max(Top, area.Top + Px(8)), area.Bottom - Height - Px(8));
            if (x != Left || y != Top) Location = new Point(x, y);
        }

        /// <summary>Mostra il pannello senza attivarlo.</summary>
        public void ShowPanel()
        {
            if (!Visible)
            {
                NativeMethods.ShowWindow(Handle, NativeMethods.SW_SHOWNOACTIVATE);
                Visible = true;
            }
            NativeMethods.SetWindowPos(Handle, NativeMethods.HWND_TOPMOST, 0, 0, 0, 0,
                NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
            KeepOnScreen();
        }

        protected void DrawText(Graphics g, string text, Font font, Color color, Rectangle bounds, TextFormatFlags flags)
        {
            TextRenderer.DrawText(g, text, font, bounds, color, flags | TextFormatFlags.NoPrefix);
        }

        internal static GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = Math.Max(1, radius * 2);
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) tips.Dispose();
            base.Dispose(disposing);
        }
    }

    /// <summary>
    /// Pulsante a colori fissi: resta leggibile anche nei pannelli che non prendono il focus.
    /// Pieno (colore + testo bianco) oppure neutro (bordo sottile).
    /// </summary>
    internal sealed class PanelButton : Control
    {
        private readonly Theme theme;
        private readonly float scale;
        private bool hover;
        private bool pressed;

        public PanelButton(string text, Theme theme, float scale, Color? fill = null, string? glyph = null, bool small = false)
        {
            this.theme = theme;
            this.scale = scale;
            Text = text;
            Fill = fill;
            Glyph = glyph;
            Small = small;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                     | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            Font = new Font("Segoe UI Semibold", small ? 8.5f : 9.5f);
            AccessibleRole = AccessibleRole.PushButton;
            AccessibleName = text;
            Size = PreferredSize;
        }

        public Color? Fill { get; set; }
        public string? Glyph { get; }
        public bool Small { get; }

        private int Px(float v) => (int)Math.Round(v * scale);

        public override Size GetPreferredSize(Size proposedSize)
        {
            var text = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            int glyph = Glyph != null ? Px(Small ? 12 : 14) + Px(6) : 0;
            int padX = Px(Small ? 10 : 14);
            int padY = Px(Small ? 4 : 7);
            return new Size(text.Width + glyph + padX * 2, text.Height + padY * 2);
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { pressed = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent?.BackColor ?? theme.Background);
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Color background;
            Color foreground;
            if (Fill.HasValue)
            {
                var c = Fill.Value;
                background = pressed ? ControlPaint.Dark(c, 0.1f) : hover ? ControlPaint.Light(c, 0.1f) : c;
                foreground = Color.White;
            }
            else
            {
                background = pressed ? theme.Track : hover ? Blend(theme.NeutralButton, theme.Track, 0.5f) : theme.NeutralButton;
                foreground = theme.NeutralButtonText;
            }
            using (var path = PanelForm.RoundedRect(rect, Px(5)))
            using (var brush = new SolidBrush(background))
            {
                g.FillPath(brush, path);
                if (!Fill.HasValue)
                {
                    using (var pen = new Pen(theme.NeutralButtonBorder)) g.DrawPath(pen, path);
                }
            }
            var textSize = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            int glyphWidth = Glyph != null ? Px(Small ? 12 : 14) : 0;
            int gap = Glyph != null ? Px(6) : 0;
            int x = (Width - (glyphWidth + gap + textSize.Width)) / 2;
            if (Glyph != null)
            {
                using (var iconFont = new Font("Segoe MDL2 Assets", Small ? 8f : 9.5f))
                {
                    TextRenderer.DrawText(g, Glyph, iconFont, new Rectangle(x, 0, glyphWidth, Height), foreground,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                }
            }
            TextRenderer.DrawText(g, Text, Font, new Rectangle(x + glyphWidth + gap, 0, textSize.Width + Px(2), Height), foreground,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }

        private static Color Blend(Color a, Color b, float t) =>
            Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
}
