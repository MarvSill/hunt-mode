-- Standort fix alle 5 s und Standortdaten bleiben erhalten:
-- 1. Alle Teilnehmenden senden ihren Standort immer alle 5 s (nicht mehr einstellbar). So kommen auch der
--    Nähe-Radar-Alarm und die Anzeige "nah / nicht mehr nah" nach wenigen Sekunden.
-- 2. Die aufgezeichneten Wege (für die Wiederholung) werden fix 30 Tage nach Spielende gelöscht (nicht mehr
--    einstellbar). Jeder Teilnehmende kann bei einem vergangenen Spiel "Für immer behalten" drücken, dann
--    bleibt dieses Spiel ganz erhalten. Wird ein Spiel gelöscht, verschwinden seine Daten wie bisher mit ihm.

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

-- Für immer behalten (je Spiel)
alter table public.games add column if not exists keep_forever boolean not null default false;

-- Nächtliches Löschen (pg_cron 03:17, aus 0007): fix 30 Tage, ausser das Spiel wird für immer behalten.
create or replace function public.purge_old_locations()
returns void language sql security definer set search_path = public as $$
  delete from public.location_samples s using public.games g
  where s.game_id = g.id and g.status in ('beendet', 'archiviert') and not g.keep_forever
    and g.ended_at < now() - interval '30 days';
$$;
revoke execute on function public.purge_old_locations() from public, anon, authenticated;

-- Knopf "Für immer behalten" / "Nicht mehr behalten": jeder Teilnehmende des Spiels, nur nach Spielende.
create or replace function public.set_keep_game(p_game_id uuid, p_keep boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or not public.is_game_member(p_game_id) then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if g.status not in ('beendet', 'archiviert') then raise exception 'Das geht erst nach Spielende.' using errcode = 'P0001'; end if;
  if not p_keep and g.ended_at < now() - interval '30 days' then
    raise exception 'Das Spiel ist älter als 30 Tage. Ohne "Für immer behalten" würde die Wiederholung sofort gelöscht.' using errcode = 'P0001';
  end if;
  update public.games set keep_forever = p_keep where id = p_game_id;
  return p_keep;
end; $$;
revoke execute on function public.set_keep_game(uuid, boolean) from public, anon;
grant execute on function public.set_keep_game(uuid, boolean) to authenticated;

-- Wiederholung: zusätzlich, ob das Spiel für immer behalten wird und wann es endete (zuletzt in 0023).
alter function public.game_replay(uuid) rename to game_replay_basis;
revoke execute on function public.game_replay_basis(uuid) from public, anon, authenticated;
create or replace function public.game_replay(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  return public.game_replay_basis(p_game_id) || jsonb_build_object('keep_forever', g.keep_forever, 'ended_at', g.ended_at);
end; $$;
revoke execute on function public.game_replay(uuid) from public, anon;
grant execute on function public.game_replay(uuid) to authenticated;
