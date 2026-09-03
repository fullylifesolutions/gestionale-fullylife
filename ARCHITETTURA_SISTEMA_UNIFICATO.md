# Sistema Unificato Fullylife Solutions — Architettura

Documento di riferimento per l'integrazione di **Gestionale fatturazione**, **Calendar
Work** e **GESPP** in un unico sistema multiutente su backend condiviso.

Stato: decisioni architetturali approvate. Da qui si passa allo schema SQL.

---

## 1. Principio guida

**Identità condivisa, dati compartimentati.**

Un soggetto (azienda o persona) esiste come **un solo record** nel database. I dati
che lo riguardano stanno in tabelle satellite separate per dominio, ciascuna con i
propri permessi. Nessuna duplicazione dell'anagrafica; massima separazione dei dati
sensibili.

---

## 2. Backend

Consolidamento su **Supabase (PostgreSQL)**, un unico backend per tutti e tre i
sistemi.

- GESPP: già su Supabase. Resta il riferimento architetturale (RLS, ruoli, audit).
- Calendar Work: da migrare da Firebase a Supabase.
- Gestionale fatturazione: da migrare da localStorage a Supabase.

Motivazione: dati fortemente relazionati (soggetto condiviso tra domini) → il
modello relazionale è quello giusto; il sistema più critico (GESPP, dati sanitari)
è già su Postgres con RLS collaudata; un solo backend = un solo modello di auth,
permessi, query.

---

## 3. Modello dati — i tre strati

### Strato 1 — Identità condivisa (chi è il soggetto)
Tabelle **già esistenti** nel GESPP, riusate da tutti:

- `companies` — aziende (ragione sociale, P.IVA, codice fiscale)
- `persons` — persone, con `tipo` = 'dipendente' | 'professionista'

Un cliente-azienda del gestionale = una riga `companies`.
Un cliente-persona fisica = una riga `persons` con tipo 'professionista'.
I dipendenti profilati di un'azienda cliente = righe `persons` con tipo
'dipendente' e `company_id` verso l'azienda.

### Strato 2 — Dominio fatturazione (satellite)
Tabella **nuova** `billing_profiles`, collegata 1-a-1 al soggetto:

- riferimento al soggetto (company_id OPPURE person_id)
- codice destinatario SDI (7 caratteri)
- PEC destinatario
- regime fiscale (es. RF19)
- IBAN
- indirizzo strutturato per XML (via, CAP, comune, provincia) se non già in
  `company_sites`
- eventuali altri campi fiscali del gestionale

Esiste **solo** per i soggetti che si fatturano. Vincoli a livello DB che
replicano i controlli già nel generatore XML (P.IVA valida, CAP 5 cifre, SDI 7
caratteri).

Le **fatture** vere e proprie (testata, righe, numerazione, stati) stanno in
tabelle dedicate del dominio fatturazione, collegate al soggetto e al
billing_profile.

### Strato 3 — Dominio sanitario (satellite, GESPP esistente)
Tabelle **già esistenti**, invariate: `spp_profiles`, `health_consents`,
`health_records`, `self_reports`, `meetings`. Collegate allo stesso soggetto
(`person_id`). Protette dalla RLS GESPP già collaudata.

