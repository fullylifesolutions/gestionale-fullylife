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
-- 10. LOGO ORGANIZZATIVO — bucket Storage "loghi"
--    Logo UNICO, condiviso da tutti gli operatori (a differenza di
--    emitter_settings, che è per-emittente): path fisso 'logo.png', upsert lo
--    sostituisce. Nessuna colonna in emitter_settings — l'URL pubblico è
--    costruibile a runtime da getPublicUrl(), non va persistito.
--    Stesso pattern del bucket "consensi" in GESPP (gespp_1_schema.sql /
--    gespp_2_funzioni_policy.sql): pubblico in lettura, perché i documenti si
--    generano in una window.open() senza sessione Supabase e serve un URL
--    diretto; scrittura (insert/update/delete) riservata all'admin.
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('loghi', 'loghi', true)
on conflict (id) do nothing;

drop policy if exists loghi_public_read on storage.objects;
create policy loghi_public_read on storage.objects
    for select to anon, authenticated using (bucket_id = 'loghi');

drop policy if exists loghi_admin_insert on storage.objects;
create policy loghi_admin_insert on storage.objects
    for insert to authenticated with check (bucket_id = 'loghi' and public.is_admin());

drop policy if exists loghi_admin_update on storage.objects;
create policy loghi_admin_update on storage.objects
    for update to authenticated using (bucket_id = 'loghi' and public.is_admin())
    with check (bucket_id = 'loghi' and public.is_admin());

drop policy if exists loghi_admin_delete on storage.objects;
create policy loghi_admin_delete on storage.objects
    for delete to authenticated using (bucket_id = 'loghi' and public.is_admin());

