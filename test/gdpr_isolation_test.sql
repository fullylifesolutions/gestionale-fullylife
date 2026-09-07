-- ============================================================================
--  TEST DI ISOLAMENTO GDPR — ripetibile, tre scenari indipendenti
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
--  ESECUZIONE — TRE SCRIPT INDIPENDENTI, UNO ALLA VOLTA: sono tre blocchi
--  separati (ciascuno begin...rollback) nello stesso file. Svuota l'SQL
--  Editor (Ctrl+A, Canc), incolla e lancia SOLO uno script, leggi l'esito,
--  svuota di nuovo l'editor, passa al successivo. Non incollarne due insieme:
--  con più SELECT in un'unica esecuzione l'editor mostra in genere solo il
--  risultato dell'ultima, e questo ne renderebbe invisibile uno dei due.
--
--  Ogni script è autocontenuto: la riga in app_users, i suoi eventuali
--  legami, e persino i dati di prova per i controlli positivi (un emittente
--  per lo scenario A, un calendario "pool" per lo scenario B, due aziende +
--  una persona + un consenso revocato per lo scenario C) vivono dentro
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
