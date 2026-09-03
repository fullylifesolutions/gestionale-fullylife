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
    numero          text not null,              -- es. FATT-002-2026
    data            date not null default current_date,
    scadenza        date,
    aliquota_iva    numeric(5,2) not null default 0,
    imponibile      numeric(12,2) not null default 0,
    imposta         numeric(12,2) not null default 0,
    totale          numeric(12,2) not null default 0,
    note            text,
    -- stati (dal frontend: status, pagato, archiviato)
    stato           text not null default 'bozza'
                    check (stato in ('bozza','emesso','pagato','annullato')),
    pagato          boolean not null default false,
    archiviato      boolean not null default false,
    -- tracciamento conversione (preventivo->proforma->fattura)
    convertito_da   uuid references public.invoices(id),
    created_by      uuid references public.app_users(id),
    created_at      timestamptz not null default now(),

    constraint chk_invoice_subject check (
        (company_id is not null and person_id is null) or
        (company_id is null and person_id is not null)
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
-- 6. CATALOGO SERVIZI — prodotti/servizi riutilizzabili (mp_shared_products)
--    Condiviso, come nel gestionale attuale.
-- ----------------------------------------------------------------------------
create table public.service_catalog (
    id              uuid primary key default gen_random_uuid(),
    nome            text not null,
    descrizione     text,
    prezzo          numeric(12,2) not null default 0,
    unita_misura    text default 'ora',
    categoria       text,
    created_at      timestamptz not null default now()
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

-- emitter_settings: admin gestisce tutto; chi fattura legge
create policy emitter_read on public.emitter_settings
    for select using (public.can_bill() or public.is_admin());
create policy emitter_admin_write on public.emitter_settings
    for all using (public.is_admin()) with check (public.is_admin());

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

-- service_catalog: chi fattura legge/scrive
create policy catalog_read on public.service_catalog
    for select using (public.can_bill());
create policy catalog_write on public.service_catalog
    for all using (public.can_bill()) with check (public.can_bill());

-- GRANT di base (la RLS filtra le righe)
grant select, insert, update, delete on
    public.emitter_settings, public.operator_emitter, public.billing_profiles,
    public.billing_counters, public.invoices, public.invoice_lines, public.service_catalog
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
--  FINE STRATO FATTURAZIONE.
--  Da verificare dopo l'esecuzione:
--   - che can_bill() NON apra alcun accesso a health_records (test GDPR)
-- ============================================================================
