-- ============================================================================
--  SISTEMA UNIFICATO FULLYLIFE — STRATO FATTURAZIONE  (estensione schema GESPP)
--
--  Da eseguire DOPO lo schema GESPP (companies, persons, app_users esistono già).
--  Modello: "identità condivisa, dati compartimentati".
--    - companies / persons  = identità del soggetto (già GESPP)
--    - billing_profiles      = dati fiscali del soggetto (satellite, QUI)
--    - invoices / invoice_lines = documenti di fatturazione (QUI)
--    - billing_counters      = numerazione progressiva per tipo/anno (QUI)
--    - emitter_settings      = dati fiscali dell'EMITTENTE (Bruno/Simona)
--
--  NB: la logica di generazione XML FatturaPA resta nel frontend, invariata.
--      Qui si modella solo DOVE stanno i dati, non COME si genera l'XML.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. PERMESSO FATTURAZIONE — flag ortogonale ai ruoli esistenti
--    Va aggiunto ad app_users (già esistente). Idempotente.
-- ----------------------------------------------------------------------------
alter table public.app_users
    add column if not exists puo_fatturare boolean not null default false;

-- Helper: l'utente corrente può operare sulla fatturazione?
create or replace function public.can_bill()
returns boolean language sql stable security definer set search_path = public
set row_security = off
as $$
    select coalesce(
        (select puo_fatturare from public.app_users where id = auth.uid()),
        false
    );
$$;
grant execute on function public.can_bill() to authenticated;

-- ----------------------------------------------------------------------------
-- 1. EMITTENTE — dati fiscali di chi emette (multi-profilo: Bruno, Simona)
--    Sostituisce l'oggetto "settings" del localStorage per la parte fiscale.
--    Legato a un app_user (il titolare del profilo di emissione).
-- ----------------------------------------------------------------------------
create table public.emitter_settings (
    id              uuid primary key default gen_random_uuid(),
    owner_id        uuid references public.app_users(id) on delete set null,  -- informativo: titolare nominale della P.IVA, non usato per i permessi (vedi operator_emitter)
    denominazione   text not null,
    partita_iva     text not null,
    codice_fiscale  text,                       -- per ditta individuale: usato come IdTrasmittente
    regime_fiscale  text not null default 'RF19',
    -- sede
    indirizzo       text,
    cap             text,
    comune          text,
    provincia       text,
    -- contatti / pagamento
    email           text,
    pec             text,
    telefono        text,
    iban            text,
    ateco           text,
    -- parametri documento
    prefisso_preventivo text default 'PREV',
    prefisso_fattura    text default 'FATT',
    prefisso_proforma   text default 'PRF',
    prefisso_nota       text default 'NC',
    riferimento_normativo text default 'Operazione in regime forfettario ex art. 1 cc. 54-89 L. 190/2014',
    footer          text,
    -- indirizzo PEC a cui inviare l'XML allo SdI: l'Agenzia delle Entrate lo
    -- cambia periodicamente, va configurabile invece che hardcoded nel frontend
    email_sdi       text default 'sdi01@pec.fatturapa.it',
    -- previsione fiscale
    aliquota_irpef  numeric(5,2) default 5,
    aliquota_inps   numeric(5,2) default 26.23,
    coeff_redditivita numeric(5,2) default 78,
    created_at      timestamptz not null default now(),

    constraint chk_emitter_piva check (partita_iva ~ '^[0-9]{11}$'),
    constraint chk_emitter_cap  check (cap is null or cap ~ '^[0-9]{5}$')
);

-- ----------------------------------------------------------------------------
-- 1b. ASSOCIAZIONE OPERATORE <-> EMITTENTE
--     Definisce chi può emettere sotto quale emittente e chi ne vede le fatture.
--     Fase 1: Simona -> suo emittente; altri operatori -> proprio emittente.
--     Fase 2 (società): tutti gli operatori abilitati -> unico emittente società.
--     L'admin (Bruno) NON ha bisogno di righe qui: bypassa via is_admin().
--     La stessa struttura regge entrambe le fasi: cambiano solo le righe.
-- ----------------------------------------------------------------------------
create table public.operator_emitter (
    id          uuid primary key default gen_random_uuid(),
    operator_id uuid not null references public.app_users(id) on delete cascade,
    emitter_id  uuid not null references public.emitter_settings(id) on delete cascade,
    created_at  timestamptz not null default now(),
    unique (operator_id, emitter_id)
);
create index idx_opem_operator on public.operator_emitter(operator_id);
create index idx_opem_emitter  on public.operator_emitter(emitter_id);