-- ============================================================================
-- 11. POLICY ADDITIVA su company_contacts (tabella GESPP esistente), stesso
--     buco già corretto in 7b su companies/persons: le policy GESPP
--     (contacts_read/contacts_write in gespp_2_funzioni_policy.sql) concedono
--     accesso solo ad admin o a chi ha un legame consultant_company — un
--     utente can_bill() non admin e non collegato via consultant_company non
--     potrebbe leggere né gestire i referenti azienda dal gestionale.
--     Le policy Postgres per lo stesso comando si combinano in OR: questo
--     apre un percorso d'accesso aggiuntivo scoped a can_bill(), senza
--     toccare né restringere l'accesso già concesso ai consulenti/admin
--     GESPP (stesso principio di companies_billing_*/persons_billing_*).
--
--     A differenza di companies/persons (soggetto condiviso, cancellazione
--     riservata ad admin), qui il DELETE è incluso: un referente è una riga
--     satellite legata al soggetto, non l'identità condivisa — e GESPP stesso
--     concede già il delete ai consulenti collegati (contacts_write, "for
--     all"), quindi non introduce un'asimmetria nuova.
--
--     Nessun GRANT esplicito necessario: Supabase applica di default i
--     privilegi su tutte le tabelle di public a authenticated (verificato
--     durante il test GDPR, vedi memoria di progetto).
-- ----------------------------------------------------------------------------
drop policy if exists contacts_billing_all on public.company_contacts;
create policy contacts_billing_all on public.company_contacts
    for all using (public.can_bill()) with check (public.can_bill());

-- ============================================================================
-- 12. FIRMA EMITTENTE — bucket Storage privato "firme"
--    A differenza del logo (sezione 10: pubblico, path fisso, uguale per
--    tutti), la firma è per-emittente e NON pubblica: chi può leggerla/
--    gestirla è deciso da can_use_emitter(emitter_id), la stessa funzione che
--    già governa emitter_settings/invoices/service_catalog. Path
--    'emitter/<emitter_id>.png' — upload con upsert lo sostituisce.
--    I documenti fiscali (prtDoc, frontend) si generano da sessione Supabase
--    già autenticata (a differenza del logo, mai in una window.open() senza
--    sessione): si scarica il file con la sessione corrente, si converte in
--    base64 e lo si inserisce inline PRIMA di aprire la finestra di stampa —
--    nessun URL pubblico da costruire, quindi nessuna lettura anon.
--    Doppia barriera su tipo/dimensione: il frontend controlla già PNG e max
--    1MB prima dell'upload, ma file_size_limit/allowed_mime_types sul bucket
--    fanno rispettare lo stesso limite anche lato Storage, indipendentemente
--    dal client (accesso diretto alle API, bypass del frontend, ecc.).
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('firme', 'firme', false, 1048576, array['image/png'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Estrae l'emitter_id dal path 'emitter/<uuid>.png'; NULL se il path non
-- rispetta il formato atteso (niente errore di cast in valutazione RLS —
-- con emitter_id NULL, can_use_emitter() restringe comunque all'admin).
create or replace function public.firma_emitter_id(p_path text)
returns uuid language sql immutable
as $$
    select (regexp_match(p_path, '^emitter/([0-9a-fA-F-]{36})\.png$'))[1]::uuid
$$;
grant execute on function public.firma_emitter_id(text) to authenticated;

drop policy if exists firme_emitter_read on storage.objects;
create policy firme_emitter_read on storage.objects
    for select to authenticated
    using (bucket_id = 'firme' and public.can_use_emitter(public.firma_emitter_id(name)));

drop policy if exists firme_emitter_insert on storage.objects;
create policy firme_emitter_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'firme' and public.can_use_emitter(public.firma_emitter_id(name)));

drop policy if exists firme_emitter_update on storage.objects;
create policy firme_emitter_update on storage.objects
    for update to authenticated
    using (bucket_id = 'firme' and public.can_use_emitter(public.firma_emitter_id(name)))
    with check (bucket_id = 'firme' and public.can_use_emitter(public.firma_emitter_id(name)));

drop policy if exists firme_emitter_delete on storage.objects;
create policy firme_emitter_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'firme' and public.can_use_emitter(public.firma_emitter_id(name)));

-- ============================================================================
-- 13. FIRMA CONSULENTE — path consulente/<user_id>.png nel bucket "firme"
--    Riusa il bucket "firme" già creato in sezione 12 (nessun secondo
--    insert/on-conflict necessario). A differenza della firma emittente
--    (can_use_emitter, più operatori possibili), qui la regola è UNICA e
--    più stretta per scelta esplicita: SOLO is_admin(), per read/insert/
--    update/delete. Non è ogni consulente a caricare la propria firma — è
--    l'admin (Bruno) a caricare/sostituire/rimuovere la firma di ciascun
--    consulente da un'area dedicata nelle impostazioni, ed è sempre l'admin
--    a generare gli NDA (Simona non genera NDA). Path
--    'consulente/<user_id>.png' — upload con upsert lo sostituisce.
--
--    Isolamento per prefisso verificato nei due sensi: queste policy non
--    toccano mai 'emitter/...' (controllano split_part(name,'/',1)=
--    'consulente', sempre falso su quei path), e le policy emitter esistenti
--    concedono sui path 'consulente/...' solo l'accesso admin (la regex di
--    firma_emitter_id() non matcha '^emitter/...', torna NULL, e
--    can_use_emitter(NULL) collassa a solo is_admin()) — stesso risultato di
--    queste, non un accesso ulteriore.
-- ----------------------------------------------------------------------------
drop policy if exists firme_consulente_read on storage.objects;
create policy firme_consulente_read on storage.objects
    for select to authenticated
    using (bucket_id = 'firme' and split_part(name, '/', 1) = 'consulente' and public.is_admin());

drop policy if exists firme_consulente_insert on storage.objects;
create policy firme_consulente_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'firme' and split_part(name, '/', 1) = 'consulente' and public.is_admin());

drop policy if exists firme_consulente_update on storage.objects;
create policy firme_consulente_update on storage.objects
    for update to authenticated
    using (bucket_id = 'firme' and split_part(name, '/', 1) = 'consulente' and public.is_admin())
    with check (bucket_id = 'firme' and split_part(name, '/', 1) = 'consulente' and public.is_admin());

