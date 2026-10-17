using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;

namespace Cornetta.Core
{
    /// <summary>Un pacchetto del feed Velopack (releases.win.json): quello che serve per riconoscerlo.</summary>
    public sealed class FeedAsset
    {
        public string FileName { get; set; } = "";
        public string Sha1 { get; set; } = "";
        public string Sha256 { get; set; } = "";
        public long Size { get; set; }
    }

    /// <summary>
    /// Firma del feed degli aggiornamenti Windows. windows/tools/sign-feed.py firma releases.win.json con
    /// ECDSA P-256 e SHA-256 e scrive releases.win.json.sig: la firma r||s (64 byte) in base64, su una riga.
    /// L'app verifica la firma con la chiave pubblica incorporata (AppInfo.UpdateFeedPublicKey) e accetta solo
    /// pacchetti che il feed firmato elenca con lo stesso nome, peso e hash: Velopack poi controlla l'hash
    /// del file scaricato. Senza firma valida l'app non si aggiorna.
    ///
    /// Perché ECDSA P-256 e non Ed25519: .NET Framework 4.8 ha ECDSA P-256 nel sistema (CNG), Ed25519 no.
    /// Ed25519 vorrebbe BouncyCastle, alcuni MB di codice di terzi da tenere aggiornato dentro il percorso
    /// che decide cosa installare. Come generare la chiave: docs/SERVIZIO.md, «Chiave del feed Windows».
    /// </summary>
    public static class FeedSignature
    {
        /// <summary>Valore della chiave pubblica finché non c'è quella vera: con questo nessun feed passa.</summary>
        public const string Placeholder = "DA-GENERARE";

        /// <summary>Null se la firma è valida, altrimenti il motivo (per il log).</summary>
        public static string? Verify(byte[] feed, string signatureText, string publicKeyHex)
        {
            byte[]? key = ParseHex(publicKeyHex ?? "");
            if (key == null || key.Length != 64) return "chiave pubblica del feed non impostata o non valida";
            byte[] signature;
            try { signature = Convert.FromBase64String((signatureText ?? "").Trim()); }
            catch (FormatException) { return "firma del feed illeggibile"; }
            if (signature.Length != 64) return "firma del feed di lunghezza sbagliata";
            try
            {
                var parameters = new ECParameters
                {
                    Curve = ECCurve.NamedCurves.nistP256,
                    Q = new ECPoint { X = key.Take(32).ToArray(), Y = key.Skip(32).ToArray() },
                };
                // ECDsa.Create() più ImportParameters: le due chiamate stanno in netstandard2.0 e in .NET Framework 4.8 (CNG).
                using (var ecdsa = ECDsa.Create())
                {
                    ecdsa.ImportParameters(parameters);
                    return ecdsa.VerifyData(feed, signature, HashAlgorithmName.SHA256) ? null : "firma del feed non valida";
                }
            }
            catch (CryptographicException ex)
            {
                return "verifica della firma non riuscita: " + ex.Message;
            }
        }

        /// <summary>I pacchetti elencati nel feed firmato. Null se il JSON non si legge.</summary>
        public static List<FeedAsset>? ParseAssets(byte[] feed)
        {
            int start = feed.Length >= 3 && feed[0] == 0xEF && feed[1] == 0xBB && feed[2] == 0xBF ? 3 : 0;
            try
            {
                var serializer = new DataContractJsonSerializer(typeof(FeedDocument));
                using (var stream = new MemoryStream(feed, start, feed.Length - start))
                {
                    var doc = serializer.ReadObject(stream) as FeedDocument;
                    if (doc?.Assets == null) return null;
                    return doc.Assets.Select(a => new FeedAsset
                    {
                        FileName = a.FileName ?? "",
                        Sha1 = a.SHA1 ?? "",
                        Sha256 = a.SHA256 ?? "",
                        Size = a.Size,
                    }).ToList();
                }
            }
            catch (SerializationException) { return null; }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        /// <summary>Null se il feed firmato elenca il pacchetto con lo stesso nome, peso e hash.</summary>
        public static string? Covers(IEnumerable<FeedAsset> signed, FeedAsset wanted)
        {
            var entry = signed.FirstOrDefault(a => string.Equals(a.FileName, wanted.FileName, StringComparison.OrdinalIgnoreCase));
            if (entry == null) return wanted.FileName + " non è nel feed firmato";
            if (entry.Size != wanted.Size) return wanted.FileName + ": peso diverso da quello firmato";
            if (entry.Sha256.Length > 0)
            {
                return string.Equals(entry.Sha256, wanted.Sha256, StringComparison.OrdinalIgnoreCase)
                    ? null : wanted.FileName + ": SHA-256 diverso da quello firmato";
            }
            if (entry.Sha1.Length > 0)
            {
                return string.Equals(entry.Sha1, wanted.Sha1, StringComparison.OrdinalIgnoreCase)
                    ? null : wanted.FileName + ": SHA-1 diverso da quello firmato";
            }
            return wanted.FileName + ": il feed firmato non ha l'hash";
        }

        private static byte[]? ParseHex(string hex)
        {
            if (hex.Length % 2 != 0) return null;
            var bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
            {
                if (!byte.TryParse(hex.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out bytes[i])) return null;
            }
            return bytes;
        }
    }

    /// <summary>releases.win.json come lo scrive vpk: qui servono solo questi campi, gli altri si ignorano.</summary>
    [DataContract]
    internal sealed class FeedDocument
    {
        [DataMember(Name = "Assets")] public List<FeedAssetJson>? Assets { get; set; }
    }

    [DataContract]
    internal sealed class FeedAssetJson
    {
        [DataMember(Name = "FileName")] public string? FileName { get; set; }
        [DataMember(Name = "SHA1")] public string? SHA1 { get; set; }
        [DataMember(Name = "SHA256")] public string? SHA256 { get; set; }
        [DataMember(Name = "Size")] public long Size { get; set; }
    }
}
