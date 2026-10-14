using System;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace Cornetta.Core
{
    /// <summary>Dati dell'app allegati al feedback.</summary>
    public sealed class FeedbackAppInfo
    {
        public string Version { get; set; } = "";
        public string Build { get; set; } = "";
        public string Os { get; set; } = "";
        public string Arch { get; set; } = "";
        public string Microphone { get; set; } = "";
    }

    /// <summary>
    /// Corpo JSON inviato a /api/feedback. Stesso schema del Mac (Sources/Cornetta/Feedback.swift),
    /// con «os» al posto di «macOS» e in più «platform»: «windows».
    /// </summary>
    public static class FeedbackPayload
    {
        public const string Platform = "windows";

        public static string ToJson(string message, string name, string email, string? diagnostics, FeedbackAppInfo app)
        {
            var sb = new StringBuilder();
            sb.Append('{');
            Field(sb, "message", message); sb.Append(',');
            Field(sb, "name", name); sb.Append(',');
            Field(sb, "email", email); sb.Append(',');
            Field(sb, "diagnostics", diagnostics ?? ""); sb.Append(',');
            Field(sb, "platform", Platform); sb.Append(',');
            sb.Append("\"app\":{");
            Field(sb, "version", app.Version); sb.Append(',');
            Field(sb, "build", app.Build); sb.Append(',');
            Field(sb, "os", app.Os); sb.Append(',');
            Field(sb, "arch", app.Arch); sb.Append(',');
            Field(sb, "microphone", app.Microphone);
            sb.Append("}}");
            return sb.ToString();
        }

        /// <summary>Stringa JSON con le virgolette e gli escape.</summary>
        public static string Quote(string value)
        {
            var sb = new StringBuilder(value.Length + 2);
            sb.Append('"');
            foreach (char ch in value)
            {
                switch (ch)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (ch < 0x20 || ch == (char)0x2028 || ch == (char)0x2029)
                        {
                            sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            sb.Append(ch);
                        }
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        private static void Field(StringBuilder sb, string key, string value)
        {
            sb.Append(Quote(key)).Append(':').Append(Quote(value));
        }
    }

    /// <summary>Risposta del servizio: {"ok":true,"id":"…"} oppure {"ok":false,"error":"…"}.</summary>
    [DataContract]
    public sealed class FeedbackResponse
    {
        [DataMember(Name = "ok")] public bool Ok { get; set; }
        [DataMember(Name = "error")] public string? Error { get; set; }

        public const string GenericError = "Il servizio non ha risposto. Riprova tra poco.";

        public static FeedbackResponse? Parse(string json)
        {
            try
            {
                var serializer = new DataContractJsonSerializer(typeof(FeedbackResponse));
                using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
                {
                    return serializer.ReadObject(stream) as FeedbackResponse;
                }
            }
            catch (SerializationException) { return null; }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        /// <summary>Null se è andato tutto bene, altrimenti il messaggio da mostrare.</summary>
        public static string? ErrorFor(int statusCode, string body)
        {
            var decoded = Parse(body);
            if (statusCode == 200 && decoded != null && decoded.Ok) return null;
            return string.IsNullOrWhiteSpace(decoded?.Error) ? GenericError : decoded!.Error;
        }
    }
}
