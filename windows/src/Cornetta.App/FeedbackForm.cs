using System;
using System.Drawing;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Cornetta.Core;

namespace Cornetta.App
{
    /// <summary>Invia il feedback al servizio di Cornetta. Stesso schema del Mac, più «platform».</summary>
    internal static class FeedbackSender
    {
        private static readonly HttpClient Client = CreateClient();

        private static HttpClient CreateClient()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            return new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        }

        /// <summary>Null se il feedback è arrivato, altrimenti il messaggio d'errore da mostrare.</summary>
        public static async Task<string?> SendAsync(string message, string name, string email, string? diagnostics, string? microphone)
        {
            string json = FeedbackPayload.ToJson(message, name, email, diagnostics, AppInfo.FeedbackInfo(microphone));
            try
            {
                using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
                using (var response = await Client.PostAsync(AppInfo.FeedbackUrl, content).ConfigureAwait(true))
                {
                    string body = await response.Content.ReadAsStringAsync().ConfigureAwait(true);
                    string? error = FeedbackResponse.ErrorFor((int)response.StatusCode, body);
                    if (error == null) Diagnostics.Log("Feedback inviato (" + message.Length + " caratteri)");
                    else Diagnostics.Log("Feedback non inviato: HTTP " + (int)response.StatusCode);
                    return error;
                }
            }
            catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException || ex is WebException)
            {
                Diagnostics.Log("Feedback non inviato: " + ex.Message);
                return FeedbackResponse.GenericError;
            }
        }
    }

    /// <summary>Finestra del feedback. Testi identici a FeedbackView in Sources/Cornetta/Feedback.swift.</summary>
    internal sealed class FeedbackForm : Form
    {
        private string? microphone;
        private readonly float scale;
        private readonly TableLayoutPanel formPanel;
        private readonly TableLayoutPanel sentPanel;
        private readonly TextBox messageBox;
        private readonly TextBox nameBox;
        private readonly TextBox emailBox;
        private readonly CheckBox diagnosticsCheck;
        private readonly LinkLabel previewLink;
        private readonly TextBox previewBox;
        private readonly Label errorLabel;
        private readonly Button sendButton;
        /// <summary>Null finché CollectDiagnostics non ha finito.</summary>
        private string? diagnostics;
        private bool sending;

        /// <param name="microphone">Il microfono della registrazione in corso; senza, si legge quello delle chiamate.</param>
        public FeedbackForm(string? microphone)
        {
            this.microphone = microphone;
            using (var g = CreateGraphics()) scale = g.DpiX / 96f;
            Text = "Feedback su Cornetta";
            Font = new Font("Segoe UI", 9.75f);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            ShowInTaskbar = true;
            AutoScaleMode = AutoScaleMode.None;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Padding = new Padding(Px(20));
            Icon = TrayIcons.App;

            int width = Px(480);

            formPanel = Column(width);
            var title = WrapLabel("Cosa funziona, cosa no, cosa ti manca?", width, new Font("Segoe UI Semibold", 12f));
            var subtitle = WrapLabel("Scrivi come ti viene. Se qualcosa non ha funzionato, racconta cosa stavi facendo.", width, Font);
            subtitle.ForeColor = SystemColors.GrayText;
            messageBox = new TextBox
            {
                Multiline = true,
                AcceptsReturn = true,
                ScrollBars = ScrollBars.Vertical,
                Width = width,
                Height = Px(140),
                Margin = new Padding(0, Px(10), 0, Px(10)),
                AccessibleName = "Messaggio",
            };
            messageBox.TextChanged += (_, __) => UpdateSendButton();

            var people = new TableLayoutPanel { ColumnCount = 2, RowCount = 1, AutoSize = true, Margin = new Padding(0), Width = width };
            people.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            people.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            nameBox = new TextBox { Width = (width - Px(8)) / 2, Margin = new Padding(0, 0, Px(8), 0), Text = Settings.FeedbackName, AccessibleName = "Nome (facoltativo)" };
            emailBox = new TextBox { Width = (width - Px(8)) / 2, Margin = new Padding(0), Text = Settings.FeedbackEmail, AccessibleName = "Email per la risposta (facoltativa)" };
            people.Controls.Add(nameBox, 0, 0);
            people.Controls.Add(emailBox, 1, 0);

            diagnosticsCheck = new CheckBox
            {
                Text = "Allega informazioni tecniche (versione, dispositivi audio, log). Nessun audio.",
                // Spenta come sul Mac: la diagnostica parte solo se la scegli (pagina /privacy/).
                Checked = FeedbackPayload.DiagnosticsByDefault,
                AutoSize = false,
                Width = width,
                Margin = new Padding(0, Px(12), 0, 0),
            };
            diagnosticsCheck.Height = TextRenderer.MeasureText(diagnosticsCheck.Text, Font, new Size(width - Px(20), int.MaxValue), TextFormatFlags.WordBreak).Height + Px(6);
            diagnosticsCheck.CheckedChanged += (_, __) => { UpdateDiagnosticsVisibility(); UpdateSendButton(); };

            previewLink = new LinkLabel { Text = "Vedi cosa viene inviato", AutoSize = true, Margin = new Padding(Px(18), Px(2), 0, 0) };
            previewLink.LinkClicked += (_, __) => { previewBox!.Visible = !previewBox.Visible; };

            previewBox = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                WordWrap = false,
                Width = width,
                Height = Px(120),
                Font = new Font("Consolas", 8.25f),
                Text = "Raccolgo le informazioni…",
                Visible = false,
                Margin = new Padding(0, Px(6), 0, 0),
                AccessibleName = "Informazioni tecniche che vengono inviate",
            };

            UpdateDiagnosticsVisibility();

            errorLabel = WrapLabel("", width, Font);
            errorLabel.ForeColor = Color.FromArgb(0xC4, 0x2B, 0x1C);
            errorLabel.Visible = false;
            errorLabel.Margin = new Padding(0, Px(8), 0, 0);

            var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = false, Width = width, Height = Px(44), Margin = new Padding(0, Px(14), 0, 0), WrapContents = false };
            sendButton = new Button { Text = "Invia feedback", AutoSize = true, MinimumSize = new Size(Px(110), Px(30)), Enabled = false };
            var cancelButton = new Button { Text = "Annulla", AutoSize = true, MinimumSize = new Size(Px(90), Px(30)), DialogResult = DialogResult.Cancel };
            sendButton.Click += async (_, __) => await Submit();
            cancelButton.Click += (_, __) => Close();
            buttons.Controls.Add(sendButton);
            buttons.Controls.Add(cancelButton);
            CancelButton = cancelButton;

            formPanel.Controls.Add(title);
            formPanel.Controls.Add(subtitle);
            formPanel.Controls.Add(messageBox);
            formPanel.Controls.Add(people);
            formPanel.Controls.Add(diagnosticsCheck);
            formPanel.Controls.Add(previewLink);
            formPanel.Controls.Add(previewBox);
            formPanel.Controls.Add(errorLabel);
            formPanel.Controls.Add(buttons);

            sentPanel = Column(width);
            sentPanel.Visible = false;
            var check = new Label
            {
                Text = "",
                Font = new Font("Segoe MDL2 Assets", 28f),
                ForeColor = Color.FromArgb(0x10, 0x7C, 0x10),
                AutoSize = false,
                Width = width,
                Height = Px(56),
                TextAlign = ContentAlignment.MiddleCenter,
                Margin = new Padding(0, Px(30), 0, Px(6)),
            };
            var thanks = WrapLabel("Grazie, il feedback è arrivato.", width, new Font("Segoe UI Semibold", 12f));
            thanks.TextAlign = ContentAlignment.MiddleCenter;
            var note = WrapLabel("Lo leggo e ti scrivo se hai lasciato l'email.", width, Font);
            note.TextAlign = ContentAlignment.MiddleCenter;
            note.ForeColor = SystemColors.GrayText;
            var closeButton = new Button { Text = "Chiudi", AutoSize = true, MinimumSize = new Size(Px(90), Px(30)), Anchor = AnchorStyles.None, Margin = new Padding(0, Px(16), 0, Px(30)) };
            closeButton.Click += (_, __) => Close();
            sentPanel.Controls.Add(check);
            sentPanel.Controls.Add(thanks);
            sentPanel.Controls.Add(note);
            sentPanel.Controls.Add(closeButton);

            formPanel.Location = new Point(Px(20), Px(20));
            sentPanel.Location = new Point(Px(20), Px(20));
            Controls.Add(formPanel);
            Controls.Add(sentPanel);
            AcceptButton = null;
            Shown += async (_, __) =>
            {
                SetCue(nameBox, "Nome (facoltativo)");
                SetCue(emailBox, "Email per la risposta (facoltativa)");
                messageBox.Focus();
                await CollectDiagnostics();
            };
        }

        /// <summary>Dispositivi, sessioni audio e log si leggono dopo l'apertura, fuori dal thread dell'interfaccia.</summary>
        private async Task CollectDiagnostics()
        {
            string? mic = microphone;
            string text;
            try
            {
                var collected = await Task.Run(() =>
                {
                    string? name = mic ?? AudioDevices.Describe().Input;
                    return (name, AppInfo.DiagnosticsText(name));
                });
                mic = collected.name;
                text = collected.Item2;
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Informazioni tecniche non raccolte: " + ex.Message);
                text = "";
            }
            if (IsDisposed) return;
            microphone = mic;
            diagnostics = text;
            previewBox.Text = text;
            UpdateSendButton();
        }

        private int Px(float value) => (int)Math.Round(value * scale);

        private static TableLayoutPanel Column(int width) => new TableLayoutPanel
        {
            ColumnCount = 1,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            MaximumSize = new Size(width, 0),
            MinimumSize = new Size(width, 0),
            Margin = new Padding(0),
            Padding = new Padding(0),
        };

        private static Label WrapLabel(string text, int width, Font font) => new Label
        {
            Text = text,
            Font = font,
            AutoSize = true,
            MaximumSize = new Size(width, 0),
            MinimumSize = new Size(width, 0),
            Margin = new Padding(0, 0, 0, 4),
        };

        private static void SetCue(TextBox box, string cue)
        {
            NativeMethods.SendMessage(box.Handle, NativeMethods.EM_SETCUEBANNER, new IntPtr(1), cue);
        }

        private void UpdateDiagnosticsVisibility()
        {
            previewLink.Visible = diagnosticsCheck.Checked;
            if (!diagnosticsCheck.Checked) previewBox.Visible = false;
        }

        private void UpdateSendButton()
        {
            // Con la diagnostica accesa si aspetta che sia pronta.
            sendButton.Enabled = !sending && messageBox.Text.Trim().Length >= 2 && (diagnostics != null || !diagnosticsCheck.Checked);
        }

        private async Task Submit()
        {
            sending = true;
            UpdateSendButton();
            sendButton.Text = "Invio…";
            errorLabel.Visible = false;
            Settings.FeedbackName = nameBox.Text.Trim();
            Settings.FeedbackEmail = emailBox.Text.Trim();
            string? error = await FeedbackSender.SendAsync(messageBox.Text, nameBox.Text.Trim(), emailBox.Text.Trim(),
                diagnosticsCheck.Checked ? diagnostics : null, FeedbackPayload.MicrophoneToSend(microphone, diagnosticsCheck.Checked));
            sending = false;
            sendButton.Text = "Invia feedback";
            UpdateSendButton();
            if (error == null)
            {
                formPanel.Visible = false;
                sentPanel.Visible = true;
                AcceptButton = null;
            }
            else
            {
                errorLabel.Text = "⚠ " + error;
                errorLabel.Visible = true;
            }
        }
    }
}
