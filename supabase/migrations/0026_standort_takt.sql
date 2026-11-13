-- Standort fix alle 5 s und Standortdaten bleiben erhalten:
-- 1. Alle Teilnehmenden senden ihren Standort immer alle 5 s (nicht mehr einstellbar). So kommen auch der
--    Nähe-Radar-Alarm und die Anzeige "nah / nicht mehr nah" nach wenigen Sekunden.
-- 2. Die Standortdaten werden nicht mehr nach einer Frist gelöscht (nächtliches Löschen entfernt).
--    Wird ein Spiel gelöscht, verschwinden seine Daten wie bisher mit ihm.

alter function public.report_location(uuid, jsonb) rename to report_location_basis;
revoke execute on function public.report_location_basis(uuid, jsonb) from public, anon, authenticated;

create or replace function public.report_location(p_game_id uuid, p_samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
begin
  v_res := public.report_location_basis(p_game_id, p_samples);
  if v_res ? 'interval_s' then
    v_res := v_res || jsonb_build_object('interval_s', 5);
  end if;
  return v_res;
end; $$;
revoke execute on function public.report_location(uuid, jsonb) from public, anon;
grant execute on function public.report_location(uuid, jsonb) to authenticated;

-- Nächtliches Löschen der Standortdaten entfernen.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'hunt-mode-purge') then
    perform cron.unschedule('hunt-mode-purge');
  end if;
end $$;
drop function if exists public.purge_old_locations();