-- Helper: l'utente corrente può operare sotto questo emittente?
--   admin -> sì su tutti; altri -> solo se associati e con permesso fatturazione.
create or replace function public.can_use_emitter(p_emitter_id uuid)
returns boolean language sql stable security definer set search_path = public
set row_security = off
as $$
    select public.is_admin()
        or ( public.can_bill() and exists (
            select 1 from public.operator_emitter oe
            where oe.emitter_id = p_emitter_id and oe.operator_id = auth.uid()
        ));
$$;
grant execute on function public.can_use_emitter(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. BILLING_PROFILES — dati fiscali del SOGGETTO (satellite di companies/persons)
--    Esiste SOLO per i soggetti che si fatturano.
--    Vincolo: collegato a UNA azienda OPPURE a UNA persona (mai entrambe/nessuna).
-- ----------------------------------------------------------------------------
create table public.billing_profiles (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid references public.companies(id) on delete cascade,
    person_id       uuid references public.persons(id)   on delete cascade,
    -- recapito fatturazione elettronica
    codice_destinatario text,                   -- 7 char SDI, oppure NULL se si usa PEC
    pec_destinatario    text,
    email           text,                       -- contatto fatturazione: companies/persons non hanno
                                                  -- una colonna email adatta condivisa con altri domini
    partita_iva     text,                       -- SOLO quando person_id è valorizzato: un professionista
                                                  -- con P.IVA. persons non ha questa colonna nativamente.
                                                  -- Per le aziende la P.IVA resta companies.partita_iva,
                                                  -- unica fonte, non duplicata qui.
    -- indirizzo di fatturazione (strutturato per XML)
    indirizzo       text,
    cap             text,
    comune          text,
    provincia       text,
    -- eventuale referente / responsabile legale
    responsabile_legale text,
    note            text,
    created_at      timestamptz not null default now(),

    -- esattamente uno tra company_id e person_id valorizzato
    constraint chk_billing_subject check (
        (company_id is not null and person_id is null) or
        (company_id is null and person_id is not null)
    ),
    -- SDI: 7 caratteri alfanumerici quando presente
    constraint chk_billing_sdi check (
        codice_destinatario is null or codice_destinatario ~ '^[A-Z0-9]{7}$'
    ),
    -- CAP: 5 cifre quando presente
    constraint chk_billing_cap check (cap is null or cap ~ '^[0-9]{5}$'),
    -- un solo profilo fiscale per soggetto
    unique (company_id),
    unique (person_id)
);

create index idx_billing_company on public.billing_profiles(company_id);
create index idx_billing_person  on public.billing_profiles(person_id);

-- ----------------------------------------------------------------------------
-- 3. BILLING_COUNTERS — numerazione progressiva per emittente/tipo/anno
--    Sostituisce il calcolo nextNum() del frontend. A livello DB per garantire
--    progressività anche con più operatori concorrenti (il bug che abbiamo visto).
-- ----------------------------------------------------------------------------
create table public.billing_counters (
    id          uuid primary key default gen_random_uuid(),
    emitter_id  uuid not null references public.emitter_settings(id) on delete cascade,
    tipo        text not null check (tipo in ('preventivo','fattura','proforma','nota_credito')),
    anno        integer not null,
    ultimo_num  integer not null default 0,
    unique (emitter_id, tipo, anno)
);

-- ----------------------------------------------------------------------------
-- 4. INVOICES — testata documento (preventivo/fattura/proforma/nota credito)
--    Sostituisce l'oggetto documento del localStorage.
-- ----------------------------------------------------------------------------
create table public.invoices (
    id              uuid primary key default gen_random_uuid(),
    emitter_id      uuid not null references public.emitter_settings(id),
    -- soggetto destinatario (stessa logica del billing_profile: azienda O persona)
    company_id      uuid references public.companies(id),
    person_id       uuid references public.persons(id),
    tipo            text not null check (tipo in ('preventivo','fattura','proforma','nota_credito')),
    -- numero NULL finché il documento è in bozza: prossimo_numero() va chiamata
    -- solo alla prima emissione (vedi sezione 8), mai per salvare una bozza.
    -- unique(emitter_id, numero) non ne risente: Postgres non considera due NULL
    -- uguali, quindi più bozze senza numero coesistono senza conflitti.
    numero          text,                       -- es. FATT-002-2026
    data            date not null default current_date,
    scadenza        date,
    aliquota_iva    numeric(5,2) not null default 0,
    imponibile      numeric(12,2) not null default 0,
    imposta         numeric(12,2) not null default 0,
    totale          numeric(12,2) not null default 0,
    note            text,
    -- Snapshot del cliente al momento del salvataggio: un documento fiscale non
    -- deve cambiare se l'indirizzo/PEC del cliente vengono corretti dopo
    -- l'emissione. company_id/person_id restano un riferimento vivo (utile per lo
    -- storico cliente), ma i dati mostrati/stampati vengono sempre da qui.
    cliente_nome        text,
    cliente_piva        text,
    cliente_email       text,
    cliente_indirizzo   text,
    cliente_cap         text,
    cliente_comune      text,
    cliente_provincia   text,
    cliente_cod_dest    text,
    cliente_pec_sdi     text,
    -- stati (dal frontend: status, pagato, archiviato)
    stato           text not null default 'bozza'
                    check (stato in ('bozza','emesso','pagato','annullato')),
    pagato          boolean not null default false,
    archiviato      boolean not null default false,
    data_pagamento    date,
    metodo_pagamento  text,
    -- riferimento testuale al documento di origine (conversione preventivo->
    -- proforma->fattura, o nota di credito a storno di una fattura). Solo
    -- etichetta mostrata nella UI/stampa: non è l'FK convertito_da sotto, che
    -- resta prevista dallo schema per un uso relazionale futuro non ancora
    -- implementato dal frontend.
    prev_ref        text,
    -- tracciamento conversione (preventivo->proforma->fattura)
    convertito_da   uuid references public.invoices(id),
    created_by      uuid references public.app_users(id),
    created_at      timestamptz not null default now(),

    -- Il form documento permette di digitare un cliente "al volo" senza passare
    -- dall'anagrafica: company_id/person_id possono restare entrambi null (non
    -- più "esattamente uno dei due" come nella prima stesura dello schema).
    constraint chk_invoice_subject check (
        not (company_id is not null and person_id is not null)
    ),
    unique (emitter_id, numero)
);

