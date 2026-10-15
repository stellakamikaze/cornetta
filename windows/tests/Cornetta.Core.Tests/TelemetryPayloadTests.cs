using System;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Cornetta.Core;
using Xunit;

namespace Cornetta.Core.Tests
{
    // I campi devono stare nelle forme che il servizio accetta (worker/src/index.js, validateTelemetry).
    public class TelemetryPayloadTests
    {
        private const string Id = "0f8fad5b-d9cb-469f-a165-70867728950e";

        [Fact]
        public void DurationsAreBroadBuckets()
        {
            Assert.Equal("<1m", TelemetryPayload.DurationBucket(12));
            Assert.Equal("1-5m", TelemetryPayload.DurationBucket(60));
            Assert.Equal("5-15m", TelemetryPayload.DurationBucket(899));
            Assert.Equal("15-60m", TelemetryPayload.DurationBucket(1800));
            Assert.Equal(">60m", TelemetryPayload.DurationBucket(7200));
        }

        [Fact]
        public void ErrorCodeNeverCarriesTheMessage()
        {
            var error = new COMException(@"Impossibile aprire C:\Users\mario\Music\Chiamata con Anna.m4a", unchecked((int)0x88890008));
            string code = TelemetryPayload.ErrorCode(error, "avvio");
            Assert.Equal("avvio.COMException_88890008", code);
            Assert.DoesNotContain("mario", code);
            Assert.Matches("^[A-Za-z0-9_.-]{0,60}$", code);
        }

        [Fact]
        public void JsonHasOnlyTheAllowedFields()
        {
            string json = TelemetryPayload.ToJson("registrazione", "0.3.0", "Windows 10.0.26100", "x64", Id, "errore", "interrotta", 200);
            Assert.Equal("{\"evento\":\"registrazione\",\"piattaforma\":\"windows\",\"versione\":\"0.3.0\",\"os\":\"Windows 10.0.26100\",\"arch\":\"x64\",\"installazione\":\"" + Id + "\",\"esito\":\"errore\",\"codice\":\"interrotta\",\"durata\":\"1-5m\"}", json);
            string minimal = TelemetryPayload.ToJson("avvio", "0.3.0", "Windows 10.0.26100", "x64", Id);
            Assert.DoesNotContain("esito", minimal);
            Assert.EndsWith("\"}", minimal);
        }

        [Fact]
        public void CodeIsCleanedAndCut()
        {
            string json = TelemetryPayload.ToJson("avvio", "0.3.0", "", "", Id, "", "spazi e:simboli/" + new string('x', 90));
            var code = Regex.Match(json, "\"codice\":\"([^\"]*)\"").Groups[1].Value;
            Assert.Matches("^[A-Za-z0-9_.-]{1,60}$", code);
        }
    }
}
