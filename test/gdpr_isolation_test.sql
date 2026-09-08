-- ============================================================================
--  TEST DI ISOLAMENTO GDPR — ripetibile, cinque scenari indipendenti
--
--  SCENARIO A: un utente con puo_fatturare=true (ma senza ruolo/associazione
--  GESPP che gliene darebbe accesso comunque) NON deve poter leggere le
--  tabelle sanitarie GESPP.
--
--  SCENARIO B: un utente "solo slot-booking" (consulente attivo,
--  puo_fatturare=false, NESSUN legame esplicito ad aziende/persone né a
--  emittenti) NON deve poter leggere né il sanitario né la fatturazione, ma
--  DEVE poter vedere il pool condiviso "Liberi Professionisti"
--  (booking_calendars con company_id null) — è il caso limite più severo
--  introdotto dalla migrazione di slot-booking (2026-09-07): verifica che il
--  terzo dominio non apra nessuna porta verso gli altri due, in nessuna
--  direzione.
--
--  SCENARIO C: la direzione POSITIVA dell'accesso aziende — A e B provano
--  solo che le porte si chiudono per chi non ha diritti, non che si aprono
--  per chi li ha. Un consulente CON un legame consultant_company verso
--  un'azienda X deve vedere X (controllo positivo) ma non una seconda
--  azienda Y a cui non è collegato (controllo negativo), e soprattutto: il
--  legame aziendale da solo non deve diventare una scorciatoia verso i dati
--  sanitari di una persona di X — serve anche il consenso attivo, non basta
--  l'appartenenza all'azienda.
--
--  SCENARIO D: isolamento del Calendar Work (tabelle wc_*, GESPP). A
--  differenza degli altri domini, un'attività di calendario NON referenzia
--  persons/companies — è un'attività personale del consulente, isolata per
--  proprietario e per taggatura, non per soggetto. Il punto critico qui non
--  è "vedo i dati sanitari di qualcuno" ma la GRANULARITÀ: un consulente
--  taggato su UN task di un collega non deve vedere automaticamente TUTTI
--  gli altri task di quello stesso collega — solo quello a cui è stato
--  esplicitamente taggato.
--
--  SCENARIO E: restrizione della vista aggregata v_spp_patologia_agg
--  (statistiche patologia × assi SPP), corretta il 2026-09-08 dopo un audit
--  che l'ha trovata leggibile da QUALUNQUE utente 'authenticated' senza
--  rispettare la RLS (security_invoker mancante, owner=postgres bypassa la
--  RLS come qualunque superuser). La regola voluta è più stretta della RLS
--  di health_records da sola: SOLO il ruolo amministratore vede l'aggregato,
--  con conteggi pieni e nessuna soppressione (chi accede ha comunque diritto
--  ai dati individuali sottostanti). Il punto critico non è "esistono dati
--  da vedere" ma la GRANULARITÀ del gate: un consulente_limitato E un
--  consulente normale (non limitato) CON un legame legittimo verso la
--  persona di prova (quindi già in grado di leggere il singolo
--  health_records via RLS ordinaria) devono comunque ottenere ZERO righe
--  dalla vista — solo passando a ruolo admin l'aggregato compare.
--
--  PREREQUISITO (una tantum per ambiente, non automatizzabile in SQL):
--    app_users.id referenzia auth.users(id) — un uuid inventato viola quel
--    vincolo di chiave esterna (visto empiricamente: ERROR 23503 su
--    app_users_id_fkey). Serve un vero utente Auth usa-e-getta:
--    Dashboard Supabase → Authentication → Users → Add user (email/password
--    a piacere, "Auto Confirm User" attivo). Copia il suo UUID: va incollato
--    UNA VOLTA PER SCRIPT al posto di 'INCOLLA-QUI-UUID-UTENTE-AUTH' (stesso
--    utente per tutti e tre gli scenari, riconfigurato di volta in volta —
--    non serve un secondo/terzo account Auth).
--
--  ESECUZIONE — CINQUE SCRIPT INDIPENDENTI, UNO ALLA VOLTA: sono cinque
--  blocchi separati (ciascuno begin...rollback) nello stesso file. Svuota
--  l'SQL Editor (Ctrl+A, Canc), incolla e lancia SOLO uno script, leggi
--  l'esito, svuota di nuovo l'editor, passa al successivo. Non incollarne
--  due insieme: con più SELECT in un'unica esecuzione l'editor mostra in
--  genere solo il risultato dell'ultima, e questo ne renderebbe invisibile
--  uno dei due.
--
--  Ogni script è autocontenuto: la riga in app_users, i suoi eventuali
--  legami, e persino i dati di prova per i controlli positivi (un emittente
--  per lo scenario A, un calendario "pool" per lo scenario B, due aziende +
--  una persona + un consenso revocato per lo scenario C, due task di
--  calendario di un altro consulente per lo scenario D, una persona con
--  consenso attivo + patologia + profilo SPP per lo scenario E) vivono dentro
--  un'UNICA transazione che viene SEMPRE annullata (rollback) alla fine,
--  indipendentemente dall'esito — zero residui nel database, si può
--  rilanciare quante volte serve. L'utente Auth stesso (in auth.users)
--  invece resta e va riusato o eliminato manualmente dal Dashboard quando
--  non serve più.
--
--  Il risultato di ciascuno script è UNA tabella con una riga per ogni
--  controllo — niente RAISE/messaggi da cercare, ogni riga dice da sola
--  cosa verifica e cosa si aspetta nella colonna "verifica".
--
--  ESITO ATTESO: ogni riga con "(atteso: 0)" deve avere valore '0', ogni
--  riga con "(atteso: true)" deve avere 'true', ogni riga con "(atteso:
--  false)" deve avere 'false'. In ciascuno script almeno una riga deve
--  essere MAGGIORE di zero — il/i controllo/i positivo/i, OBBLIGATORI: se
--  dessero 0, gli zeri sulle altre righe sarebbero un falso positivo
--  (sessione mal impersonata, non RLS che discrimina davvero), non una
--  prova che l'isolamento funziona:
--    - Scenario A: n_emitter_settings via emitter_read (public.can_bill()
--      concede la lettura di TUTTI gli emitter_settings, non solo i propri
--      — l'assegnazione operator_emitter regola solo la scrittura). Questa
--      è una vera SELECT filtrata da RLS, non una funzione scalare come
--      can_bill(): can_bill() da sola NON dimostra che l'impersonazione
--      stia leggendo dati sotto RLS, potrebbe dare true anche con sessione
--      rotta mentre le tabelle sanitarie danno 0 per tutt'altro motivo
--      (permission denied silenzioso, ruolo non cambiato davvero, ecc.) —
--      per questo compare comunque nel report come riga informativa, ma
--      il controllo positivo vero è la conta su emitter_settings.
--    - Scenario B: n_booking_calendars pool company_id null.
--    - Scenario C: vede l'azienda X (legame) e la persona dentro X
--      (can_access_person via il legame aziendale) — ma NON i dati sanitari
--      di quella persona, nonostante fisicamente esistano nella transazione.
--    - Scenario D: dopo essere taggato, vede il task su cui è taggato — ma
--      NON un secondo task dello stesso proprietario su cui non è taggato
--      (controllo di granularità: taggato sul task, non sul proprietario).
--    - Scenario E: da ruolo admin, vede la riga aggregata della patologia di
--      prova in v_spp_patologia_agg (numero_casi >= 1) — sia da
--      consulente_limitato sia da consulente normale con legame legittimo
--      (che vede già il singolo health_records) la vista deve dare 0 righe.
-- ============================================================================


-- ============================================================================
--  SCRIPT 1/3 — SCENARIO A
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- consulente_limitato è il ruolo GESPP con meno accesso sanitario tra quelli
-- esistenti (vedi ARCHITETTURA_SISTEMA_UNIFICATO.md — non esiste ancora un
-- ruolo "solo amministrativo" con zero accesso sanitario). on conflict:
-- se l'utente Auth ha già una riga app_users (es. creata da un trigger),
-- la riconfigura invece di fallire.
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation A',
        'test.gdpr.isolation.a@example.invalid', 'consulente_limitato', true, true)
