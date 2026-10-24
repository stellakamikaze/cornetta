using System;

namespace Cornetta.Core
{
    /// <summary>Quale cattura riavviare quando Windows cambia un dispositivo predefinito (Recorder.OnDefaultDeviceChanged).</summary>
    public enum DeviceRestart { None, Microphone, CallOutput, GeneralOutput }

    public static class DeviceChange
    {
        /// <summary>
        /// Windows notifica ogni ruolo con una chiamata a parte. Il microfono segue solo il ruolo delle chiamate, l'uscita delle
        /// chiamate il ruolo Comunicazioni, la seconda uscita il predefinito generale (Console): un cambio del solo predefinito
        /// generale (monitor HDMI, pannello Volume) non interrompe la voce degli altri.
        /// </summary>
        public static DeviceRestart For(bool capture, bool callRole, bool consoleRole)
        {
            if (capture) return callRole ? DeviceRestart.Microphone : DeviceRestart.None;
            if (callRole) return DeviceRestart.CallOutput;
            return consoleRole ? DeviceRestart.GeneralOutput : DeviceRestart.None;
        }

        /// <summary>
        /// Dopo un cambio del predefinito generale: vero se l'uscita delle chiamate scelta adesso non è quella che il loopback
        /// ascolta. Succede quando manca il ruolo Comunicazioni e l'uscita delle chiamate è proprio il predefinito generale.
        /// </summary>
        public static bool CallOutputMoved(string? currentCallOutputId, string? capturedId) =>
            !string.Equals(currentCallOutputId, capturedId, StringComparison.Ordinal);
    }
}
