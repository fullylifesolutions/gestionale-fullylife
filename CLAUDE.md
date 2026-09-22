# gestionale-fullylife

## ⚠️ Repo PUBBLICO, live su GitHub Pages — ogni push va in produzione

Questo repo è **pubblico** e pubblicato su GitHub Pages
(`fullylifesolutions.github.io/gestionale-fullylife/`). **Non esiste una copia
"solo locale"**: ogni `git push` su `main` aggiorna immediatamente la versione
che gli utenti reali stanno usando. Non c'è uno stage/preview intermedio.
Prima di committare/pushare qualunque modifica a `gestionale_fullylife.html`
o `gestionale_schema.sql`, avvisare esplicitamente l'utente che l'azione
porterà la modifica LIVE in produzione — non trattarla come un'operazione a
basso rischio solo perché "è solo un push su GitHub".

## Contesto: sistema unificato Fullylife Solutions

Questo repo è **un modulo** di un sistema più ampio a **sei domini** che ruotano
attorno a un **soggetto condiviso** (azienda o persona), secondo il modello
**"identità condivisa, dati compartimentati"**: il soggetto esiste come un solo
record (`companies` / `persons`), e ogni dominio tiene i propri dati in tabelle
satellite separate, con permessi propri. Nessuna duplicazione dell'anagrafica.

I sei domini (cornice completa, per orientarsi — non tutti attivi qui):
1. **Fatturazione** (questo repo)
2. Profilazione SPP (GESPP) — dati sanitari
3. Percezione appartenenza al gruppo (PAG)
4. Benessere psicosociale (MCS/MCSR)
5. Calendario (Calendar Work) — **integrato nel repo GESPP** (tab "Le mie
   attività", dal 2026-09-08), non in questo repo: il gestionale richiede di
   selezionare un emittente fiscale prima di mostrare qualunque schermata, e
   quella selezione richiede `can_bill()` — un consulente senza
   `puo_fatturare=true` non riuscirebbe mai a vederlo qui. GESPP invece mostra
   i suoi tab a qualunque `app_users` attivo, senza cancelli simili. A
   differenza degli altri domini della lista, questo HA già una sede reale.
6. Prenotazione slot (slot-booking)

Disciplina: **"pensiamo a sei, costruiamo a uno"**. Lo schema è pensato per
reggere tutti i domini, ma si implementa un modulo alla volta. Gli altri
domini si aggancieranno allo stesso soggetto condiviso in seguito, uno per
volta — **non sono lavoro di questo repo**.

Documento di riferimento completo: `ARCHITETTURA_SISTEMA_UNIFICATO.md`.

## Backend

**Supabase (PostgreSQL)**, unico backend condiviso da tutti i domini.

**GESPP è il riferimento architetturale esistente**: è già su Supabase, con
RLS, ruoli e audit collaudati. Le tabelle di identità (`companies`, `persons`,
`app_users`) e le funzioni helper (`is_admin()`, ecc.) vengono da lì e sono
**riusate**, non riprogettate. Anche i dati sanitari GESPP (`spp_profiles`,
`health_records`, ecc.) restano come sono, protetti dalla loro RLS.

## Lavoro attuale: SOLO il modulo gestionale fatturazione

Questo repo copre **esclusivamente** lo strato fatturazione. Migrazione da
localStorage (HTML locale) a Supabase, come estensione dello schema GESPP.

Schema di riferimento: `gestionale_schema.sql`.

Tabelle nuove di questo modulo:
- `emitter_settings` — dati fiscali dell'**emittente** (es. Bruno, Simona:
  fase 1 = una P.IVA a testa; fase 2 futura = società unica)
- `operator_emitter` — associazioni operatore↔emittente: righe che dicono
  chi può emettere sotto quale emittente
- `billing_profiles` — dati fiscali del **soggetto** cliente (satellite 1-a-1
  di `companies`/`persons`: SDI, PEC, indirizzo fatturazione)
- `billing_counters` — numerazione progressiva per emitter/tipo/anno
- `invoices` / `invoice_lines` — testata e righe di preventivo/fattura/
  proforma/nota di credito
- `service_catalog` — catalogo servizi riutilizzabile
- bucket Storage `firme` (privato) — firma emittente (`emitter/<emitter_id>.png`,
  RLS `can_use_emitter()`) e firma consulente (`consulente/<user_id>.png`, RLS
  solo `is_admin()`); vedi sezioni 12-13 di `gestionale_schema.sql` e punto 4
  sotto
- `quote_tranches` — piano di fatturazione a tranche (acconto/tranche/saldo...)
  su un preventivo esistente: percentuali variabili, `importo_imponibile` come
  fonte di verità, stato tracciato (`da_fatturare`/`proforma`/`fatturata`).
  Isolata, non tocca `invoices`/`invoice_lines`. Live (vedi punto 6 sotto).

