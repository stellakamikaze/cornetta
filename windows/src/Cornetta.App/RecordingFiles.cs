using System;
using System.Collections.Generic;
using System.IO;
using Cornetta.Core;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace Cornetta.App
{
    /// <summary>
    /// Dal WAV di lavoro (WavRecordingSink, in %LOCALAPPDATA%\Cornetta Dati\In corso) al file nella cartella delle registrazioni:
    /// AAC .m4a con Media Foundation, oppure il WAV stesso se l'AAC manca (Windows N senza Media Feature Pack).
    /// Allo stop converte; dopo un crash o uno spegnimento il recupero all'avvio fa lo stesso. Porta di RecordingFinalizer.swift.
    /// </summary>
    internal static class RecordingFiles
    {
        public const int BitRate = 160_000;

        private static bool? aacAvailable;

        /// <summary>Vero se Windows ha l'encoder AAC di Media Foundation a 48 kHz stereo.</summary>
        public static bool AacAvailable
        {
            get
            {
                if (aacAvailable.HasValue) return aacAvailable.Value;
                try
                {
                    MediaFoundationApi.Startup();
                    aacAvailable = MediaFoundationEncoder.SelectMediaType(AudioSubtypes.MFAudioFormat_AAC, WavRecordingSink.Format, BitRate) != null;
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Media Foundation non disponibile: " + ex.Message);
                    aacAvailable = false;
                }
                return aacAvailable.Value;
            }
        }

        /// <summary>Estensione del file in base all'encoder disponibile.</summary>
        public static string Extension => AacAvailable ? ".m4a" : ".wav";

        /// <summary>
        /// Salva il WAV di lavoro in <paramref name="output"/> e lo cancella. Il file definitivo compare solo a conversione finita.
        /// Se la conversione non riesce salva il WAV con lo stesso nome: l'audio non si perde. Restituisce il percorso salvato.
        /// </summary>
        public static string Finalize(string workingFile, string output)
        {
            // Dopo un crash l'intestazione non sa quanto audio c'è; dopo una chiusura normale non cambia niente.
            WavRepair.Repair(workingFile);
            string directory = Path.GetDirectoryName(output)!;
            Directory.CreateDirectory(directory);
            string name = Path.GetFileNameWithoutExtension(output);
            if (output.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase) && AacAvailable)
            {
                // Media Foundation sceglie il contenitore dall'estensione: la copia parziale finisce in .m4a, fuori dalla cartella Musica.
                string partial = Path.Combine(Path.GetDirectoryName(workingFile)!, name + ".parziale.m4a");
                string? saved = null;
                try
                {
                    File.Delete(partial);
                    using (var reader = new WaveFileReader(workingFile))
                    {
                        MediaFoundationEncoder.EncodeToAac(reader, partial, BitRate);
                    }
                    output = FileNaming.UniquePath(directory, name, ".m4a");
                    File.Move(partial, output);
                    saved = output;
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Conversione in AAC non riuscita, salvo il WAV: " + ex.Message);
                    try { File.Delete(partial); } catch (Exception) { }
                }
                if (saved != null)
                {
                    // Il .m4a è già nella cartella: un WAV bloccato (antivirus) resta in «In corso» e non si sposta accanto all'm4a.
                    // Il marcatore evita che il recupero al prossimo avvio lo salvi una seconda volta come «Nome (2).m4a».
                    try { File.Delete(workingFile); }
                    catch (Exception ex)
                    {
                        Diagnostics.Log("WAV di lavoro non cancellato: " + ex.Message);
                        try { WorkingFiles.MarkSaved(workingFile, saved); }
                        catch (Exception markEx) { Diagnostics.Log("Marcatore del WAV salvato non scritto: " + markEx.Message); }
                    }
                    return saved;
                }
            }
            output = FileNaming.UniquePath(directory, name, ".wav");
            File.Move(workingFile, output);
            return output;
        }

        /// <summary>
        /// Registrazioni interrotte da un crash, da Gestione attività o da uno spegnimento: le salva nella cartella delle
        /// registrazioni. Restituisce i nomi dei file salvati. Gira fuori dal thread dell'interfaccia.
        /// </summary>
        public static List<string> Recover(IEnumerable<string> leftovers, string recordingsDirectory)
        {
            var saved = new List<string>();
            foreach (string working in leftovers)
            {
                string name = Path.GetFileName(working);
                try
                {
                    if (WavRepair.Repair(working) <= 0)
                    {
                        // Interrotta prima del primo audio: non c'è niente da salvare.
                        File.Delete(working);
                        Diagnostics.Log("Registrazione interrotta vuota, la cancello: " + name);
                        continue;
                    }
                    Diagnostics.Log("Recupero la registrazione interrotta: " + name);
                    string output = Finalize(working, WorkingFiles.RecoveredPath(working, recordingsDirectory, Extension));
                    Diagnostics.Log("Recuperata: " + Path.GetFileName(output));
                    saved.Add(Path.GetFileName(output));
                }
                catch (Exception ex)
                {
                    Diagnostics.Log("Recupero non riuscito per " + name + ": " + ex.Message);
                }
            }
            return saved;
        }
    }
}