### I sei domini del sistema (cornice completa)
Il sistema unificato ha SEI domini che ruotano attorno al soggetto condiviso.
Tutti **presuppongono un soggetto che già esiste** (persona in percorso con
Fullylife: interno di un'azienda cliente o professionista già seguito) e lo
osservano/servono da angolazioni diverse. Tutti seguono "identità condivisa,
dati compartimentati": stesso soggetto, dati e permessi propri per dominio.

1. **Fatturazione** (gestionale) — dati fiscali, fatture. Accesso:
   `puo_fatturare`. Repo: da creare (oggi è HTML locale).
2. **Profilazione SPP** (GESPP) — sei assi, dati sanitari. Accesso: consulenti,
   RLS GDPR severa. Repo: GESPP (Supabase).
3. **Percezione appartenenza al gruppo** (PAG) — monitoraggio, stesse persone.
   Repo: PAG1, PAG-C, PAG2.
4. **Benessere psicosociale** (MCS/MCSR) — monitoraggio, stesse persone.
   Repo: MCS, MCSR.
5. **Calendario** (Calendar Work) — task/operatori. Da migrare da Firebase.
6. **Prenotazione slot** (slot-booking) — appuntamenti per persone GIÀ in
   percorso (interni di aziende clienti o professionisti già seguiti). Il
   soggetto esiste già: la prenotazione è legata a un soggetto anagrafato, non
   lo genera. Da migrare da Firebase.

### Disciplina di lavoro: "pensiamo a sei, costruiamo a uno"
La cornice contempla tutti e sei i domini fin dal disegno (così lo schema non va
rifatto). L'IMPLEMENTAZIONE procede un modulo alla volta, per non restare
bloccati a progettare un sistema enorme prima di mettere online un pezzo.
Primo modulo: **gestionale fatturazione** (quello che ha innescato il progetto).
Gli altri si agganciano al soggetto condiviso in seguito, uno per volta.

---

## 3-bis. Emittenti e transizione societaria

**Fase 1 (attuale): N operatori, ognuno con la propria P.IVA.**
- `emitter_settings` ha una riga per emittente (Bruno, Simona, ...).
- Ogni emittente ha numerazione progressiva indipendente
  (`billing_counters` unique per emitter_id/tipo/anno).
- Autorizzazione a emettere: funzione `can_use_emitter(emitter_id)` =
  "sei l'owner OPPURE sei admin".
  - Simona (login proprio, autonoma) → emette solo come sé stessa.
  - Bruno (admin) → può emettere anche a nome di altri (es. Simona).
- Ogni fattura registra due cose distinte:
  - `emitter_id` = sotto quale P.IVA esce (di chi è il documento fiscale)
  - `created_by` = chi l'ha materialmente creata (tracciabilità:
    "Bruno per conto di Simona")
- Visibilità: admin vede tutto; gli altri vedono solo le fatture degli
  emittenti che possono usare (RLS via `can_use_emitter`).

**Fase 2 (futura): assetto societario, numerazione unica.**
- Non è una fusione di numerazioni: è un NUOVO soggetto fiscale (società,
  nuova P.IVA) con un nuovo `emitter_id` i cui contatori partono da 0.
- I registri personali di fase 1 si chiudono; il nuovo registro società parte.
- La numerazione diventa unica perché tutti emettono sotto lo stesso
  emitter_id (società): il vincolo unique(emitter_id,tipo,anno) produce
  automaticamente un contatore condiviso.
- Modifica prevista a `can_use_emitter`: aggiungere il caso "emittente =
  società → chiunque abbia puo_fatturare può usarlo". Estensione minima,
  lo schema regge senza ristrutturazioni.

---

## 4. Permessi e ruoli

Ruoli esistenti (invariati): `admin`, `consulente`, `consulente_limitato`.

**Accesso alla fatturazione = permesso ortogonale, non un nuovo ruolo.**
Flag `puo_fatturare` (booleano) su `app_users`. Si combina con qualsiasi ruolo:

- `admin` + puo_fatturare → Bruno
- futuro amministrativo → ruolo che NON vede il sanitario + puo_fatturare
- `consulente` senza flag → lavora sui soggetti ma non fattura

### Regola di sicurezza critica (GDPR)
Poter vedere un soggetto in `companies`/`persons` per fatturarlo **non deve**
dare alcun accesso ai dati sanitari di quel soggetto. La RLS sui dati sanitari
resta ancorata alle tabelle sanitarie (funzione `can_access_person`, esclusione
`consulente_limitato`, vincolo consenso attivo) e va verificata dopo
l'integrazione: aprire il soggetto alla fatturazione non deve aprire crepe verso
`health_records`.

---

## 5. Cosa NON cambia

- Tutta la logica di generazione XML FatturaPA del gestionale (IdTrasmittente=CF
  per ditta individuale, namespace, DatiBollo, sanitizzazione Latin-1, controlli
  SDI/CAP/P.IVA). È lato generazione documento, indipendente da dove stanno i
  dati. Si migra il *dove leggo i dati*, non *come genero l'XML*.
- L'impianto RLS/ruoli/audit del GESPP.
- La pagina pubblica di consenso e la Edge Function (indipendenti dal DB).

---

## 6. Ordine di lavoro

0. **[FATTO]** Decisioni architetturali (questo documento).
1. Progettare lo schema SQL dello strato fatturazione (billing_profiles +
   fatture) come estensione dello schema GESPP.
2. Migrare il gestionale da localStorage a Supabase (sostituire storage con
   query; logica XML invariata).
3. Migrare Calendar Work da Firebase a Supabase.
4. Portale unificato con login unico e viste per ruolo/permesso.

Strumento consigliato dalla fase 1: **Claude Code** sul repository GitHub
(più file coordinati + versionamento Git).
