using System;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using Cornetta.Core;
using Velopack;

namespace Cornetta.App
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            // Velopack prima di tutto: gestisce installazione, aggiornamento e disinstallazione.
            bool firstRun = false;
            VelopackApp.Build().OnFirstRun(_ => firstRun = true).Run();

            Diagnostics.FilePath = AppInfo.LogPath;

            if (args.Contains("--selftest", StringComparer.OrdinalIgnoreCase)) return SelfTest.Run(args);
            if (args.Contains("--record", StringComparer.OrdinalIgnoreCase)) return Headless.Run(args);
            if (args.Contains("--render-ui", StringComparer.OrdinalIgnoreCase)) return UiPreview.Run(args);
            if (args.Contains("--smoke-tray", StringComparer.OrdinalIgnoreCase)) return SmokeTray();

            using (var single = new Mutex(true, @"Local\Cornetta.Tray", out bool created))
            {
                if (!created) return 0;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (_, e) => Diagnostics.Log("Errore non gestito: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (_, e) => Diagnostics.Log("Errore fatale: " + e.ExceptionObject);
                Diagnostics.Log("Avvio Cornetta " + AppInfo.Version + " da " + AppInfo.ExecutablePath);
                // Qui e non nel costruttore di TrayApp: la prova --smoke-tray della CI non deve mandare eventi.
                Telemetry.AppLaunched();
                Application.Run(new TrayApp(firstRun));
                GC.KeepAlive(single);
            }
            return 0;
        }

        /// <summary>
        /// Prova di avvio per il CI: costruisce l'app vera (icona, menu, scorciatoia, timer) e la chiude dopo 3 secondi.
        /// Selftest e pannelli non passano dal costruttore di TrayApp: senza questa prova un crash all'avvio arriva agli utenti.
        /// </summary>
        private static int SmokeTray()
        {
            ConsoleOutput.Attach();
            try
            {
                Application.EnableVisualStyles();
                var app = new TrayApp(false);
                var stop = new System.Windows.Forms.Timer { Interval = 3000 };
                stop.Tick += (_, __) => { stop.Stop(); app.ExitThread(); };
                stop.Start();
                Application.Run(app);
                Console.WriteLine("Avvio dell'app riuscito");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Avvio dell'app non riuscito: " + ex);
                return 1;
            }
        }
    }
}
