using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Cornetta.App
{
    /// <summary>
    /// Pannello mostrato durante la registrazione. Testi identici a Sources/Cornetta/OverlayViews.swift:
    /// tempo, livelli «Tu» e «Altri», «Ferma», «Feedback», banner «La chiamata sembra finita» con «Continua».
    /// </summary>
    internal sealed class OverlayForm : PanelForm
    {
        private readonly PanelButton stopButton;
        private readonly PanelButton feedbackButton;
        private readonly PanelButton continueButton;
        private readonly Font timeFont = new Font("Segoe UI Semibold", 14.25f);
        private readonly Font bannerFont = new Font("Segoe UI Semibold", 9f);
        private readonly Font captionFont = new Font("Segoe UI", 8.25f);
        private readonly Font barLabelFont = new Font("Segoe UI Semibold", 7.5f);
        private readonly Font glyphFont = new Font(IconFont, 11f);
        private readonly DateTime shownAt = DateTime.UtcNow;
        private readonly bool animate = SystemInformation.UIEffectsEnabled;

        private string elapsed = "00:00";
        private float micLevel;
        private float systemLevel;
        private string microphone = "";
        private bool callEnded;

        // Geometria calcolata in Relayout.
        private Rectangle bannerRow;
        private int dividerY;
        private Rectangle dotRect;
        private Rectangle timeRect;
        private Rectangle micBar;
        private Rectangle systemBar;
        private Rectangle captionRect;

        public event Action? StopClicked;
        public event Action? FeedbackClicked;
        public event Action? ContinueClicked;

        public OverlayForm()
        {
            Text = "Cornetta";
            AccessibleName = "Cornetta, registrazione in corso";
            stopButton = new PanelButton("Ferma", theme, scale, Theme.Red, "");
            feedbackButton = new PanelButton("Feedback", theme, scale, null, "", small: true);
            continueButton = new PanelButton("Continua", theme, scale, null, null, small: true);
            stopButton.Click += (_, __) => StopClicked?.Invoke();
            feedbackButton.Click += (_, __) => FeedbackClicked?.Invoke();
            continueButton.Click += (_, __) => ContinueClicked?.Invoke();
            tips.SetToolTip(stopButton, "Ferma e salva la registrazione");
            tips.SetToolTip(feedbackButton, "Segnala un problema o un'idea a chi sviluppa Cornetta");
            Controls.Add(stopButton);
            Controls.Add(feedbackButton);
            Controls.Add(continueButton);
            Relayout();
            var saved = Settings.OverlayPosition;
            if (saved.HasValue) Location = new Point(saved.Value.X, saved.Value.Y); else PlaceTopRight();
        }

        public void UpdateState(string elapsedText, float mic, float system, string? microphoneName, bool callEndedSuggestion)
        {
            elapsed = elapsedText;
            micLevel = mic;
            systemLevel = system;
            microphone = microphoneName != null ? "Microfono: " + microphoneName : "Senza microfono: registro solo la chiamata";
            if (callEndedSuggestion != callEnded)
            {
                callEnded = callEndedSuggestion;
                Relayout();
                KeepOnScreen();
            }
            Invalidate();
        }

        protected override void OnMoved() => Settings.OverlayPosition = (Left, Top);

        private void Relayout()
        {
            int pad = Px(14);
            int width = Px(428);
            int inner = width - pad * 2;
            int y = pad;

            continueButton.Visible = callEnded;
            if (callEnded)
            {
                int rowHeight = Math.Max(continueButton.Height, Px(22));
                bannerRow = new Rectangle(pad, y, inner, rowHeight);
                continueButton.Location = new Point(pad + inner - continueButton.Width, y + (rowHeight - continueButton.Height) / 2);
                y += rowHeight + Px(5);
                dividerY = y;
                y += Px(6);
            }

            int mainHeight = Math.Max(stopButton.Height, Px(36));
            int center = y + mainHeight / 2;
            dotRect = new Rectangle(pad, center - Px(6), Px(12), Px(12));
            timeRect = new Rectangle(dotRect.Right + Px(12), y, Px(72), mainHeight);
            int barsX = timeRect.Right + Px(8);
            micBar = new Rectangle(barsX, center - Px(9), Px(150), Px(6));
            systemBar = new Rectangle(barsX, center + Px(4), Px(150), Px(6));
            stopButton.Location = new Point(pad + inner - stopButton.Width, center - stopButton.Height / 2);
            y += mainHeight + Px(10);

            int captionHeight = Math.Max(feedbackButton.Height, Px(20));
            feedbackButton.Location = new Point(pad + inner - feedbackButton.Width, y + (captionHeight - feedbackButton.Height) / 2);
            captionRect = new Rectangle(pad, y, inner - feedbackButton.Width - Px(8), captionHeight);
            y += captionHeight + pad;

            ClientSize = new Size(width, y);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            if (callEnded)
            {
                var glyph = new Rectangle(bannerRow.X, bannerRow.Y, Px(20), bannerRow.Height);
                DrawText(g, "", glyphFont, Theme.Orange, glyph, TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
                var text = new Rectangle(glyph.Right + Px(6), bannerRow.Y, bannerRow.Width - glyph.Width - continueButton.Width - Px(12), bannerRow.Height);
                DrawText(g, "La chiamata sembra finita", bannerFont, theme.Text, text, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
                using (var pen = new Pen(theme.Divider)) g.DrawLine(pen, bannerRow.X, dividerY, bannerRow.Right, dividerY);
            }

            // Pallino rosso che pulsa piano (fermo se Windows ha le animazioni spente).
            float alpha = 1;
            if (animate)
            {
                double t = (DateTime.UtcNow - shownAt).TotalSeconds;
                alpha = 0.65f + 0.35f * (float)Math.Cos(t * Math.PI / 0.8);
            }
            using (var brush = new SolidBrush(Color.FromArgb((int)(255 * alpha), Theme.Red))) g.FillEllipse(brush, dotRect);

            DrawText(g, elapsed, timeFont, theme.Text, timeRect, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding);
            DrawBar(g, "Tu", micLevel, Theme.MeterBlue, micBar);
            DrawBar(g, "Altri", systemLevel, Theme.MeterGreen, systemBar);
            DrawText(g, microphone, captionFont, theme.SecondaryText, captionRect, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        }

        private void DrawBar(Graphics g, string label, float level, Color tint, Rectangle bar)
        {
            int labelWidth = Px(30);
            var labelRect = new Rectangle(bar.X, bar.Y - Px(5), labelWidth, bar.Height + Px(10));
            DrawText(g, label, barLabelFont, theme.SecondaryText, labelRect, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding);
            var track = new Rectangle(bar.X + labelWidth, bar.Y, bar.Width - labelWidth, bar.Height);
            using (var path = RoundedRect(track, track.Height / 2))
            using (var brush = new SolidBrush(theme.Track))
            {
                g.FillPath(brush, path);
            }
            int fill = (int)(track.Width * Math.Min(Math.Max(level, 0), 1));
            if (fill >= track.Height)
            {
                using (var path = RoundedRect(new Rectangle(track.X, track.Y, fill, track.Height), track.Height / 2))
                using (var brush = new SolidBrush(tint))
                {
                    g.FillPath(brush, path);
                }
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timeFont.Dispose();
                bannerFont.Dispose();
                captionFont.Dispose();
                barLabelFont.Dispose();
                glyphFont.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    /// <summary>
    /// Avviso generico: chiamata iniziata, chiamata finita, aggiornamento disponibile.
    /// Porta di NoticeView in Sources/Cornetta/OverlayViews.swift.
    /// </summary>
    internal sealed class NoticeForm : PanelForm
    {
        private readonly string glyph;
        private readonly Color tint;
        private readonly string title;
        private readonly string message;
        private readonly Font titleFont = new Font("Segoe UI Semibold", 10.5f);
        private readonly Font iconFont = new Font(IconFont, 16f);
        private Rectangle iconRect;
        private Rectangle titleRect;
        private Rectangle messageRect;

        public NoticeForm(string kind, string glyph, Color tint, string title, string message, string primary, string secondary,
                          Action onPrimary, Action onSecondary)
        {
            Kind = kind;
            this.glyph = glyph;
            this.tint = tint;
            this.title = title;
            this.message = message;
            Text = title;
            AccessibleName = title + ". " + message;
            var primaryButton = new PanelButton(primary, theme, scale, tint);
            var secondaryButton = new PanelButton(secondary, theme, scale);
            primaryButton.Click += (_, __) => onPrimary();
            secondaryButton.Click += (_, __) => onSecondary();
            Controls.Add(primaryButton);
            Controls.Add(secondaryButton);

            int pad = Px(14);
            int width = Px(388);
            iconRect = new Rectangle(pad, pad, Px(30), Px(30));
            int textX = iconRect.Right + Px(12);
            int textWidth = width - textX - pad;
            var titleSize = TextRenderer.MeasureText(title, titleFont, new Size(textWidth, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            titleRect = new Rectangle(textX, pad, textWidth, titleSize.Height);
            var messageSize = TextRenderer.MeasureText(message, Font, new Size(textWidth, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            messageRect = new Rectangle(textX, titleRect.Bottom + Px(6), textWidth, messageSize.Height);
            int buttonsY = messageRect.Bottom + Px(10);
            primaryButton.Location = new Point(width - pad - primaryButton.Width, buttonsY);
            secondaryButton.Location = new Point(primaryButton.Left - Px(8) - secondaryButton.Width, buttonsY);
            ClientSize = new Size(width, buttonsY + primaryButton.Height + pad);
            PlaceTopRight();
        }

        public string Kind { get; }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            DrawText(g, glyph, iconFont, tint, iconRect, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top);
            DrawText(g, title, titleFont, theme.Text, titleRect, TextFormatFlags.WordBreak | TextFormatFlags.Left);
            DrawText(g, message, Font, theme.SecondaryText, messageRect, TextFormatFlags.WordBreak | TextFormatFlags.Left);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                titleFont.Dispose();
                iconFont.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
