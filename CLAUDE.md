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
