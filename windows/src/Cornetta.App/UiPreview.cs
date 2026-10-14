using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

namespace Cornetta.App
{
    /// <summary>
    /// Disegna pannelli e finestre in PNG, per controllarli a vista senza un PC Windows:
    ///   Cornetta.exe --render-ui C:\cartella
    /// Il CI li allega agli artifact (tema chiaro e scuro).
    /// </summary>
    internal static class UiPreview
    {
        public static int Run(string[] args)
        {
            ConsoleOutput.Attach();
            string dir = SelfTest.ArgumentAfter(args, "--render-ui") ?? Path.Combine(AppInfo.DataDirectory, "ui");
            Directory.CreateDirectory(dir);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                foreach (bool dark in new[] { false, true })
                {
                    Theme.Override = dark;
                    string suffix = dark ? "-scuro" : "-chiaro";

                    var overlay = new OverlayForm();
                    overlay.UpdateState("12:34", 0.72f, 0.45f, "Microfono (Realtek(R) Audio)", false);
                    Save(overlay, Path.Combine(dir, "pannello" + suffix + ".png"));

                    overlay = new OverlayForm();
                    overlay.UpdateState("1:02:09", 0.1f, 0f, null, true);
                    Save(overlay, Path.Combine(dir, "pannello-chiamata-finita" + suffix + ".png"));

                    Save(new NoticeForm("call", "\uE717", Theme.Red, "Chiamata in corso su WhatsApp",
                        "Vuoi registrarla? Registro la tua voce e quella delle altre persone in un file.",
                        "Registra", "Non ora", () => { }, () => { }), Path.Combine(dir, "avviso-chiamata" + suffix + ".png"));
                    Save(new NoticeForm("update", "\uE896", Theme.Blue, "Aggiornamento disponibile",
                        "È pronta Cornetta 0.3.0. L'installazione richiede pochi secondi e l'app si riapre da sola.",
                        "Aggiorna ora", "Più tardi", () => { }, () => { }), Path.Combine(dir, "avviso-aggiornamento" + suffix + ".png"));
                    Save(new NoticeForm("ended", "\uE778", Theme.Orange, "La chiamata sembra finita",
                        "Cornetta sta ancora registrando.", "Ferma e salva", "Continua", () => { }, () => { }),
                        Path.Combine(dir, "avviso-fine" + suffix + ".png"));
                }
                Theme.Override = null;
                Save(new FeedbackForm("Microfono (Realtek(R) Audio)"), Path.Combine(dir, "feedback.png"));
                Console.WriteLine("Immagini in " + dir);
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Disegno non riuscito: " + ex);
                return 1;
            }
        }

        private static void Save(Form form, string path)
        {
            form.StartPosition = FormStartPosition.Manual;
            form.Location = new Point(-20000, -20000);
            form.ShowInTaskbar = false;
            form.Show();
            Application.DoEvents();
            using (var bitmap = new Bitmap(form.Width, form.Height))
            {
                form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height));
                bitmap.Save(path, ImageFormat.Png);
            }
            form.Close();
            form.Dispose();
            Console.WriteLine("Scritto " + path);
        }
    }
}