on conflict (id) do update
    set ruolo = 'consulente_limitato', puo_fatturare = true, attivo = true;

-- Pulizia difensiva: niente assegnazioni residue da eventuali usi precedenti
-- di questo stesso utente Auth fuori da una transazione con rollback.
delete from public.operator_emitter   where operator_id   = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Autosufficienza: crea un emittente di prova, così il controllo positivo
-- (emitter_read: can_bill() vede TUTTI gli emitter_settings, non serve
-- operator_emitter) ha sempre qualcosa da trovare a prescindere da cosa
-- esiste già nel database reale. Il rollback finale lo rimuove.
insert into public.emitter_settings (denominazione, partita_iva)
values ('TEST isolamento GDPR — emittente di prova (auto-rimosso a fine test)', '00000000000');

-- Sessione impersonata come l'utente di test. Serve SIA il claim JWT SIA il
-- cambio di ruolo effettivo: l'SQL Editor si connette come postgres, che
-- bypassa la RLS a prescindere dai claim se non si cambia anche il ruolo.
set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('A. ruolo utente (atteso: consulente_limitato)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('A. can_bill() (atteso: true, informativo: non e di per se prova di RLS)', public.can_bill()::text),
    ('A. n_spp_profiles (atteso: 0)', (select count(*) from public.spp_profiles)::text),
    ('A. n_health_consents (atteso: 0)', (select count(*) from public.health_consents)::text),
    ('A. n_health_records (atteso: 0)', (select count(*) from public.health_records)::text),
    ('A. n_self_reports (atteso: 0)', (select count(*) from public.self_reports)::text),
    ('A. n_meetings (atteso: 0)', (select count(*) from public.meetings)::text),
    ('A. n_emitter_settings via emitter_read (ATTESO: maggiore di 0 - controllo positivo reale)', (select count(*) from public.emitter_settings)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, emittente di prova, ogni
          -- effetto collaterale. Zero residui, ripetibile quante volte serve.


-- ============================================================================
--  SCRIPT 2/3 — SCENARIO B (eseguire DOPO aver letto l'esito dello Script 1,
--  in un editor svuotato — non incollare di seguito allo Script 1)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- Utente "solo slot-booking": consulente attivo, senza puo_fatturare, senza
-- alcun legame esplicito ad aziende/persone né a emittenti. Deve vedere SOLO
-- il pool condiviso "Liberi Professionisti" e nient'altro. Riusa lo stesso
-- utente Auth usa-e-getta dello Script 1 — non serve un secondo account.
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation B',
        'test.gdpr.isolation.b@example.invalid', 'consulente', false, true)
on conflict (id) do update
    set ruolo = 'consulente', puo_fatturare = false, attivo = true;

delete from public.operator_emitter   where operator_id   = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Autosufficienza: crea un pool "Liberi Professionisti" di prova, così il
-- controllo positivo ha sempre qualcosa da trovare a prescindere da cosa
-- esiste già nel database reale. Il rollback finale lo rimuove insieme al
-- resto: zero pulizia manuale, sia in caso di successo sia di fallimento.
insert into public.booking_calendars (company_id, nome)
values (null, 'TEST isolamento GDPR — pool di prova (auto-rimosso a fine test)');

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('B. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('B. can_bill() (atteso: false)', public.can_bill()::text),
    ('B. n_spp_profiles (atteso: 0)', (select count(*) from public.spp_profiles)::text),
    ('B. n_health_consents (atteso: 0)', (select count(*) from public.health_consents)::text),
    ('B. n_health_records (atteso: 0)', (select count(*) from public.health_records)::text),
    ('B. n_self_reports (atteso: 0)', (select count(*) from public.self_reports)::text),
    ('B. n_meetings (atteso: 0)', (select count(*) from public.meetings)::text),
    ('B. n_emitter_settings (atteso: 0)', (select count(*) from public.emitter_settings)::text),
    ('B. n_invoices (atteso: 0)', (select count(*) from public.invoices)::text),
    ('B. n_invoice_lines (atteso: 0)', (select count(*) from public.invoice_lines)::text),
    ('B. n_companies (atteso: 0, identita condivisa non e accesso libero)', (select count(*) from public.companies)::text),
    ('B. n_booking_calendars pool company_id null (ATTESO: maggiore di 0 - controllo positivo)', (select count(*) from public.booking_calendars where company_id is null)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, pool di prova, ogni effetto
          -- collaterale. Zero residui, ripetibile quante volte serve.


-- ============================================================================
--  SCRIPT 3/3 — SCENARIO C (eseguire DOPO aver letto l'esito dello Script 2,
--  in un editor svuotato — non incollare di seguito agli script precedenti)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- puo_fatturare=false apposta: così l'unica via di accesso alle aziende
-- possibile è consultant_company (GESPP), non la policy di fatturazione
-- companies_billing_select (anch'essa a maglie larghe, can_bill()-gated,
-- che altrimenti contaminerebbe il controllo negativo su Y).
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation C',
        'test.gdpr.isolation.c@example.invalid', 'consulente', false, true)
on conflict (id) do update
    set ruolo = 'consulente', puo_fatturare = false, attivo = true;

delete from public.operator_emitter   where operator_id   = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Autosufficienza: due aziende di prova (X con legame, Y senza), una
-- persona dentro X, e un consenso sanitario REVOCATO per quella persona
-- (non assente: la riga esiste davvero, così il test dimostra che il
-- legame aziendale da solo non basta ad aggirare il gate del consenso
-- attivo — non solo che "non c'è nulla da vedere" per mancanza di dati).
-- Tutto rimosso dal rollback finale, incluse le righe di audit_log che i
-- trigger su persons/health_consents/health_records generano da soli.
with x as (
    insert into public.companies (ragione_sociale) values ('TEST isolamento GDPR — azienda X (con legame)') returning id
)
select set_config('test.company_x_id', id::text, true) from x;

with y as (
    insert into public.companies (ragione_sociale) values ('TEST isolamento GDPR — azienda Y (senza legame)') returning id
)
select set_config('test.company_y_id', id::text, true) from y;

insert into public.consultant_company (consultant_id, company_id)
values (current_setting('test.gdpr_user_id')::uuid, current_setting('test.company_x_id')::uuid);

with p as (
    insert into public.persons (tipo, nome, cognome, company_id)
    values ('dipendente', 'Test', 'Persona X', current_setting('test.company_x_id')::uuid)
    returning id
)
select set_config('test.person_x_id', id::text, true) from p;

with c as (
    -- chk_revoca: stato='revocato' richiede data_revoca valorizzata.
    insert into public.health_consents (person_id, testo_versione, stato, data_revoca)
    values (current_setting('test.person_x_id')::uuid, 'v1.0-test', 'revocato', now())
    returning id
)
select set_config('test.consent_x_id', id::text, true) from c;

insert into public.health_records (person_id, consent_id, data_rilevazione)
values (current_setting('test.person_x_id')::uuid, current_setting('test.consent_x_id')::uuid, current_date);

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('C. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('C. vede azienda X (ATTESO: 1 - controllo positivo, legame consultant_company)', (select count(*) from public.companies where id = current_setting('test.company_x_id')::uuid)::text),
    ('C. NON vede azienda Y (atteso: 0 - controllo negativo, nessun legame)', (select count(*) from public.companies where id = current_setting('test.company_y_id')::uuid)::text),
    ('C. vede la persona dentro X (atteso: 1, can_access_person via il legame aziendale)', (select count(*) from public.persons where id = current_setting('test.person_x_id')::uuid)::text),
    ('C. vede che esiste un consenso per quella persona (atteso: 1, sapere lo stato del consenso non e dato sanitario)', (select count(*) from public.health_consents where person_id = current_setting('test.person_x_id')::uuid)::text),
    ('C. NON vede i dati sanitari di quella persona (ATTESO: 0 - il legame aziendale da solo non basta, serve anche consenso attivo)', (select count(*) from public.health_records where person_id = current_setting('test.person_x_id')::uuid)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, aziende X/Y, persona, consenso e
          -- dato sanitario di prova, legame consultant_company, ogni
          -- effetto collaterale. Zero residui, ripetibile quante volte serve.


-- ============================================================================
--  SCRIPT 4/4 — SCENARIO D (eseguire DOPO aver letto l'esito dello Script 3,
--  in un editor svuotato — non incollare di seguito agli script precedenti)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- Consulente normale, senza puo_fatturare e senza legami — il ruolo esatto
-- non è rilevante per questo scenario (l'isolamento qui è per taggatura,
-- non per fatturazione), riusa lo stesso profilo minimale degli altri.
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation D',
        'test.gdpr.isolation.d@example.invalid', 'consulente', false, true)
on conflict (id) do update
    set ruolo = 'consulente', puo_fatturare = false, attivo = true;

delete from public.operator_emitter   where operator_id   = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.wc_task_operators  where operator_id   = current_setting('test.gdpr_user_id')::uuid;

-- Autosufficienza: individua un ALTRO consulente reale già esistente nel
-- sistema per usarlo come proprietario del task di prova — non lo
-- impersoniamo, serve solo come valore valido per owner_id (FK su
-- app_users), non tocchiamo nessun suo dato reale. Se il database ha un
-- solo app_user in tutto (solo il nostro utente di test), questo passo
-- restituisce null e l'insert successivo fallisce: serve almeno un
-- secondo consulente già presente.
select set_config('test.other_owner_id',
    (select id::text from public.app_users where id <> current_setting('test.gdpr_user_id')::uuid limit 1),
    true);

-- Due task di prova dello stesso "altro" proprietario: uno taggherà il
-- nostro utente di test, l'altro no — dimostra che la visibilità concessa
-- da wc_can_see_task() è per SINGOLO task, non "tutti i task di quel
-- proprietario una volta che ne vedi uno".
with tk1 as (
    insert into public.wc_tasks (owner_id, nome, data)
    values (current_setting('test.other_owner_id')::uuid, 'TEST isolamento calendario — sarà taggato (auto-rimosso)', current_date)
    returning id
)
select set_config('test.task_tagged_id', id::text, true) from tk1;

with tk2 as (
    insert into public.wc_tasks (owner_id, nome, data)
    values (current_setting('test.other_owner_id')::uuid, 'TEST isolamento calendario — resterà non taggato (auto-rimosso)', current_date)
    returning id
)
select set_config('test.task_untagged_id', id::text, true) from tk2;

-- Prima lettura: il nostro utente NON è ancora taggato da nessuna parte —
-- salviamo il risultato ora (non ancora taggato) per mostrarlo insieme a
-- quello finale in un'unica riga di report più sotto.
set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);
select set_config('test.pre_tag_tagged',   (select count(*) from public.wc_tasks where id = current_setting('test.task_tagged_id')::uuid)::text,   true);
select set_config('test.pre_tag_untagged', (select count(*) from public.wc_tasks where id = current_setting('test.task_untagged_id')::uuid)::text, true);

-- Ora tagghiamo il nostro utente SOLO sul primo task (come postgres: la
-- RLS di scrittura su wc_task_operators richiede di essere il proprietario
-- del task, non il nostro utente di test).
reset role;
insert into public.wc_task_operators (task_id, operator_id)
values (current_setting('test.task_tagged_id')::uuid, current_setting('test.gdpr_user_id')::uuid);

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('D. ruolo utente (atteso: consulente)', (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid)::text),
    ('D. can_bill() (atteso: false)', public.can_bill()::text),
    ('D. PRIMA di essere taggato: vedeva il task che sarebbe stato taggato (atteso: 0)', current_setting('test.pre_tag_tagged')),
    ('D. PRIMA di essere taggato: vedeva il task che resta non taggato (atteso: 0)', current_setting('test.pre_tag_untagged')),
    ('D. DOPO essere taggato: VEDE il task taggato (ATTESO: 1 - controllo positivo)', (select count(*) from public.wc_tasks where id = current_setting('test.task_tagged_id')::uuid)::text),
    ('D. DOPO essere taggato: NON vede il secondo task dello stesso proprietario (atteso: 0 - granularita per task, non per proprietario)', (select count(*) from public.wc_tasks where id = current_setting('test.task_untagged_id')::uuid)::text),
    ('D. n_spp_profiles (atteso: 0)', (select count(*) from public.spp_profiles)::text),
    ('D. n_health_consents (atteso: 0)', (select count(*) from public.health_consents)::text),
    ('D. n_health_records (atteso: 0)', (select count(*) from public.health_records)::text),
    ('D. n_self_reports (atteso: 0)', (select count(*) from public.self_reports)::text),
    ('D. n_meetings (atteso: 0)', (select count(*) from public.meetings)::text),
    ('D. n_emitter_settings (atteso: 0)', (select count(*) from public.emitter_settings)::text),
    ('D. n_invoices (atteso: 0)', (select count(*) from public.invoices)::text),
    ('D. n_invoice_lines (atteso: 0)', (select count(*) from public.invoice_lines)::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, entrambi i task di prova, la
          -- taggatura, ogni effetto collaterale (incluso sul consulente
          -- "altro" usato solo come proprietario). Zero residui, ripetibile
          -- quante volte serve.


-- ============================================================================
--  SCRIPT 5/5 — SCENARIO E (eseguire DOPO aver letto l'esito dello Script 4,
--  in un editor svuotato — non incollare di seguito agli script precedenti)
-- ============================================================================
begin;

select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- Partiamo da consulente_limitato: e il caso piu ovvio, gia escluso da
-- health_access via current_role() <> 'consulente_limitato'. Il ruolo viene
-- alzato progressivamente nello stesso script (limitato -> consulente pieno
-- con legame legittimo -> admin) per dimostrare che il gate della vista non
-- e la RLS di health_records (che un consulente pieno con legame supera
-- gia) ma la regola aggiuntiva is_admin() dentro la vista stessa.
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation E',
        'test.gdpr.isolation.e@example.invalid', 'consulente_limitato', false, true)
on conflict (id) do update
    set ruolo = 'consulente_limitato', puo_fatturare = false, attivo = true;

delete from public.operator_emitter   where operator_id   = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_company where consultant_id = current_setting('test.gdpr_user_id')::uuid;
delete from public.consultant_person  where consultant_id = current_setting('test.gdpr_user_id')::uuid;

-- Autosufficienza: azienda + persona + consenso ATTIVO + patologia + record
-- sanitario + profilo SPP di prova, così la vista ha davvero una riga da
-- aggregare (altrimenti uno zero non proverebbe nulla: potrebbe essere
-- "non c'è niente da vedere" invece di "il gate blocca l'accesso"). Il
-- nostro utente di test viene legato alla persona via consultant_person: da
-- consulente pieno (non limitato) avrebbe quindi accesso legittimo al
-- singolo health_records tramite la RLS ordinaria — il punto dello scenario
-- è che questo NON gli basta per vedere l'aggregato.
with x as (
    insert into public.companies (ragione_sociale) values ('TEST isolamento GDPR — azienda E (statistiche)') returning id
)
select set_config('test.company_e_id', id::text, true) from x;

with p as (
    insert into public.persons (tipo, nome, cognome, company_id)
    values ('dipendente', 'Test', 'Persona E', current_setting('test.company_e_id')::uuid)
    returning id
)
select set_config('test.person_e_id', id::text, true) from p;

insert into public.consultant_person (consultant_id, person_id)
values (current_setting('test.gdpr_user_id')::uuid, current_setting('test.person_e_id')::uuid);

with c as (
    insert into public.health_consents (person_id, testo_versione, stato)
    values (current_setting('test.person_e_id')::uuid, 'v1.0-test', 'attivo')
    returning id
)
select set_config('test.consent_e_id', id::text, true) from c;

with pat as (
    insert into public.pathologies (denominazione)
    values ('TEST isolamento GDPR — patologia scenario E (auto-rimossa)')
    returning id
)
select set_config('test.pathology_e_id', id::text, true) from pat;

insert into public.health_records (person_id, consent_id, pathology_id, data_rilevazione)
values (current_setting('test.person_e_id')::uuid, current_setting('test.consent_e_id')::uuid,
        current_setting('test.pathology_e_id')::uuid, current_date);

insert into public.spp_profiles (person_id, consultant_id, asse1_sessualita)
values (current_setting('test.person_e_id')::uuid, current_setting('test.gdpr_user_id')::uuid, 'TEST-asse1');

-- Lettura 1: come consulente_limitato.
set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);
select set_config('test.e_limitato_stats',
    (select count(*) from public.v_spp_patologia_agg
     where denominazione = 'TEST isolamento GDPR — patologia scenario E (auto-rimossa)')::text, true);
select set_config('test.e_limitato_health_records',
    (select count(*) from public.health_records where person_id = current_setting('test.person_e_id')::uuid)::text, true);

-- Alza il ruolo a consulente pieno (non limitato) — il legame
-- consultant_person resta quello di prima.
reset role;
update public.app_users set ruolo = 'consulente' where id = current_setting('test.gdpr_user_id')::uuid;

-- Lettura 2: come consulente pieno con legame legittimo.
set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);
select set_config('test.e_consulente_stats',
    (select count(*) from public.v_spp_patologia_agg
     where denominazione = 'TEST isolamento GDPR — patologia scenario E (auto-rimossa)')::text, true);