drop policy if exists firme_consulente_delete on storage.objects;
create policy firme_consulente_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'firme' and split_part(name, '/', 1) = 'consulente' and public.is_admin());

-- Lista consulenti selezionabili per NDA (RPC, non select diretta su
-- app_users): la RLS di app_users (id = auth.uid() or is_admin(), da GESPP)
-- impedirebbe a chiunque non-admin di vedere le righe altrui. Gate
-- is_admin() anche qui (non solo can_bill()): coerente con le policy sopra
-- — solo Bruno genera NDA, quindi solo Bruno vede la lista popolata, invece
-- di uno stato confuso (select pieni, firme sempre vuote per chiunque
-- altro).
create or replace function public.consulenti_nda_disponibili()
returns table(id uuid, nome text, cognome text, ruolo user_role)
language sql stable security definer set search_path = public
set row_security = off
as $$
    select u.id, u.nome, u.cognome, u.ruolo
    from public.app_users u
    where u.attivo
      and u.ruolo in ('consulente','admin')
      and public.is_admin()
    order by u.cognome, u.nome;
$$;
grant execute on function public.consulenti_nda_disponibili() to authenticated;

-- ============================================================================
-- 14. TEMPLATE DOCUMENTI LEGALI — legal_templates
--    Sostituisce (a regime) il testo hardcoded di printNDA(): il corpo HTML
--    vive qui, con segnaposto {{...}} sostituiti a runtime dal motore
--    renderLegalDoc() nel frontend (fase 3). Lettura: chiunque autenticato
--    può leggere i template ATTIVI — serve per popolare il select "Tipo di
--    accordo" a chiunque generi documenti legali, non solo admin. Stesso
--    criterio già usato per consent_config in GESPP: contenuto non
--    sensibile, serve alla UI. Scrittura: solo admin, è l'admin a
--    redigere/approvare i testi legali.
--
--    'attori' descrive chi compila il documento (jsonb array), es. NDA:
--    [{"slot":"CONSULENTE1","tipo":"consulente","label":"Consulente 1","firma":true},
--     {"slot":"CONSULENTE2","tipo":"consulente","label":"Consulente 2","firma":true},
--     {"slot":"AZIENDA","tipo":"azienda","label":"Azienda","firma":false}]
--    Tipi di attore supportati (insieme chiuso per ora): 'consulente'
--    (fonte app_users+emitter_settings), 'azienda'/'cliente' (fonte clients
--    lato frontend, cioè companies/persons+billing_profiles). Segnaposto per
--    slot: {{<SLOT>_NOME}}, {{<SLOT>_QUALIFICA}}, {{<SLOT>_PIVA}},
--    {{<SLOT>_CF}}, {{<SLOT>_STUDIO}}, {{<SLOT>_PEC}} per 'consulente';
--    {{<SLOT>_DENOMINAZIONE}} (o {{<SLOT>_NOME}}), {{<SLOT>_PIVA_CF}},
--    {{<SLOT>_INDIRIZZO}}, {{<SLOT>_RESP_LEGALE}}, {{<SLOT>_PEC}} per
--    'azienda'/'cliente'; {{FIRMA_<SLOT>}} dove firma:true. Più
--    {{LUOGO_DATA}} globale. PEC (consulente e azienda/cliente) e
--    RESP_LEGALE (azienda/cliente) aggiunti il 2026-09-18: migrando il testo
--    NDA SRC esistente sono emersi due valori già in uso (PEC dei
--    consulenti, PEC e rappresentante legale dell'azienda) che l'insieme
--    iniziale non copriva — estensione decisa esplicitamente, non dedotta.
--    Nessuna sostituzione lato DB: la tabella contiene solo il corpo col
--    segnaposto, la sostituzione è tutta frontend (stesso principio già in
--    vigore: "qui si modella dove stanno i dati, non come si genera il
--    documento").
--
--    Policy di lettura: attivo=true per chiunque autenticato, OPPURE
--    is_admin() — l'admin vede anche i template disattivati (serve per un
--    futuro editor/versionamento, dove deve poter rivedere/riattivare una
--    bozza prima che sia visibile a tutti).
--
--    Nessuna funzione RPC di lettura: a differenza di consulenti_nda_
--    disponibili() (che bypassa una RLS più restrittiva su app_users),
--    qui la policy di select è già essa stessa il filtro "attivi" per
--    chiunque autenticato — un select diretto basta, non serve un wrapper.
-- ----------------------------------------------------------------------------
create table if not exists public.legal_templates (
    id            uuid primary key default gen_random_uuid(),
    tipo          text not null,
    nome          text not null,
    versione      text not null,
    corpo         text not null,
    attori        jsonb not null default '[]',
    attivo        boolean not null default true,
    note          text,
    aggiornato_da uuid references public.app_users(id),
    aggiornato_il timestamptz not null default now()
);
create index if not exists idx_legal_templates_tipo on public.legal_templates(tipo);
-- Aggiunto il 2026-09-20 dopo un incidente reale: un INSERT rilanciato per
-- errore su produzione ha creato un duplicato attivo di 'nda_src' (stesso
-- tipo, contenuto identico — 'tipo' non aveva nessun vincolo). Indice unico
-- PARZIALE (solo attivo=true): impedisce due righe attive con lo stesso
-- tipo, ma lascia spazio allo storico/versioning (più righe con lo stesso
-- tipo e attivo=false possono coesistere, es. versioni precedenti).
create unique index if not exists idx_legal_templates_tipo_attivo_unique
on public.legal_templates(tipo) where attivo = true;

alter table public.legal_templates enable row level security;

drop policy if exists legal_templates_read on public.legal_templates;
create policy legal_templates_read on public.legal_templates
    for select to authenticated using (attivo = true or public.is_admin());

drop policy if exists legal_templates_admin_write on public.legal_templates;
create policy legal_templates_admin_write on public.legal_templates
    for all to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.legal_templates to authenticated;

-- ----------------------------------------------------------------------------
-- 15. QUOTE_TRANCHES — fatturazione a tranche da preventivo
--     Piano di tranche (acconto/tranche/saldo...) su un preventivo esistente.
--     Tabella isolata: non tocca invoices/invoice_lines. Il legame verso i
--     documenti generati (proforma_id/fattura_id) è relazionale fin da subito
--     — a differenza di invoices.convertito_da (mai valorizzato dal frontend,
--     resta morto, sezione 4), qui il frontend scrive davvero questi due campi
--     quando genera un documento dalla tranche (vedi Fase 2 del piano).
--
--     Base di calcolo: invoices.imponibile (colonna già separata dal totale,
--     sezione 4) — mai il totale. importo_imponibile su ciascuna riga è la
--     fonte di verità una volta salvata: al momento della fatturazione si
--     legge questo valore dal DB, non si ricalcola dalla percentuale.
--     Quadratura al centesimo lasciata al frontend (Fase 2): le prime N-1
--     tranche sono round2(imponibile * percentuale/100), l'ultima è il
--     residuo (imponibile - somma delle precedenti) — la somma degli
--     importo_imponibile torna sempre esatta anche con arrotondamenti.
--
--     NB non implementato qui (segnalato, non deciso): nessun vincolo impedisce
--     che preventivo_id punti a una riga invoices con tipo diverso da
--     'preventivo' — un CHECK non può leggere un'altra tabella; servirebbe un
--     trigger dedicato, non richiesto da questa fase. Il frontend (Fase 2)
--     comunque offrirà il piano tranche solo dalla schermata preventivo.
-- ----------------------------------------------------------------------------
create table public.quote_tranches (
    id                  uuid primary key default gen_random_uuid(),
    preventivo_id       uuid not null references public.invoices(id) on delete cascade,
    ordine              integer not null check (ordine > 0),
    descrizione         text not null,
    percentuale         numeric(5,2) not null check (percentuale > 0 and percentuale <= 100),
    -- fonte di verità dell'importo: valorizzata dal frontend al salvataggio del
    -- piano (round2(imponibile*percentuale/100) per le prime N-1, residuo per
    -- l'ultima), mai ricalcolata da qui in poi. Nessun default: un insert che
    -- se lo dimentica deve fallire rumorosamente, non silenziosamente a 0.
    importo_imponibile  numeric(12,2) not null,
    stato               text not null default 'da_fatturare'
                        check (stato in ('da_fatturare','proforma','fatturata')),
    -- documento generato da questa tranche. Nessun on delete: cancellare una
    -- proforma/fattura già legata a una tranche resta bloccato dalla FK per
    -- default (stesso comportamento restrittivo di invoices.convertito_da),
    -- non silenziato con un set null.
    proforma_id         uuid references public.invoices(id),
    fattura_id          uuid references public.invoices(id),
    created_at          timestamptz not null default now(),
    unique (preventivo_id, ordine)
);

create index idx_tranches_preventivo on public.quote_tranches(preventivo_id);
create index idx_tranches_proforma   on public.quote_tranches(proforma_id);
create index idx_tranches_fattura    on public.quote_tranches(fattura_id);

alter table public.quote_tranches enable row level security;

-- Stesso criterio di invoice_lines (sezione 7): accesso via l'emittente del
-- PREVENTIVO padre, non un criterio proprio.
create policy tranches_all on public.quote_tranches
    for all using ( exists (
        select 1 from public.invoices i
        where i.id = quote_tranches.preventivo_id and public.can_use_emitter(i.emitter_id)
    )) with check ( exists (
        select 1 from public.invoices i
        where i.id = quote_tranches.preventivo_id and public.can_use_emitter(i.emitter_id)
    ));

grant select, insert, update, delete on public.quote_tranches to authenticated;

-- Validazione somma percentuali = 100 per piano (preventivo_id). Difesa in
-- profondità: il frontend (Fase 2) blocca già il salvataggio se la somma non
-- torna; questo trigger è la rete di sicurezza lato DB — copre un eventuale
-- bug frontend, una scrittura diretta da SQL Editor, o una futura
-- integrazione che scriva su questa tabella senza passare dalla UI.
--
-- Trigger di VINCOLO (deferrable, initially deferred): una riga vista in
-- isolamento non somma mai 100 finché non sono state inserite tutte le righe
-- del piano nella stessa transazione. Un trigger FOR EACH ROW normale (non
-- deferred) fallirebbe già sul primo insert del batch. DEFERRABLE INITIALLY
-- DEFERRED sposta il controllo al COMMIT: il frontend inserisce tutte le
-- righe del piano in un'unica transazione (Fase 2), e solo alla fine si
-- verifica che la somma sia esattamente 100.
create or replace function public.check_tranche_percentuali()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_preventivo_id uuid := coalesce(new.preventivo_id, old.preventivo_id);
    v_somma         numeric(6,2);
    v_count         integer;
begin
    select count(*), coalesce(sum(percentuale), 0)
      into v_count, v_somma
      from public.quote_tranches
     where preventivo_id = v_preventivo_id;

    -- ultima riga del piano cancellata: nessun piano residuo da validare.
    if v_count = 0 then
        return null;
    end if;

    if v_somma <> 100 then
        raise exception
            'Piano tranche del preventivo %: la somma delle percentuali è %, deve essere 100',
            v_preventivo_id, v_somma
            using errcode = '23514'; -- check_violation
    end if;

    return null;
end;
$$;

create constraint trigger trg_tranche_percentuali
    after insert or update or delete on public.quote_tranches
    deferrable initially deferred
    for each row execute function public.check_tranche_percentuali();

-- ============================================================================
--  FINE STRATO FATTURAZIONE.
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