create index idx_invoices_emitter on public.invoices(emitter_id);
create index idx_invoices_company on public.invoices(company_id);
create index idx_invoices_person  on public.invoices(person_id);
create index idx_invoices_tipo    on public.invoices(tipo);

-- ----------------------------------------------------------------------------
-- 5. INVOICE_LINES — righe documento
--    Sostituisce l'array righe[] del documento localStorage.
-- ----------------------------------------------------------------------------
create table public.invoice_lines (
    id              uuid primary key default gen_random_uuid(),
    invoice_id      uuid not null references public.invoices(id) on delete cascade,
    numero_linea    integer not null,
    descrizione     text not null,
    quantita        numeric(12,2) not null default 1,
    unita_misura    text default 'forfait',
    prezzo_unitario numeric(12,2) not null default 0,
    prezzo_totale   numeric(12,2) not null default 0,
    created_at      timestamptz not null default now(),
    unique (invoice_id, numero_linea)
);

create index idx_lines_invoice on public.invoice_lines(invoice_id);

-- ----------------------------------------------------------------------------
-- 6. CATALOGO SERVIZI — prodotti/servizi riutilizzabili
--    emitter_id null  = catalogo comune, condiviso tra TUTTI gli operatori
--                        con puo_fatturare (evoluzione di mp_shared_products,
--                        che oggi è "comune" solo per limite del localStorage).
--    emitter_id valorizzato = catalogo personale di quell'emittente.
--    src_id: per una riga comune generata pubblicando una riga personale,
--            punta a quella riga personale (rispecchia il campo srcId del
--            frontend). Permette alle due righe di divergere se modificate
--            separatamente, come nel comportamento attuale.
-- ----------------------------------------------------------------------------
create table public.service_catalog (
    id              uuid primary key default gen_random_uuid(),
    emitter_id      uuid references public.emitter_settings(id) on delete cascade,
    src_id          uuid references public.service_catalog(id) on delete set null,
    nome            text not null,
    descrizione     text,
    prezzo          numeric(12,2) not null default 0,
    unita_misura    text default 'ora',
    categoria       text,
    created_at      timestamptz not null default now()
);
create index idx_catalog_emitter on public.service_catalog(emitter_id);

