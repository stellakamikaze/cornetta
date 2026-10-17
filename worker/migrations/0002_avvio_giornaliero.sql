-- Un solo «avvio» per installazione al giorno: il Worker scrive il giorno UTC (AAAA-MM-GG) negli avvii
-- e inserisce con INSERT OR IGNORE, così un client che riapre l'app a raffica non gonfia la tabella.
-- Le righe vecchie restano con giorno NULL: in un indice unico i NULL non si scontrano, niente si cancella.
-- Va applicata PRIMA del deploy del Worker che scrive la colonna (docs/SERVIZIO.md).
ALTER TABLE eventi ADD COLUMN giorno TEXT;
CREATE UNIQUE INDEX eventi_avvio_giorno ON eventi (installazione, giorno) WHERE evento = 'avvio';
