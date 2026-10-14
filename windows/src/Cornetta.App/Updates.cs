using System;
using System.Drawing;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using Cornetta.Core;
using Velopack;

namespace Cornetta.App
{
    /// <summary>Icone incluse nell'eseguibile.</summary>
    internal static class TrayIcons
    {
        public static readonly Icon App = Load("cornetta.ico", 32);
        public static readonly Icon Idle = Load("tray-idle.ico", SystemInformation.SmallIconSize.Width);
        public static readonly Icon Recording = Load("tray-recording.ico", SystemInformation.SmallIconSize.Width);
        public static readonly Icon Update = Load("tray-update.ico", SystemInformation.SmallIconSize.Width);

        private static Icon Load(string name, int size)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Cornetta." + name))
            {
                if (stream == null) return SystemIcons.Application;
                return new Icon(stream, new Size(size, size));
            }
        }
    }

    /// <summary>Esito di un controllo degli aggiornamenti.</summary>
    internal enum UpdateCheck { NotInstalled, UpToDate, Found, Failed }

    /// <summary>
    /// Aggiornamenti da remoto con Velopack: il feed sta in https://cornetta.stellakamikaze.org/windows/
    /// (releases.win.json più i pacchetti .nupkg). Controllo all'avvio e ogni 4 ore.
    /// </summary>
    internal sealed class UpdateService
    {
        private readonly UpdateManager? manager;
        private UpdateInfo? update;

        public UpdateService()
        {
            string feed = Settings.FeedOverride ?? AppInfo.UpdateFeedUrl;
            try
            {
                manager = new UpdateManager(feed);
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Aggiornamenti non disponibili: " + ex.Message);
            }
        }

        /// <summary>Vero se l'app è installata con Setup (in sviluppo gli aggiornamenti sono spenti).</summary>
        public bool IsInstalled
        {
            get
            {
                try { return manager?.IsInstalled == true; }
                catch (Exception) { return false; }
            }
        }

        /// <summary>Versione pronta da installare, se c'è.</summary>
        public string? AvailableVersion => update?.TargetFullRelease.Version.ToString();

        public async Task<UpdateCheck> CheckAsync()
        {
            if (manager == null || !IsInstalled) return UpdateCheck.NotInstalled;
            try
            {
                var info = await manager.CheckForUpdatesAsync().ConfigureAwait(true);
                if (info == null) return UpdateCheck.UpToDate;
                bool isNew = update == null || update.TargetFullRelease.Version.ToString() != info.TargetFullRelease.Version.ToString();
                update = info;
                if (isNew) Diagnostics.Log("Aggiornamento trovato: " + info.TargetFullRelease.Version);
                return UpdateCheck.Found;
            }
            catch (Exception ex)
            {
                Diagnostics.Log("Controllo aggiornamenti: " + ex.Message);
                return UpdateCheck.Failed;
            }
        }

        /// <summary>Scarica, installa e riapre Cornetta. Se va a buon fine il processo termina qui.</summary>
        public async Task InstallAsync(Action<int>? progress, Action beforeRestart)
        {
            if (manager == null || update == null) return;
            await manager.DownloadUpdatesAsync(update, progress).ConfigureAwait(true);
            Diagnostics.Log("Installo l'aggiornamento " + update.TargetFullRelease.Version);
            beforeRestart();
            manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
        }
    }

    /// <summary>Scorciatoia globale Ctrl+Alt+R per avviare e fermare la registrazione.</summary>
    internal sealed class GlobalHotkey : NativeWindow, IDisposable
    {
        private const int Id = 0xC0E7;
        private readonly Action pressed;

        public GlobalHotkey(Action pressed)
        {
            this.pressed = pressed;
            CreateHandle(new CreateParams());
            Registered = NativeMethods.RegisterHotKey(Handle, Id,
                NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT | NativeMethods.MOD_NOREPEAT, (uint)Keys.R);
            if (!Registered) Diagnostics.Log("Scorciatoia Ctrl+Alt+R già usata da un'altra app");
        }

        public bool Registered { get; }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_HOTKEY && m.WParam.ToInt32() == Id) pressed();
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Registered) NativeMethods.UnregisterHotKey(Handle, Id);
            DestroyHandle();
        }
    }
}
