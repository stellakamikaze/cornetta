using System;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Cornetta.Core;

namespace Cornetta.App
{
    /// <summary>
    /// Telemetria di funzionamento: pochi eventi a lista chiusa verso il servizio di Cornetta, per sapere se
    /// l'app funziona sui PC di chi la usa. Mai audio, testi, nomi di file, dispositivi o contatti.
    /// Si spegne dal menu («Invia dati di funzionamento»): spenta, l'id di installazione si cancella.
    /// Cosa parte e cosa no lo spiega https://cornetta.stellakamikaze.org/privacy/.
    /// </summary>
    internal static class Telemetry
    {
        public const string Url = AppInfo.ServiceUrl + "/api/t";
        private static readonly HttpClient Client = CreateClient();

        private static HttpClient CreateClient()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            return new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        }

        public static bool IsEnabled
        {
            get => Settings.TelemetryEnabled;
            set
            {
                Settings.TelemetryEnabled = value;
                if (!value) Settings.TelemetryInstallId = "";
                Diagnostics.Log("Telemetria " + (value ? "accesa" : "spenta"));
            }
        }

        /// <summary>Id casuale dell'installazione: serve a contare le installazioni attive, non dice chi sei.</summary>
        private static string InstallId
        {
            get
            {
                string id = Settings.TelemetryInstallId;
                if (id.Length > 0) return id;
                id = Guid.NewGuid().ToString("D");
                Settings.TelemetryInstallId = id;
                return id;
            }
        }

        private static string Os
        {
            get
            {
                var v = Environment.OSVersion.Version;
                return "Windows " + v.Major + "." + v.Minor + "." + v.Build;
            }
        }

        /// <summary>All'avvio dell'app: «avvio», più «aggiornamento» se la versione è cambiata dall'ultima volta.</summary>
        public static void AppLaunched()
        {
            string previous = Settings.TelemetryLastVersion;
            Settings.TelemetryLastVersion = AppInfo.Version;
            Send("avvio");
            if (previous.Length > 0 && previous != AppInfo.Version) Send("aggiornamento");
        }

        public static void Send(string evento, string outcome = "", string code = "", double? seconds = null)
        {
            // Le build di prova della CI (0.0.<run>) non contano.
            if (!IsEnabled || AppInfo.Version == "dev" || AppInfo.Version.StartsWith("0.0.", StringComparison.Ordinal)) return;
            string arch = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
            string json = TelemetryPayload.ToJson(evento, AppInfo.Version, Os, arch, InstallId, outcome, code, seconds);
            // Senza rete l'evento si perde: non si ritenta e non si accumula niente sul disco.
            Task.Run(async () =>
            {
                try
                {
                    using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
                    using (var response = await Client.PostAsync(Url, content).ConfigureAwait(false))
                    {
                        if (response.StatusCode != HttpStatusCode.OK) Diagnostics.Log("Telemetria non inviata (" + evento + "): HTTP " + (int)response.StatusCode);
                    }
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Telemetria non inviata (" + evento + "): " + ex.GetBaseException().Message);
                }
            });
        }
    }
}