select set_config('test.e_consulente_health_records',
    (select count(*) from public.health_records where person_id = current_setting('test.person_e_id')::uuid)::text, true);

-- Alza il ruolo ad admin — controllo positivo obbligatorio.
reset role;
update public.app_users set ruolo = 'admin' where id = current_setting('test.gdpr_user_id')::uuid;

set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

select verifica, valore from (values
    ('E. n_v_spp_patologia_agg da consulente_limitato (atteso: 0 - gate is_admin())', current_setting('test.e_limitato_stats')),
    ('E. n_health_records da consulente_limitato (atteso: 0 - health_access esclude questo ruolo)', current_setting('test.e_limitato_health_records')),
    ('E. n_v_spp_patologia_agg da consulente pieno con legame legittimo (ATTESO: 0 - la vista e piu restrittiva della RLS di health_records)', current_setting('test.e_consulente_stats')),
    ('E. n_health_records da consulente pieno con legame legittimo (atteso: 1 - vede gia il dato individuale via RLS ordinaria, a riprova che la restrizione sulla vista e una regola aggiuntiva, non un effetto collaterale di dati mancanti)', current_setting('test.e_consulente_health_records')),
    ('E. n_v_spp_patologia_agg da admin (ATTESO: maggiore o uguale a 1 - controllo positivo, la patologia di prova e visibile)',
        (select count(*) from public.v_spp_patologia_agg
         where denominazione = 'TEST isolamento GDPR — patologia scenario E (auto-rimossa)')::text)
) as t(verifica, valore);

rollback; -- annulla TUTTO: utente di test, azienda/persona/consenso/
          -- patologia/record sanitario/profilo SPP di prova, legame
          -- consultant_person, ogni cambio di ruolo. Zero residui,
          -- ripetibile quante volte serve.
