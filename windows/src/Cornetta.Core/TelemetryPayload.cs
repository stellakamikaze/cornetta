using System;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Cornetta.Core
{
    /// <summary>
    /// Telemetria di funzionamento: campi ridotti a valori che non dicono niente di chi usa l'app.
    /// Stesse forme del Mac (Sources/CornettaCore/TelemetryFields.swift). Il servizio rifiuta tutto ciò che
    /// sta fuori lista (worker/src/index.js, validateTelemetry).
    /// </summary>
    public static class TelemetryPayload
    {
        public const string Platform = "windows";

        /// <summary>La durata di una registrazione in fasce larghe, mai al secondo.</summary>
        public static string DurationBucket(double seconds)
        {
            if (seconds < 60) return "<1m";
            if (seconds < 300) return "1-5m";
            if (seconds < 900) return "5-15m";
            if (seconds < 3600) return "15-60m";
            return ">60m";
        }

        /// <summary>Un'eccezione ridotta a tipo e HRESULT («avvio.COMException_88890008»): il messaggio non parte mai.</summary>
        public static string ErrorCode(Exception error, string prefix = "")
        {
            var inner = error.GetBaseException();
            string raw = (prefix.Length > 0 ? prefix + "." : "") + inner.GetType().Name + "_" + inner.HResult.ToString("X8", CultureInfo.InvariantCulture);
            return Clean(raw);
        }

        /// <summary>Solo lettere, cifre, «_», «.» e «-», al massimo 60 caratteri.</summary>
        public static string Clean(string raw)
        {
            var chars = raw.Where(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-');
            string clean = new string(chars.ToArray());
            return clean.Length > 60 ? clean.Substring(0, 60) : clean;
        }

        public static string ToJson(string evento, string version, string os, string arch, string installId,
            string outcome = "", string code = "", double? seconds = null)
        {
            var sb = new StringBuilder("{");
            Field(sb, "evento", evento);
            Field(sb, "piattaforma", Platform);
            Field(sb, "versione", version);
            Field(sb, "os", os);
            Field(sb, "arch", arch);
            Field(sb, "installazione", installId);
            if (outcome.Length > 0) Field(sb, "esito", outcome);
            if (code.Length > 0) Field(sb, "codice", Clean(code));
            if (seconds.HasValue) Field(sb, "durata", DurationBucket(seconds.Value));
            sb.Length--;   // l'ultima virgola
            sb.Append('}');
            return sb.ToString();
        }

        private static void Field(StringBuilder sb, string key, string value)
        {
            sb.Append(FeedbackPayload.Quote(key)).Append(':').Append(FeedbackPayload.Quote(value)).Append(',');
        }
    }
}