Permesso: flag `puo_fatturare` su `app_users` (ortogonale ai ruoli esistenti
`admin`/`consulente`/`consulente_limitato`), verificato via `can_bill()`.
Chi può emettere sotto un dato emittente è deciso dalla funzione
`can_use_emitter(emitter_id)`: vero se sei admin, oppure se hai
`puo_fatturare` **e** esiste una riga in `operator_emitter` che ti associa a
quell'emittente. L'admin bypassa sempre, senza bisogno di righe in
`operator_emitter`.
Regola di sicurezza critica: poter vedere/fatturare un soggetto **non deve**
dare accesso ai suoi dati sanitari — la RLS sanitaria resta ancorata alle
tabelle sanitarie, va verificata dopo ogni cambiamento qui.

Cosa **non** cambia: la logica di generazione XML FatturaPA (frontend) resta
invariata — qui si modella *dove* stanno i dati, non *come* si genera l'XML.

## Work Calendar (dominio 5 — vive nel repo GESPP, non qui)

Migrato da un'app locale a sé (`work_calendar.html`, solo localStorage) a
tab "Le mie attività" dentro `spp_dashboard.html` (repo GESPP), sulle tabelle
`wc_*` — documentate in `gespp_1_schema.sql`/`gespp_2_funzioni_policy.sql`
di quel repo, non più in `gestionale_schema.sql`. Modello: ogni consulente ha
il proprio calendario privato (`owner_id`); un task può taggare altri
consulenti reali (`app_users`, non più profili "operatore" liberi) come
collaboratori — chi è taggato entra nel "team" di quel task e può vederlo,
leggere/scrivere un log di aggiornamenti condivisi (`wc_task_updates`),
cambiare lo stato dei subtask a cui è specificamente assegnato.
Struttura/proprietà del task restano del proprietario. Funzione centrale:
`wc_can_see_task(task_id)`. Vive brevemente su questo repo il 2026-09-08
(tab "Calendario" in `gestionale_fullylife.html`) prima di essere spostato
qui — vedi la motivazione del punto 5 della lista dei domini sopra.

### Ordine di lavoro
0. [FATTO] Decisioni architetturali + schema SQL strato fatturazione.
1. [FATTO] Migrare il gestionale da localStorage a Supabase (query al posto
   dello storage, logica XML invariata).
2. [FATTO, ma fuori da questo repo] Work Calendar integrato in GESPP (vedi
   sopra) — non più lavoro di questo repo dopo lo spostamento del 2026-09-08.
3. (Fuori da questo repo, più avanti) portale unificato con login condiviso
   tra gestionale/GESPP/slot-booking — il repo è ora pubblico e pubblicato su
   GitHub Pages (vedi avviso in cima al file), quindi questo prerequisito è
   soddisfatto; resta da fare solo il login condiviso vero e proprio.
4. [FATTO] Firma sui documenti, in due sotto-fasi indipendenti (owner/scope
   diversi, quindi bucket/path/policy diversi — non è stato fatto a metà):
   - Sotto-fase 1 — firma **emittente** sui documenti fiscali (preventivi/
     fatture/proforma): `handleFirma`/`removeFirma` in Impostazioni emittente,
     `prtDoc` scarica la firma in sessione e la incorpora inline in base64
     prima di aprire la finestra di stampa (mai un URL pubblico, a differenza
     del logo). Bucket `firme` privato, path `emitter/<emitter_id>.png`.
   - Sotto-fase 2 — firma **consulente** sugli accordi legali (oggi generati
     dal motore di template, punto 5 — non più da `printNDA`, rimosso): path
     `consulente/<user_id>.png`, accesso ristretto a solo admin (Bruno) — non
     autogestione, l'admin carica la firma di ciascun consulente da una card
     dedicata in Impostazioni. La UI legge i consulenti da `app_users`
     (ruolo consulente/admin, attivi) via la RPC `consulenti_nda_disponibili()`
     (bypassa la RLS restrittiva di `app_users`, ereditata da GESPP). Il campo
     "Titolare" (`emitter_settings.owner_id`, solo admin) collega opzionalmente
     un consulente al proprio emittente per arricchire CF/P.IVA/PEC/residenza
     nel documento quando disponibili.
   - Verificato in produzione: isolamento per-prefisso tra le policy
     `firme_emitter_*` e `firme_consulente_*` (nessuno sconfinamento
     reciproco), upload/rimozione/anteprima, generazione documenti con e
     senza firma caricata.
5. [FATTO] Motore di template per documenti legali (`legal_templates`,
   sostituisce il vecchio `printNDA` hardcoded, rimosso): tabella con
   `corpo` (HTML, segnaposto `{{...}}`) e `attori` (jsonb — chi compila il
   documento: consulente/azienda/cliente, con `firma`/`firma_layout`/
   `obbligatori` opzionali per attore). La UI deriva i select di selezione
   dagli `attori` del template scelto, nessuna struttura cablata nel
   codice. `renderLegalDoc()` sostituisce i segnaposto, valida i campi
   `obbligatori` per attore prima di generare (blocca con avviso invece di
   produrre un documento con buchi), inserisce le firme in base64. Indice
   unico parziale `(tipo) WHERE attivo` dopo un incidente reale di
   duplicazione in produzione (un INSERT rilanciato per errore). Due
   template attivi: NDA SRC (migrazione 1:1 del vecchio `printNDA`,
   verificata con test di fedeltà byte-per-byte) e NDA Generale.
