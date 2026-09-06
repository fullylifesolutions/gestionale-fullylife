# Test di non-regressione genXML()

Verifica che `genXML()` in `gestionale_fullylife.html` produca lo stesso
output XML FatturaPA a parità di dati in ingresso — cioè che nessuna
modifica futura al frontend alteri la logica di generazione (che deve
restare invariata per contratto, vedi CLAUDE.md: "qui si modella dove
stanno i dati, non come si genera l'XML").

## Perché non è un test automatico

Questo repo non ha un framework di test né un ambiente headless: è un
singolo file HTML/JS senza build. `genXML()` gira nel browser e legge dati
da Supabase in tempo reale. Il confronto qui è quindi **manuale mirato**:
un fixture di dati fissi + un output di riferimento salvato + una procedura
di ridiff, non un test lanciabile da riga di comando.

## Il fixture

I dati di emittente/cliente/riga usati per generare `reference_output.xml`
sono descritti in `fixture.md`. Sono scelti per essere semplici e
riproducibili in qualunque progetto Supabase di test.

## Come rilanciare il confronto

1. Nel progetto Supabase di test, ricrea (o riusa se esiste ancora) un
   emittente e una fattura con **esattamente** i valori descritti in
   `fixture.md`.
2. Emetti il documento (Salva & inviato) se non lo è già — da qui in poi
   il numero assegnato non cambia più, anche riaprendo il documento.
3. Genera l'XML dal pulsante "XML" sul documento.
4. Confronta il file scaricato con `reference_output.xml`:
   - **Devono essere identici** su tutti i campi tranne quelli elencati
     sotto come "attesi diversi".
   - Un modo pratico: `diff nuovo_file.xml test/xml_regression/reference_output.xml`.

### Campi attesi diversi tra due generazioni (non sono regressioni)

- `<ProgressivoInvio>` e `<Numero>`: dipendono dal contatore
  `billing_counters` al momento dell'emissione — sono identici solo se si
  riapre **lo stesso documento già emesso** descritto in `fixture.md`
  (rigenerare l'XML di un documento esistente non richiama mai
  `prossimo_numero()` di nuovo, quindi il numero resta lo stesso). Se
  invece si ricrea il documento da zero in un progetto diverso, questi due
  campi rifletteranno il contatore di quel progetto — normale, non un bug.
- `<Data>`: solo se il fixture non fissa esplicitamente la data del
  documento.

Qualunque altra differenza (dati anagrafici emittente/cliente, importi,
aliquota, namespace, struttura XML, arrotondamenti) è una regressione reale
da investigare prima di rilasciare la modifica che l'ha causata.

## Quando aggiornare `reference_output.xml`

Solo quando si decide **deliberatamente** di cambiare la logica di
generazione XML (fuori scope per la migrazione localStorage→Supabase, ma
può succedere in futuro per altri motivi, es. aggiornamento normativo
FatturaPA). In quel caso: rigenerare il riferimento, aggiornare la data in
`fixture.md`, e spiegare nel commit perché l'output è cambiato
intenzionalmente.