-- ----------------------------------------------------------------------------
-- 6b. CATEGORIE SERVIZI — mp_shared_categories, globali come il catalogo
--     comune: usate per raggruppare/colorare le voci nel catalogo.
-- ----------------------------------------------------------------------------
create table public.service_categories (
    id          uuid primary key default gen_random_uuid(),
    nome        text not null unique,
    colore      text,
    created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 7. RLS — solo chi ha puo_fatturare accede allo strato fatturazione.
--    I dati sanitari restano protetti dalla loro RLS: vedere un soggetto per
--    fatturarlo NON dà accesso a health_records.
-- ----------------------------------------------------------------------------
alter table public.emitter_settings enable row level security;
alter table public.operator_emitter enable row level security;
alter table public.billing_profiles enable row level security;
alter table public.billing_counters enable row level security;
alter table public.invoices         enable row level security;
alter table public.invoice_lines    enable row level security;
alter table public.service_catalog  enable row level security;
alter table public.service_categories enable row level security;

-- emitter_settings: creazione/eliminazione solo admin (operazioni fiscalmente
-- sensibili, disattivate anche dalla UI); l'aggiornamento dei dati (es.
-- Impostazioni nel frontend) è invece consentito a chi può usare quell'
-- emittente, non solo all'admin — altrimenti nessun operatore non-admin
-- potrebbe mai modificare i propri dati fiscali.
create policy emitter_read on public.emitter_settings
    for select using (public.can_bill() or public.is_admin());
create policy emitter_admin_insert on public.emitter_settings
    for insert with check (public.is_admin());
create policy emitter_admin_delete on public.emitter_settings
    for delete using (public.is_admin());
create policy emitter_update on public.emitter_settings
    for update using (public.can_use_emitter(id)) with check (public.can_use_emitter(id));

-- operator_emitter: l'operatore vede le proprie associazioni; solo admin le gestisce
create policy opem_read on public.operator_emitter
    for select using (operator_id = auth.uid() or public.is_admin());
create policy opem_admin_write on public.operator_emitter
    for all using (public.is_admin()) with check (public.is_admin());

-- billing_profiles: solo chi fattura
create policy billing_read on public.billing_profiles
    for select using (public.can_bill());
create policy billing_write on public.billing_profiles
    for all using (public.can_bill()) with check (public.can_bill());

-- billing_counters: legati all'emittente -> stesso criterio delle fatture
create policy counters_all on public.billing_counters
    for all using (public.can_use_emitter(emitter_id))
    with check (public.can_use_emitter(emitter_id));

-- invoices: visibilità e scrittura basate sull'EMITTENTE, non sul creatore.
--   admin -> tutte; operatore -> solo quelle del proprio emittente.
--   Copre correttamente il caso "Bruno emette a nome di Simona":
--   la fattura è del emitter di Simona, quindi Simona la vede.
create policy invoices_read on public.invoices
    for select using (public.can_use_emitter(emitter_id));
create policy invoices_write on public.invoices
    for all using (public.can_use_emitter(emitter_id))
    with check (public.can_use_emitter(emitter_id));

-- invoice_lines: accesso via l'emittente della fattura padre
create policy lines_all on public.invoice_lines
    for all using ( exists (
        select 1 from public.invoices i
        where i.id = invoice_lines.invoice_id and public.can_use_emitter(i.emitter_id)
    )) with check ( exists (
        select 1 from public.invoices i
        where i.id = invoice_lines.invoice_id and public.can_use_emitter(i.emitter_id)
    ));

-- service_catalog: riga comune (emitter_id null) -> chiunque possa fatturare;
--   riga personale -> solo chi può usare quell'emittente. Una sola policy
--   per operazione: qui non serve l'asimmetria insert/update vista nel bug
--   del Modulo 1 su emitter_settings, la creazione non è un'operazione
--   fiscalmente sensibile come la creazione di un emittente.
create policy catalog_all on public.service_catalog
    for all using (
        (emitter_id is null and public.can_bill())
        or (emitter_id is not null and public.can_use_emitter(emitter_id))
    )
    with check (
        (emitter_id is null and public.can_bill())
        or (emitter_id is not null and public.can_use_emitter(emitter_id))
    );

-- service_categories: globali, chi fattura legge/scrive
create policy categories_all on public.service_categories
    for all using (public.can_bill()) with check (public.can_bill());