6. [FATTO] Fatturazione a tranche da
   preventivo (`quote_tranches`): piano di N tranche con percentuali
   variabili, quadratura automatica (le prime N-1 = `round2(imponibile *
   percentuale/100)`, l'ultima assorbe il residuo — la somma torna sempre
   esatta al centesimo). Genera proforma/fattura per singola tranche riusando
   `saveDoc`/`ensureNumero` esistenti (`saveDoc` riceve solo un `tranche_id`
   opzionale per scrivere il legame dopo l'insert) — `genXML`/`fmtAmt`/
   `prossimo_numero`/`convDoc` non toccati. Trigger DB deferred valida che la
   somma percentuali sia 100 per piano (difesa in profondità oltre al
   controllo frontend). Piano bloccato (non più modificabile) quando almeno
   una tranche è già fatturata; le tranche ancora da fatturare restano
   comunque generabili. Collaudato in TEST: durante il collaudo è emerso un
   rischio reale di doppia fatturazione — il bottone generico "→ Fattura"
   della lista documenti (`convDoc`) non sa nulla del piano tranche e
   genererebbe un documento scollegato — risolto con un redirect al piano
   tranche per le proforma che ne fanno parte (`quote_tranches.proforma_id`),
   lasciando invariato il comportamento sulle proforma normali. Schema
   applicato sia in TEST che in produzione, verificato in produzione
   (tabella/trigger/policy presenti); UI collaudata in TEST e in produzione
   (senza emettere fatture vere) — il primo utilizzo reale su un preventivo
   diviso in tranche farà da collaudo finale sul flusso di emissione.

## Note di architettura / attenzioni

**Motore template documenti legali.** I documenti legali (NDA SRC, NDA
Generale, futuri) vivono nella tabella `legal_templates` (corpo HTML con
segnaposto `{{...}}` + `attori` in JSON), non hardcoded nel frontend. Il
vecchio `printNDA()` è stato rimosso: il motore unico è
`renderLegalDoc()`/`printLegalDoc()`. Ogni attore dichiara i propri campi
obbligatori **per template** — lo stesso campo (es. `RESP_LEGALE`) può
essere obbligatorio nel template Generale e facoltativo nell'SRC: la
validazione blocca la generazione se un campo obbligatorio dichiarato è
vuoto. Le firme dei consulenti sono immagini lette dal bucket `firme`; il
markup della firma cambia in base al layout del template
(`firma_layout:"relativo"` per i template a prosa come il Generale,
assoluto per l'SRC che è a tabella). RLS di `legal_templates`: lettura per
`attivo=true or is_admin()`, scrittura solo admin. Versionamento: un
template firmato **non va sovrascritto** — si crea una nuova versione e si
disattiva la vecchia, mai un update in place.

**STUDIO vs INDIRIZZO si compongono diversamente.** Non è un'incoerenza da
sistemare: `STUDIO` del consulente è composto da indirizzo+CAP+comune+
provincia, mentre `INDIRIZZO` dell'azienda è una semplice concatenazione/
join. Replica un comportamento storico voluto — non uniformare i due
campi.

**Fatturazione a tranche.** `quote_tranches` (`preventivo_id`, `ordine`,
`descrizione`, `percentuale`, `importo_imponibile`, `stato`, `proforma_id`,
`fattura_id`) è isolata: non ha bisogno di toccare `invoices.convertito_da`
(che resta morto, mai valorizzato dal frontend — vedi commento nello schema),
perché ha i propri FK diretti verso i documenti generati.
`importo_imponibile` è la fonte di verità una volta salvato: la generazione
del documento lo rilegge sempre fresco da DB, mai da un valore tenuto in
memoria nel frontend (`trancheRows`). Il calcolo lavora sempre su
`invoices.imponibile` (già colonna separata dal totale), mai sul totale —
nessuna assunzione "imponibile=totale" del regime forfettario è stata
introdotta. Il trigger di somma percentuali è un *constraint trigger*
`deferrable initially deferred`: necessario perché una riga vista in
isolamento non somma mai 100 finché non sono state inserite tutte le righe
del piano nella stessa transazione (un trigger immediato fallirebbe già sul
primo insert del batch).

Attenzione per chi tocca la lista documenti in futuro: una proforma con una
riga in `quote_tranches.proforma_id` NON deve mai fatturarsi dal bottone
generico "→ Fattura" (`convDoc`) — solo dal piano tranche. Il bottone generico
non aggiorna `quote_tranches`, quindi genererebbe una fattura vera, con un
numero vero, scollegata dal piano (successo davvero in collaudo, corretto con
un redirect in `diHTML()` verso `openTranche()` quando `trancheProformaMap`
risolve la proforma).
