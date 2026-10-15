-- Telemetria di funzionamento di Cornetta: un evento per riga, niente che identifichi una persona.
-- installazione è un id casuale generato dall'app, che cambia se l'utente spegne la telemetria.
CREATE TABLE eventi (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,             -- ISO 8601 UTC, arrivo al Worker
  evento TEXT NOT NULL,         -- avvio | registrazione | trascrizione | aggiornamento
  piattaforma TEXT NOT NULL,    -- macos | windows
  versione TEXT NOT NULL,
  os TEXT NOT NULL DEFAULT '',
  arch TEXT NOT NULL DEFAULT '',
  paese TEXT NOT NULL DEFAULT '',
  installazione TEXT NOT NULL,
  esito TEXT NOT NULL DEFAULT '',
  codice TEXT NOT NULL DEFAULT '',
  durata TEXT NOT NULL DEFAULT ''
);
CREATE INDEX eventi_ts ON eventi (ts);
CREATE INDEX eventi_installazione ON eventi (installazione, ts);