-- ----------------------------------------------------------------------------
-- 7b. POLICY ADDITIVE su companies/persons (tabelle GESPP esistenti) per la
--     fatturazione. NON sostituiscono le policy GESPP già presenti su queste
--     tabelle (companies_read/companies_admin_write, persons_read/
--     persons_insert/persons_update/persons_delete) — le policy Postgres per
--     lo stesso comando si combinano in OR, quindi questo apre un percorso
--     d'accesso aggiuntivo scoped a can_bill(), senza toccare né restringere
--     l'accesso già concesso ai consulenti/admin GESPP.
--
--     Verificato (2026-09-05): senza queste policy un utente puo_fatturare
--     non admin e non collegato via consultant_company non può leggere né
--     scrivere companies/persons — buco reale, non solo teorico.
--
--     Nessuna policy di DELETE per can_bill(): companies/persons sono
--     soggetti condivisi tra tutti i domini, la cancellazione resta
--     admin-only (comportamento GESPP esistente, non toccato). L'azione
--     "elimina cliente" nel frontend cancella solo la riga billing_profiles
--     collegata, mai il soggetto condiviso.
--
--     Su persons, scoped a tipo='professionista': un utente fatturazione
--     non deve poter leggere/creare righe 'dipendente', che appartengono al
--     dominio di profilazione aziendale GESPP, non a quello fatturazione.
-- ----------------------------------------------------------------------------
create policy companies_billing_select on public.companies
    for select using (public.can_bill());
create policy companies_billing_insert on public.companies
    for insert with check (public.can_bill());
create policy companies_billing_update on public.companies
    for update using (public.can_bill()) with check (public.can_bill());

create policy persons_billing_select on public.persons
    for select using (public.can_bill() and tipo = 'professionista'::person_type);
create policy persons_billing_insert on public.persons
    for insert with check (public.can_bill() and tipo = 'professionista'::person_type);
create policy persons_billing_update on public.persons
    for update using (public.can_bill() and tipo = 'professionista'::person_type)
    with check (public.can_bill() and tipo = 'professionista'::person_type);

grant select, insert, update on public.companies, public.persons to authenticated;

-- GRANT di base (la RLS filtra le righe)
grant select, insert, update, delete on
    public.emitter_settings, public.operator_emitter, public.billing_profiles,
    public.billing_counters, public.invoices, public.invoice_lines, public.service_catalog,
    public.service_categories
    to authenticated;

-- ----------------------------------------------------------------------------
-- 8. PROSSIMO_NUMERO — numerazione atomica di preventivi/fatture/proforma/note
--    Sostituisce nextNum() del frontend (che leggeva il max da docs in memoria).
--
--    ⚠️ CONTRATTO D'USO — la correttezza fiscale dipende da CHI e QUANDO la
--    chiama, non solo da come è scritta:
--
--    1. Va chiamata solo all'EMISSIONE del documento (transizione bozza →
--       emesso), MAI alla creazione/salvataggio di una bozza. Ogni chiamata
--       consuma un numero in modo definitivo e irreversibile: una bozza
--       salvata, modificata più volte o mai emessa non deve mai passare di
--       qui, altrimenti si bruciano numeri e si aprono buchi nella sequenza
--       (problema in sede di controllo fiscale).
--    2. Dopo uno SCARTO da parte dello SdI, il frontend NON deve richiamare
--       questa funzione per ritrasmettere il documento: la fattura scartata
--       si corregge e si ritrasmette con lo STESSO numero già assegnato alla
--       prima emissione. Richiamarla di nuovo assegnerebbe un secondo numero
--       allo stesso documento logico, disallineando la numerazione da quanto
--       dichiarato all'Agenzia delle Entrate.
-- ----------------------------------------------------------------------------
create or replace function public.prossimo_numero(
    p_emitter_id uuid,
    p_tipo       text,
    p_anno       integer
)
returns text
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_num      integer;
    v_prefisso text;
