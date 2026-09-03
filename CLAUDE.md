# gestionale-fullylife

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
5. Calendario (Calendar Work)
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

### Ordine di lavoro
0. [FATTO] Decisioni architetturali + schema SQL strato fatturazione.
1. Migrare il gestionale da localStorage a Supabase (query al posto dello
   storage, logica XML invariata).
2. (Fuori da questo repo, più avanti) migrare Calendar Work, poi portale
   unificato.
