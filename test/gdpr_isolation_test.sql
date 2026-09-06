-- ============================================================================
--  TEST DI ISOLAMENTO GDPR — ripetibile
--
--  Verifica il vincolo critico di CLAUDE.md: un utente con puo_fatturare=true
--  (ma senza ruolo/associazione GESPP che gliene darebbe accesso comunque)
--  NON deve poter leggere le tabelle sanitarie GESPP.
--
--  PREREQUISITO (una tantum per ambiente, non automatizzabile in SQL):
--    app_users.id referenzia auth.users(id) — un uuid inventato viola quel
--    vincolo di chiave esterna (visto empiricamente: ERROR 23503 su
--    app_users_id_fkey). Serve un vero utente Auth usa-e-getta:
--    Dashboard Supabase → Authentication → Users → Add user (email/password
--    a piacere, "Auto Confirm User" attivo). Copia il suo UUID e sostituiscilo
--    qui sotto al posto di 'INCOLLA-QUI-UUID-UTENTE-AUTH'.
--
--  Il resto è autocontenuto: la riga in app_users e il cambio di ruolo
--  vivono dentro una transazione che viene SEMPRE annullata (rollback) alla
--  fine, indipendentemente dall'esito — non lascia dati residui in
--  app_users/operator_emitter, si può rilanciare quante volte serve.
--  L'utente Auth stesso (in auth.users) invece resta e va riusato o
--  eliminato manualmente dal Dashboard quando non serve più.
--
--  Esecuzione: incollare per intero nel SQL Editor Supabase (o psql) come
--  utente con privilegi sufficienti (es. postgres) e lanciare in un colpo
--  solo. Niente RAISE/messaggi da cercare: l'ultima query restituisce
--  UNA riga con tutti i valori che servono per giudicare l'esito.
--
--  ESITO ATTESO sull'unica riga restituita:
--    - ruolo_utente_test = 'consulente_limitato' (non 'admin', altrimenti il
--      test non è significativo — l'admin bypassa tutto per design)
--    - n_spp_profiles, n_health_consents, n_health_records, n_self_reports,
--      n_meetings TUTTI a 0 — questo è il vincolo critico da verificare
--    - can_bill = true — controllo di contrasto: se fosse false, gli zeri
--      sopra sarebbero un falso positivo (sessione mal configurata, non RLS
--      che funziona davvero)
-- ============================================================================

begin;

-- Sostituisci con l'uuid del vero utente Auth creato come da prerequisito sopra.
select set_config('test.gdpr_user_id', 'INCOLLA-QUI-UUID-UTENTE-AUTH', true);

-- Utente di test: consulente_limitato + puo_fatturare = true.
-- consulente_limitato è il ruolo GESPP con meno accesso sanitario tra quelli
-- esistenti (vedi ARCHITETTURA_SISTEMA_UNIFICATO.md — non esiste ancora un
-- ruolo "solo amministrativo" con zero accesso sanitario). on conflict:
-- se l'utente Auth ha già una riga app_users (es. creata da un trigger),
-- la riconfigura invece di fallire.
insert into public.app_users (id, nome, cognome, email, ruolo, puo_fatturare, attivo)
values (current_setting('test.gdpr_user_id')::uuid, 'Test', 'GDPR Isolation',
        'test.gdpr.isolation@example.invalid', 'consulente_limitato', true, true)
on conflict (id) do update
    set ruolo = 'consulente_limitato', puo_fatturare = true, attivo = true;

-- Sessione impersonata come l'utente di test. Serve SIA il claim JWT SIA il
-- cambio di ruolo effettivo: l'SQL Editor si connette come postgres, che
-- bypassa la RLS a prescindere dai claim se non si cambia anche il ruolo.
set local role authenticated;
select set_config(
    'request.jwt.claims',
    json_build_object('sub', current_setting('test.gdpr_user_id'), 'role', 'authenticated')::text,
    true
);

-- UNICA riga con tutto il necessario per giudicare l'esito (vedi header).
select
    (select ruolo from public.app_users where id = current_setting('test.gdpr_user_id')::uuid) as ruolo_utente_test,
    (select count(*) from public.spp_profiles)     as n_spp_profiles,
    (select count(*) from public.health_consents)  as n_health_consents,
    (select count(*) from public.health_records)   as n_health_records,
    (select count(*) from public.self_reports)     as n_self_reports,
    (select count(*) from public.meetings)         as n_meetings,
    (select count(*) from public.emitter_settings) as n_emitter_settings,
    public.can_bill()                              as can_bill;

rollback; -- annulla SEMPRE: utente di test e ogni effetto collaterale, zero residui.