begin
    -- validazione dominio: errore leggibile invece di far fallire il CHECK
    -- constraint sull'INSERT più sotto
    if p_tipo not in ('preventivo','fattura','proforma','nota_credito') then
        raise exception 'Tipo documento non valido: %', p_tipo
            using errcode = '22023';  -- invalid_parameter_value
    end if;

    -- controllo permesso: solo chi può usare questo emittente
    if not public.can_use_emitter(p_emitter_id) then
        raise exception 'Non autorizzato a emettere sotto l''emittente %', p_emitter_id
            using errcode = '42501';  -- insufficient_privilege
    end if;

    -- percorso principale: la riga contatore esiste già.
    -- UPDATE...RETURNING legge, blocca e incrementa in un solo statement atomico:
    -- due chiamate concorrenti si serializzano sul lock di riga, mai lo stesso numero.
    update public.billing_counters
       set ultimo_num = ultimo_num + 1
     where emitter_id = p_emitter_id
       and tipo        = p_tipo
       and anno         = p_anno
    returning ultimo_num into v_num;

    -- la riga non esisteva ancora: creala partendo da 1.
    -- ON CONFLICT gestisce la creazione concorrente: se un'altra chiamata la crea
    -- nello stesso istante, questa transazione si blocca sul conflitto e incrementa
    -- invece di fallire con una violazione di unicità.
    if not found then
        insert into public.billing_counters (emitter_id, tipo, anno, ultimo_num)
        values (p_emitter_id, p_tipo, p_anno, 1)
        on conflict (emitter_id, tipo, anno)
        do update set ultimo_num = public.billing_counters.ultimo_num + 1
        returning ultimo_num into v_num;
    end if;

    -- prefisso in base al tipo, letto dall'emittente
    select case p_tipo
             when 'preventivo'   then e.prefisso_preventivo
             when 'fattura'      then e.prefisso_fattura
             when 'proforma'     then e.prefisso_proforma
             when 'nota_credito' then e.prefisso_nota
           end
      into v_prefisso
      from public.emitter_settings e
     where e.id = p_emitter_id;

    if v_prefisso is null then
        raise exception 'Emittente % non trovato o prefisso non configurato per il tipo %',
            p_emitter_id, p_tipo
            using errcode = 'P0002';  -- no_data_found
    end if;

    -- formato PREFISSO-NNN-ANNO (numero 3 cifre, anno 4 cifre)
    return v_prefisso || '-' || lpad(v_num::text, 3, '0') || '-' || to_char(p_anno, 'FM0000');
end;
$$;

grant execute on function public.prossimo_numero(uuid, text, integer) to authenticated;

-- ============================================================================
-- 9. MODULO 1 FRONTEND — colonne aggiuntive emittente + RPC di selezione
--    Supporto per lo switch da "profilo" locale (mp_profiles) a scelta
--    dell'emittente Supabase-backed nel frontend.
-- ----------------------------------------------------------------------------
alter table public.emitter_settings
    add column if not exists acconto     numeric(5,2) default 0,
    add column if not exists role_label  text,
    add column if not exists color_index integer default 0;

-- Restituisce solo gli emittenti che l'utente corrente può usare.
-- security invoker (non definer) di proposito: la RLS su emitter_settings
-- resta attiva come seconda linea di difesa, coerente con prossimo_numero().
create or replace function public.emittenti_disponibili()
returns setof public.emitter_settings
language sql stable security invoker set search_path = public
as $$
    select e.* from public.emitter_settings e
    where public.can_use_emitter(e.id);
$$;
grant execute on function public.emittenti_disponibili() to authenticated;

-- ============================================================================
-- 10. WORK CALENDAR — pianificazione attività per consulente, condivisa per
--     taggatura (dominio "Calendario/Calendar Work" della cornice a sei,
--     integrato qui invece che come modulo a parte — vedi CLAUDE.md).
--
--     Modello: ogni consulente ha il proprio calendario privato (task,
--     backlog, categorie) — owner_id. Un task può taggare altri consulenti
--     come "operatori": chi è taggato (sul task o su un suo subtask) entra
--     a far parte del "team" di quel task e può vederlo, vedere gli altri
--     taggati, leggere/scrivere aggiornamenti condivisi (wc_task_updates).
--     Cambiare lo stato di un subtask è riservato a chi è taggato su
--     QUEL subtask specifico, non all'intero team del task. Struttura e
--     proprietà del task (nome/data/punti/taggature) restano del
--     proprietario.
-- ----------------------------------------------------------------------------

create table public.wc_categories (
    id         uuid primary key default gen_random_uuid(),
    owner_id   uuid not null references public.app_users(id) on delete cascade,
    nome       text not null,
    colore     text not null default '#7c6fcd',
    created_at timestamptz not null default now()
);

