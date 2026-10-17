using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Http;
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
    /// Il feed è firmato (releases.win.json.sig, vedi FeedSignature): senza firma valida l'app non aggiorna.
    /// </summary>
    internal sealed class UpdateService
    {
        private const string FeedFile = "releases.win.json";
        private static readonly HttpClient Client = CreateClient();
        private readonly UpdateManager? manager;
        private readonly string feed;
        private UpdateInfo? update;

        private static HttpClient CreateClient()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            return new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        }

        public UpdateService()
        {
            feed = Settings.FeedOverride ?? AppInfo.UpdateFeedUrl;
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
                string? refusal = await SignedFeedRefusal(info).ConfigureAwait(true);
                if (refusal != null)
                {
                    Diagnostics.Log("Aggiornamento " + info.TargetFullRelease.Version + " rifiutato: " + refusal);
                    update = null;
                    return UpdateCheck.Failed;
                }
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
            // Copia locale: durante gli await un controllo del timer o del menu può cambiare il campo update.
            var target = update;
            if (manager == null || target == null) return;
            // Di nuovo subito prima di scaricare: dal controllo possono essere passate ore.
            string? refusal = await SignedFeedRefusal(target).ConfigureAwait(true);
            if (refusal != null)
            {
                Diagnostics.Log("Aggiornamento " + target.TargetFullRelease.Version + " rifiutato: " + refusal);
                if (ReferenceEquals(update, target)) update = null;
                throw new InvalidOperationException("Feed degli aggiornamenti senza firma valida: " + refusal);
            }
            await manager.DownloadUpdatesAsync(target, progress).ConfigureAwait(true);
            Diagnostics.Log("Installo l'aggiornamento " + target.TargetFullRelease.Version);
            beforeRestart();
            manager.ApplyUpdatesAndRestart(target.TargetFullRelease);
        }

        /// <summary>
        /// Null se il feed firmato copre ogni pacchetto che Velopack scaricherà (completo e delta), altrimenti il motivo.
        /// Velopack poi controlla l'hash del file scaricato con quello del pacchetto, che qui risulta firmato.
        /// </summary>
        private async Task<string?> SignedFeedRefusal(UpdateInfo info)
        {
            byte[] feedBytes;
            string signature;
            try
            {
                feedBytes = await ReadFeedFile(FeedFile).ConfigureAwait(true);
                signature = System.Text.Encoding.ASCII.GetString(await ReadFeedFile(FeedFile + ".sig").ConfigureAwait(true));
            }
            catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException || ex is WebException || ex is IOException || ex is UnauthorizedAccessException)
            {
                return "firma del feed non scaricata (" + ex.Message + ")";
            }
            string? problem = FeedSignature.Verify(feedBytes, signature, AppInfo.UpdateFeedPublicKey);
            if (problem != null) return problem;
            var signed = FeedSignature.ParseAssets(feedBytes);
            if (signed == null) return "feed firmato illeggibile";
            var wanted = new List<VelopackAsset> { info.TargetFullRelease };
            if (info.DeltasToTarget != null) wanted.AddRange(info.DeltasToTarget);
            foreach (var asset in wanted)
            {
                problem = FeedSignature.Covers(signed, new FeedAsset
                {
                    FileName = asset.FileName ?? "",
                    Sha1 = asset.SHA1 ?? "",
                    Sha256 = asset.SHA256 ?? "",
                    Size = asset.Size,
                });
                if (problem != null) return problem;
            }
            return null;
        }

        /// <summary>Un file accanto al feed: in rete, oppure nella cartella di FeedOverride per le prove.</summary>
        private async Task<byte[]> ReadFeedFile(string name)
        {
            if (feed.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || feed.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                string url = feed.TrimEnd('/') + "/" + name;
                using (var response = await Client.GetAsync(url).ConfigureAwait(true))
                {
                    if (!response.IsSuccessStatusCode) throw new HttpRequestException("HTTP " + (int)response.StatusCode + " per " + name);
                    return await response.Content.ReadAsByteArrayAsync().ConfigureAwait(true);
                }
            }
            return File.ReadAllBytes(Path.Combine(feed, name));
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
