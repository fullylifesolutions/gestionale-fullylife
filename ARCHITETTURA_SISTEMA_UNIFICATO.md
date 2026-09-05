# Sistema Unificato Fullylife Solutions — Architettura

Documento di riferimento per l'integrazione di **Gestionale fatturazione**, **Calendar
Work** e **GESPP** in un unico sistema multiutente su backend condiviso.

Stato: gestionale fatturazione migrato da localStorage a Supabase (auth,
emittente, catalogo, clienti, documenti/fatture, generazione XML). Vedi
sezione 7 per le lezioni riusabili quando si affronterà il prossimo dominio.

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
1. **[FATTO]** Schema SQL dello strato fatturazione (billing_profiles +
   fatture) come estensione dello schema GESPP.
2. **[FATTO]** Migrare il gestionale da localStorage a Supabase (storage
   sostituito con query; logica XML invariata) — vedi sezione 7 per le
   lezioni riusabili emerse in questo passaggio.
3. Migrare Calendar Work da Firebase a Supabase.
4. Portale unificato con login unico e viste per ruolo/permesso.

Strumento consigliato dalla fase 1: **Claude Code** sul repository GitHub
(più file coordinati + versionamento Git).

---

## 7. Lezioni dal Modulo 1 (gestionale fatturazione) per i prossimi domini

Durante la migrazione del gestionale sono emersi tre pattern che vale la
pena riusare quando si affronterà il prossimo dominio (Calendar Work o
altro), invece di riscoprirli da capo. Sono nati da bug reali trovati in
sessione, non da teoria.

### 7.1 Policy RLS additive sulle tabelle condivise

Un dominio nuovo che ha bisogno di leggere/scrivere `companies`/`persons`
(o qualunque altra tabella non di sua proprietà, appartenente a un altro
dominio) **non deve mai modificare le policy RLS esistenti** di quella
tabella. Va invece aggiunta una policy nuova, scoped al proprio criterio
di accesso (es. `can_use_emitter()`, o l'equivalente del nuovo dominio).

Le policy Postgres per lo stesso comando (select/insert/update/delete) si
combinano in **OR**: una policy aggiuntiva allarga l'accesso solo per chi
soddisfa il suo criterio, senza mai restringere o toccare l'accesso già
concesso dalle policy di altri domini. Verificato concretamente nel
gestionale: `companies`/`persons` avevano già `companies_read`/
`persons_insert` ecc. per i consulenti GESPP; sono state aggiunte
`companies_billing_select/insert/update` e `persons_billing_*` (quest'ultime
scoped anche a `tipo='professionista'`, per non aprire accesso ai
`dipendente` che appartengono al dominio di profilazione aziendale) senza
toccare una riga delle policy GESPP.

**Corollario**: non aggiungere mai una policy `DELETE` per un dominio che
non possiede il soggetto. Cancellare un'identità condivisa è un'operazione
cross-dominio (rischia di portarsi via dati di un altro dominio collegati
allo stesso `company_id`/`person_id`) — resta un'operazione admin via SQL
diretto, non un bottone in nessuna delle interfacce di dominio.

### 7.2 Verificare le RLS reali PRIMA di scrivere il piano, mai assumerle

Due dei tre bug di sicurezza/permessi seri trovati in questa migrazione
(su `emitter_settings` nel Modulo 1, su `companies`/`persons` nel Modulo 3)
erano buchi RLS non documentati da nessuna parte — solo la lettura diretta
di `pg_policies` li ha fatti emergere, non la documentazione né la sola
lettura del codice applicativo. Prima di progettare come un nuovo dominio
si aggancia a una tabella condivisa, query da lanciare sempre:

```sql
select tablename, policyname, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename in ('nome_tabella_1','nome_tabella_2');
```

Non fidarsi di "dovrebbe già funzionare perché è nello schema" — verificarlo
impersonando un utente reale del nuovo dominio (tecnica: `set local role
authenticated` + `request.jwt.claims`, vedi promemoria RLS del gestionale).

### 7.3 Snapshot vs riferimento vivo per i dati che devono restare storici

Quando un dominio produce un documento/evento che deve restare invariato
nel tempo anche se l'anagrafica del soggetto cambia dopo (una fattura, ma
lo stesso vale per un verbale, un referto, una prenotazione confermata),
la tabella satellite del dominio deve contenere **entrambe** le cose:

- un riferimento vivo al soggetto (`company_id`/`person_id`), utile per
  aggregare/navigare ("tutti i documenti di questo cliente");
- uno **snapshot** dei campi che contano al momento dell'evento (nome,
  indirizzo, ecc.), copiati nella riga stessa — mai un JOIN live per i dati
  mostrati/stampati.

Nel gestionale: `invoices` ha sia `company_id`/`person_id` sia le colonne
`cliente_*` (snapshot). Un JOIN live sarebbe stato più "pulito"
relazionalmente ma avrebbe rotto la correttezza fiscale storica alla prima
correzione di indirizzo di un cliente.

---
