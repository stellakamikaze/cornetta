namespace Cornetta.Core
{
    public enum SilenceAlert
    {
        None,
        /// <summary>Dall'inizio della chiamata non è mai arrivata la voce degli altri: avviso all'utente.</summary>
        OthersMuted,
        /// <summary>A metà chiamata l'audio di sistema è a zero da più di LongSilenceSeconds: solo nel log.</summary>
        LongSilence,
    }

    /// <summary>
    /// Si accorge che la voce degli altri non arriva: la regola di checkAudioArrives del Mac (RecorderModel.swift).
    /// Il flusso di silenzio tiene vivo il loopback, quindi il watchdog vede pacchetti anche quando l'audio è tutto zero.
    /// Conta solo lo zero esatto, non una soglia: un livello basso può essere una chiamata vera in cui gli altri tacciono.
    /// Un oggetto per registrazione; lo usa il thread dell'interfaccia.
    /// </summary>
    public sealed class SilenceWatch
    {
        public const double WarnAfterSeconds = 25;
        public const double LongSilenceSeconds = 120;

        private bool callSeen;
        private bool warned;
        private bool longSilence;

        /// <summary>A ogni controllo delle chiamate durante la registrazione, con il numero di app di chiamata sul microfono.</summary>
        public void NoteCallApps(int count)
        {
            if (count > 0) callSeen = true;
        }

        /// <summary>Cosa segnalare adesso. Ogni avviso parte una volta sola; quello del silenzio lungo torna dopo che l'audio è tornato.</summary>
        public SilenceAlert Check(RecordingStats stats)
        {
            if (!callSeen) return SilenceAlert.None;
            if (stats.SystemPeakRms == 0)
            {
                if (warned || stats.Seconds < WarnAfterSeconds) return SilenceAlert.None;
                warned = true;
                return SilenceAlert.OthersMuted;
            }
            if (stats.SystemSilentSeconds < LongSilenceSeconds)
            {
                longSilence = false;
                return SilenceAlert.None;
            }
            if (longSilence) return SilenceAlert.None;
            longSilence = true;
            return SilenceAlert.LongSilence;
        }
    }
}