create table public.wc_backlog (
    id           uuid primary key default gen_random_uuid(),
    owner_id     uuid not null references public.app_users(id) on delete cascade,
    nome         text not null,
    pts          integer not null default 5,
    categoria_id uuid references public.wc_categories(id) on delete set null,
    note         text,
    created_at   timestamptz not null default now()
);

create table public.wc_tasks (
    id              uuid primary key default gen_random_uuid(),
    owner_id        uuid not null references public.app_users(id) on delete cascade,
    nome            text not null,
    data            date not null,
    pts             integer not null default 5,
    categoria_id    uuid references public.wc_categories(id) on delete set null,
    stato           text not null default 'todo' check (stato in ('todo','doing','done')),
    ricorrenza      text not null default 'none' check (ricorrenza in ('none','daily','weekly','monthly')),
    ricorrenza_fine date,
    note            text,
    -- collegamento al backlog di provenienza, se pianificato da lì
    -- (una direzione sola: "è pianificato?" si deduce cercando se un task
    -- referenzia questo backlog_id, non serve il puntatore inverso)
    backlog_id      uuid references public.wc_backlog(id) on delete set null,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create index idx_wc_tasks_owner on public.wc_tasks(owner_id);
create index idx_wc_tasks_data  on public.wc_tasks(data);

create table public.wc_task_operators (
    task_id     uuid not null references public.wc_tasks(id) on delete cascade,
    operator_id uuid not null references public.app_users(id) on delete cascade,
    primary key (task_id, operator_id)
);

create table public.wc_subtasks (
    id         uuid primary key default gen_random_uuid(),
    task_id    uuid not null references public.wc_tasks(id) on delete cascade,
    nome       text not null,
    pts        integer default 0,
    stato      text not null default 'todo' check (stato in ('todo','doing','done')),
    ordine     integer not null default 0,
    created_at timestamptz not null default now()
);
create index idx_wc_subtasks_task on public.wc_subtasks(task_id);

create table public.wc_subtask_operators (
    subtask_id  uuid not null references public.wc_subtasks(id) on delete cascade,
    operator_id uuid not null references public.app_users(id) on delete cascade,
    primary key (subtask_id, operator_id)
);

-- Log condiviso di aggiornamenti sul task, visibile e scrivibile da tutto
-- il team (proprietario + taggati), non solo dal proprietario.
create table public.wc_task_updates (
    id         uuid primary key default gen_random_uuid(),
    task_id    uuid not null references public.wc_tasks(id) on delete cascade,
    author_id  uuid not null references public.app_users(id) on delete cascade,
    testo      text not null,
    created_at timestamptz not null default now()
);
create index idx_wc_updates_task on public.wc_task_updates(task_id);

-- ----------------------------------------------------------------------------
-- Chi fa parte del "team" di un task: il proprietario, chi è taggato sul
-- task, chi è taggato su uno dei suoi subtask. security definer perché
-- valutata dentro le policy di più tabelle diverse (stesso motivo di
-- can_access_person in GESPP: evita di dover dare grant incrociati fra le
-- tabelle wc_* solo per farle leggere l'un l'altra durante la valutazione
-- della RLS).
-- ----------------------------------------------------------------------------
create or replace function public.wc_can_see_task(p_task_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
    select exists(
        select 1 from public.wc_tasks t
        where t.id = p_task_id
          and (
            t.owner_id = auth.uid()
            or public.is_admin()
            or exists(select 1 from public.wc_task_operators o where o.task_id = t.id and o.operator_id = auth.uid())
            or exists(
                select 1 from public.wc_subtasks s
                join public.wc_subtask_operators so on so.subtask_id = s.id
                where s.task_id = t.id and so.operator_id = auth.uid()
            )
          )
    );
$$;
grant execute on function public.wc_can_see_task(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.wc_categories        enable row level security;
alter table public.wc_backlog           enable row level security;
alter table public.wc_tasks             enable row level security;
alter table public.wc_task_operators    enable row level security;
alter table public.wc_subtasks          enable row level security;
alter table public.wc_subtask_operators enable row level security;
alter table public.wc_task_updates      enable row level security;

-- categorie/backlog: solo il proprietario, calendario privato come oggi.
create policy wc_categories_owner on public.wc_categories
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());
create policy wc_backlog_owner on public.wc_backlog
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());

-- Il team di un task deve poter leggere nome/colore delle categorie usate
-- da quel task — non l'intero elenco categorie del proprietario, solo
-- quelle effettivamente referenziate da un task che può vedere. Sola
-- lettura: nessuna policy di scrittura aggiuntiva, resta owner-only.
create policy wc_categories_team_read on public.wc_categories
    for select to authenticated using (
        exists(select 1 from public.wc_tasks t where t.categoria_id = wc_categories.id and public.wc_can_see_task(t.id))
    );

-- task: il proprietario ha pieno controllo; il team lo vede soltanto —
-- nessuna policy di update/delete per i taggati sulla riga task stessa,
-- la struttura resta del proprietario.
create policy wc_tasks_owner_all on public.wc_tasks
    for all to authenticated using (owner_id = auth.uid() or public.is_admin())
    with check (owner_id = auth.uid() or public.is_admin());
create policy wc_tasks_team_read on public.wc_tasks
    for select to authenticated using (public.wc_can_see_task(id));

-- taggature: il proprietario del task le gestisce; il team vede chi altro
-- è taggato (utile per sapere con chi si sta collaborando).
create policy wc_task_operators_owner_write on public.wc_task_operators
    for all to authenticated using (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_task_operators_team_read on public.wc_task_operators
    for select to authenticated using (public.wc_can_see_task(task_id));

-- subtask: il proprietario del task ha pieno controllo (struttura,
-- creazione, cancellazione). Il team lo vede in lettura. Lo stato invece
-- lo può cambiare solo chi è taggato su QUEL subtask specifico (non tutto
-- il team del task) — coerente con "aggiornamenti sulla propria parte".
create policy wc_subtasks_owner_all on public.wc_subtasks
    for all to authenticated using (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_tasks t where t.id = task_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_subtasks_team_read on public.wc_subtasks
    for select to authenticated using (public.wc_can_see_task(task_id));
create policy wc_subtasks_assigned_update on public.wc_subtasks
    for update to authenticated using (
        exists(select 1 from public.wc_subtask_operators so where so.subtask_id = id and so.operator_id = auth.uid())
    ) with check (
        exists(select 1 from public.wc_subtask_operators so where so.subtask_id = id and so.operator_id = auth.uid())
    );

create policy wc_subtask_operators_owner_write on public.wc_subtask_operators
    for all to authenticated using (
        exists(select 1 from public.wc_subtasks s join public.wc_tasks t on t.id = s.task_id
               where s.id = subtask_id and (t.owner_id = auth.uid() or public.is_admin()))
    ) with check (
        exists(select 1 from public.wc_subtasks s join public.wc_tasks t on t.id = s.task_id
               where s.id = subtask_id and (t.owner_id = auth.uid() or public.is_admin()))
    );
create policy wc_subtask_operators_team_read on public.wc_subtask_operators
    for select to authenticated using (
        exists(select 1 from public.wc_subtasks s where s.id = subtask_id and public.wc_can_see_task(s.task_id))
    );

-- aggiornamenti: tutto il team del task legge e scrive (sempre a nome
-- proprio — mai a nome di qualcun altro); solo l'autore (o l'admin) elimina.
create policy wc_task_updates_team_read on public.wc_task_updates
    for select to authenticated using (public.wc_can_see_task(task_id));
create policy wc_task_updates_team_insert on public.wc_task_updates
    for insert to authenticated with check (author_id = auth.uid() and public.wc_can_see_task(task_id));
create policy wc_task_updates_author_delete on public.wc_task_updates
    for delete to authenticated using (author_id = auth.uid() or public.is_admin());

grant select, insert, update, delete on
    public.wc_categories, public.wc_backlog, public.wc_tasks, public.wc_task_operators,
    public.wc_subtasks, public.wc_subtask_operators, public.wc_task_updates
    to authenticated;

-- ============================================================================
--  FINE STRATO FATTURAZIONE + WORK CALENDAR.
--
--  Verificato:
--   - prossimo_numero(): atomicità sotto concorrenza (test SQL Editor a due
--     sessioni, vedi memoria progetto).
--   - Isolamento GDPR: un utente consulente_limitato + puo_fatturare=true
--     legge 0 righe su spp_profiles/health_consents/health_records/
--     self_reports/meetings (verificato con controllo di contrasto positivo
--     su emitter_settings/can_bill() per escludere falsi positivi da
--     sessione mal configurata).
-- ============================================================================
