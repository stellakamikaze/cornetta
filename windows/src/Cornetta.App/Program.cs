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

            using (var single = new Mutex(true, @"Local\Cornetta.Tray", out bool created))
            {
                if (!created) return 0;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (_, e) => Diagnostics.Log("Errore non gestito: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (_, e) => Diagnostics.Log("Errore fatale: " + e.ExceptionObject);
                Diagnostics.Log("Avvio Cornetta " + AppInfo.Version + " da " + AppInfo.ExecutablePath);
                Application.Run(new TrayApp(firstRun));
                GC.KeepAlive(single);
            }
            return 0;
        }
    }
}
