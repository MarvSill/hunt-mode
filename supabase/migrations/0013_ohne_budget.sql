-- Budget ist ganz entfernt: keine Käufe, kein Kauf-Ping, keine Beträge.
-- Noch nicht gestartete Spiele bekommen das Budget ausgeschaltet; Käufe melden ist gesperrt.

update public.games
  set config_json = config_json || '{"budget": {"enabled": false}}'::jsonb
  where status in ('entwurf', 'geplant', 'lobby');

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'make_purchase'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;
