using System;

namespace Cornetta.Core
{
    /// <summary>
    /// Mette i campioni di una sorgente (microfono o audio di sistema) sulla linea del tempo comune.
    ///
    /// Le posizioni sono in frame a 48 kHz dall'avvio della registrazione e le decide l'orologio:
    /// - un blocco che arriva in orario si accoda al precedente, senza scatti;
    /// - se la sorgente tace (il loopback WASAPI non manda pacchetti quando nessuno suona) il buco
    ///   diventa silenzio, e il blocco successivo cade nella posizione giusta;
    /// - se la sorgente corre avanti rispetto all'orologio (deriva fra i due dispositivi),
    ///   scarta i campioni in eccesso e si riallinea.
    /// Così microfono e sistema restano allineati anche dopo minuti di silenzio.
    /// Chi legge deve stare indietro rispetto all'orologio più di GapToleranceFrames (il mixer sta a 350 ms):
    /// altrimenti un blocco che arriva dopo un silenzio viene accodato invece che messo al suo posto.
    /// Thread safe: le catture scrivono dai loro thread, il mixer legge dal suo.
    /// </summary>
    public sealed class CaptureTimeline
    {
        private readonly object gate = new object();
        private float[] buffer;
        private long readFrame;   // posizione del primo frame in buffer
        private int frameCount;   // frame presenti in buffer

        public CaptureTimeline(int channels, int sampleRate = 48000)
        {
            Channels = channels;
            SampleRate = sampleRate;
            buffer = new float[sampleRate * channels];
            GapToleranceFrames = sampleRate * 120 / 1000;
            AheadToleranceFrames = sampleRate * 80 / 1000;
        }

        public int Channels { get; }
        public int SampleRate { get; }
        /// <summary>Oltre questo ritardo rispetto all'orologio il buco diventa silenzio.</summary>
        public long GapToleranceFrames { get; set; }
        /// <summary>Oltre questo anticipo rispetto all'orologio la sorgente viene riallineata.</summary>
        public long AheadToleranceFrames { get; set; }

        /// <summary>Quante volte un silenzio della sorgente è stato riempito di zeri.</summary>
        public int GapsFilled { get; private set; }
        /// <summary>Frame scartati per riallineare la sorgente o perché arrivati troppo tardi.</summary>
        public long FramesDropped { get; private set; }
        /// <summary>Frame ricevuti dalla sorgente.</summary>
        public long FramesReceived { get; private set; }

        public long WritePosition
        {
            get { lock (gate) return readFrame + frameCount; }
        }

        /// <summary>
        /// Aggiunge un blocco arrivato quando l'orologio segnava <paramref name="arrivalFrame"/>:
        /// l'ultimo campione del blocco corrisponde a quell'istante.
        /// </summary>
        public void Write(long arrivalFrame, float[] interleaved)
        {
            int frames = interleaved.Length / Channels;
            if (frames == 0) return;
            lock (gate)
            {
                FramesReceived += frames;
                long expectedStart = arrivalFrame - frames;
                long writePos = readFrame + frameCount;
                int skip = 0;
                if (expectedStart - writePos > GapToleranceFrames)
                {
                    AppendSilence((int)Math.Min(expectedStart - writePos, int.MaxValue / Channels));
                    GapsFilled++;
                }
                else if (writePos - expectedStart > AheadToleranceFrames)
                {
                    long excess = writePos - expectedStart;
                    skip = (int)Math.Min(excess, frames);
                    FramesDropped += skip;
                }
                if (skip < frames) Append(interleaved, skip, frames - skip);
            }
        }

        /// <summary>
        /// Restituisce i frame fino alla posizione <paramref name="upTo"/> (esclusa) e li toglie dal buffer.
        /// Dove la sorgente non ha dati, silenzio.
        /// </summary>
        public float[] Read(long upTo)
        {
            lock (gate)
            {
                int frames = (int)Math.Max(0, upTo - readFrame);
                var output = new float[frames * Channels];
                int available = Math.Min(frames, frameCount);
                Array.Copy(buffer, 0, output, 0, available * Channels);
                Consume(available);
                readFrame = Math.Max(readFrame, upTo);
                return output;
            }
        }

        private void Consume(int frames)
        {
            if (frames <= 0) return;
            int remaining = frameCount - frames;
            if (remaining > 0) Array.Copy(buffer, frames * Channels, buffer, 0, remaining * Channels);
            frameCount = remaining;
            readFrame += frames;
        }

        private void AppendSilence(int frames)
        {
            EnsureCapacity(frameCount + frames);
            Array.Clear(buffer, frameCount * Channels, frames * Channels);
            frameCount += frames;
        }

        private void Append(float[] source, int startFrame, int frames)
        {
            // I campioni prima della posizione già letta sono arrivati troppo tardi: si scartano.
            if (frames <= 0) return;
            EnsureCapacity(frameCount + frames);
            Array.Copy(source, startFrame * Channels, buffer, frameCount * Channels, frames * Channels);
            frameCount += frames;
        }

        private void EnsureCapacity(int frames)
        {
            int needed = frames * Channels;
            if (needed <= buffer.Length) return;
            int size = buffer.Length;
            while (size < needed) size *= 2;
            Array.Resize(ref buffer, size);
        }
    }
}
