-- 0023: Rückmeldungen aus dem zweiten Testspiel
-- 1. Der Host kann das Spiel pausieren (die Zeit hält an) und während der Pause Einstellungen ändern.
-- 2. Der Vorsprung startet erst, wenn alle Spieler und Hunter den Sicherheitshinweis bestätigt haben
--    (der Host kann notfalls trotzdem starten).
-- 3. Fang: lehnt der Spieler einen gemeldeten Fang ab, gilt er nicht.
-- 4. Abgebrochenes Spiel: keiner hat gewonnen.
-- 5. Wiederholung: der ganze Weg aller Personen (ab Spielstart, fein aufgelöst), nicht nur die Pings.
-- 6. Eigene Spiel-Varianten speichern.

alter table public.games add column if not exists pause_kind text;
alter table public.participants add column if not exists safety_ok_at timestamptz;

-- ---------------------------------------------------------------------------
-- Fortsetzen nach einer Pause: alle Zeiten um die Pause verschieben.
-- p_kind: 'notfall' (SOS), 'host' (Pause durch den Host), 'sicherheit' (Warten auf den Sicherheitshinweis).
create or replace function public.resume_shift(p_game_id uuid, p_title text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_now timestamptz;
  d interval;
begin
  select * into g from public.games where id = p_game_id for update;
  if g.paused_at is null then return; end if;
  v_now := public.engine_now(p_game_id);
  d := v_now - g.paused_at;
  update public.games set paused_at = null, pause_reason = null, pause_kind = null, last_tick_at = v_now,
    -- Wartet das Spiel auf den Sicherheitshinweis, beginnt es erst jetzt richtig.
    start_at = case when g.pause_kind = 'sicherheit' then start_at + d else start_at end,
    hunt_start_at = case when status = 'vorsprung' then hunt_start_at + d else hunt_start_at end,
    ends_at = ends_at + d,
    deadline_at = deadline_at + d,
    exit_reveal_at = exit_reveal_at + d,
    next_day_at = next_day_at + d,
    state_json = case when g.pause_kind = 'sicherheit' then state_json
      else state_json || jsonb_build_object('paused_s', coalesce((state_json ->> 'paused_s')::int, 0) + extract(epoch from d)::int) end
  where id = p_game_id;
  update public.participants set next_ping_at = next_ping_at + d, ping_pending_until = ping_pending_until + d,
    grace_until = grace_until + d, out_pending_since = out_pending_since + d, stationary_since = stationary_since + d,
    speeding_since = speeding_since + d, transport_prompted_at = transport_prompted_at + d,
    restricted_since = restricted_since + d
  where game_id = p_game_id;
  update public.speedhunts set deadline_at = deadline_at + d where game_id = p_game_id and status = 'laeuft';
  update public.active_effects set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.live_windows set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.violations set auto_apply_at = auto_apply_at + d where game_id = p_game_id and status = 'offen';
  update public.catches set expires_at = expires_at + d where game_id = p_game_id and expires_at > g.paused_at;
  update public.games set state_json = jsonb_set(state_json, '{next_phase_at}', to_jsonb((state_json ->> 'next_phase_at')::timestamptz + d))
    where id = p_game_id and (state_json ->> 'next_phase_at') is not null;
  update public.zones set visible_from = visible_from + d where game_id = p_game_id and visible_from > g.paused_at and visible_from <> 'infinity';
  perform public.notify(p_game_id, 'alle', null, 'resume', p_title, p_body, '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'resumed', jsonb_build_object('seconds', extract(epoch from d)::int, 'kind', coalesce(g.pause_kind, 'notfall')));
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.resume_shift(uuid, text, text) from public, anon, authenticated;

-- Nach einem Notfall geht es nur weiter, wenn das Spiel wegen des Notfalls unterbrochen war
-- (eine Pause des Hosts oder das Warten auf den Sicherheitshinweis bleibt bestehen).
create or replace function public.resume_internal(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.games where id = p_game_id and pause_kind is not null) then return; end if;
  perform public.resume_shift(p_game_id, 'Weiter geht''s!', 'Der Notfall ist beendet. Das Spiel läuft wieder, die unterbrochene Zeit wird angehängt.');
end; $$;
revoke execute on function public.resume_internal(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Pause durch den Host
create or replace function public.host_pause(p_game_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat, kann pausieren.' using errcode = '42501'; end if;
  perform public.tick_game(p_game_id);
  select * into g from public.games where id = p_game_id for update;
  if g.status not in ('vorsprung', 'laeuft', 'finale') then raise exception 'Das Spiel läuft nicht.' using errcode = 'P0001'; end if;
  if g.paused_at is not null then raise exception 'Das Spiel ist schon unterbrochen.' using errcode = 'P0001'; end if;
  update public.games set paused_at = public.engine_now(p_game_id), pause_kind = 'host',
    pause_reason = coalesce(nullif(trim(p_reason), ''), 'Pause') where id = p_game_id;
  perform public.notify(p_game_id, 'alle', null, 'pause', 'Spiel pausiert',
    'Der Host hat das Spiel angehalten' || coalesce(': ' || nullif(trim(p_reason), ''), '') || '. Die Zeit steht still, bis es weitergeht.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'paused', jsonb_build_object('reason', p_reason, 'kind', 'host'));
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.host_pause(uuid, text) from public, anon;
grant execute on function public.host_pause(uuid, text) to authenticated;

create or replace function public.host_resume(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat, kann fortsetzen.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is null then return; end if;
  if g.pause_kind is distinct from 'host' then raise exception 'Das Spiel ist nicht vom Host pausiert.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.emergencies where game_id = p_game_id and status = 'offen') then
    raise exception 'Es läuft noch ein Notfall. Zuerst den Notfall beenden.' using errcode = 'P0001';
  end if;
  perform public.resume_shift(p_game_id, 'Weiter geht''s!', 'Der Host hat das Spiel fortgesetzt. Die Pause wird hinten angehängt.');
end; $$;
revoke execute on function public.host_resume(uuid) from public, anon;
grant execute on function public.host_resume(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Sicherheitshinweis: jede Person bestätigt ihn. Vorher startet der Vorsprung nicht.
create or replace function public.safety_missing(p_game_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.participants
  where game_id = p_game_id and role in ('spieler', 'hunter', 'zentrale') and safety_ok_at is null;
$$;
revoke execute on function public.safety_missing(uuid) from public, anon, authenticated;

create or replace function public.safety_confirm(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id);
  update public.participants set safety_ok_at = coalesce(safety_ok_at, now()) where id = v_me.id;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is not null and g.pause_kind = 'sicherheit' and public.safety_missing(p_game_id) = 0 then
    perform public.resume_shift(p_game_id, 'Los geht''s!', 'Alle haben den Sicherheitshinweis bestätigt. Der Vorsprung läuft.');
  end if;
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.safety_confirm(uuid) from public, anon;
grant execute on function public.safety_confirm(uuid) to authenticated;

-- Notfalls startet der Host ohne die fehlenden Bestätigungen.
create or replace function public.safety_force_start(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is null or g.pause_kind is distinct from 'sicherheit' then return; end if;
  perform public.log_game_event(p_game_id, 'safety_forced', jsonb_build_object('missing', public.safety_missing(p_game_id)));
  perform public.resume_shift(p_game_id, 'Los geht''s!', 'Der Host hat das Spiel gestartet. Der Vorsprung läuft.');
end; $$;
revoke execute on function public.safety_force_start(uuid) from public, anon;
grant execute on function public.safety_force_start(uuid) to authenticated;

-- Start: fehlt noch eine Bestätigung, wartet das Spiel (die Zeit steht still).
alter function public.start_game(uuid, boolean) rename to start_game_zeiten;
revoke execute on function public.start_game_zeiten(uuid, boolean) from public, anon, authenticated;

create or replace function public.start_game(p_game_id uuid, p_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
  v_missing int;
begin
  v_res := public.start_game_zeiten(p_game_id, p_test);
  v_missing := public.safety_missing(p_game_id);
  if v_missing > 0 then
    update public.games set paused_at = public.engine_now(p_game_id), pause_kind = 'sicherheit',
      pause_reason = 'Warten auf den Sicherheitshinweis' where id = p_game_id;
    perform public.notify(p_game_id, 'alle', null, 'safety_wait', 'Bitte Sicherheitshinweis bestätigen',
      'Der Vorsprung startet, sobald alle Spieler und Hunter den Hinweis gelesen und bestätigt haben.', '{}', 'kritisch');
    perform public.bump(p_game_id);
  end if;
  return v_res || jsonb_build_object('waiting_for_safety', v_missing);
end; $$;
revoke execute on function public.start_game(uuid, boolean) from public, anon;
grant execute on function public.start_game(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Regeln ändern: vor dem Start oder während einer Pause des Hosts (dann werden die Zeiten neu berechnet).
create or replace function public.update_game_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_change jsonb;
  g public.games;
  v_total int;
  v_head int;
  v_reveal int;
  v_paused int;
  v_ends timestamptz;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Regeln ändern.' using errcode = '42501';
  end if;
  select * into g from public.games where id = p_game_id for update;
  if g.status in ('entwurf', 'geplant', 'lobby') then
    update public.games
    set config_json = p_config, timezone = coalesce(p_config #>> '{game,timezone}', timezone), updated_at = now()
    where id = p_game_id;
  elsif g.status in ('vorsprung', 'laeuft', 'finale') and g.paused_at is not null and g.pause_kind = 'host' then
    v_total := public.cfg_int(p_config, 'game', 'duration_minutes', 180);
    v_head := public.cfg_int(p_config, 'start', 'head_start_minutes', 0);
    v_paused := coalesce((g.state_json ->> 'paused_s')::int, 0);
    v_reveal := least(public.cfg_int(p_config, 'exit', 'reveal_minutes_before_end', 20), v_total - v_head);
    v_ends := g.start_at + make_interval(mins => v_total, secs => v_paused);
    if v_ends < g.paused_at + interval '5 minutes' then
      raise exception 'Die Spielzeit ist zu kurz: es sind schon % min gespielt.',
        floor(extract(epoch from (g.paused_at - g.start_at)) / 60 - v_paused / 60.0)::int using errcode = 'P0001';
    end if;
    if g.status = 'vorsprung' and g.start_at + make_interval(mins => v_head, secs => v_paused) < g.paused_at then
      raise exception 'Der Vorsprung ist schon länger gelaufen.' using errcode = 'P0001';
    end if;
    update public.games set config_json = p_config, updated_at = now(),
      ends_at = v_ends, deadline_at = v_ends,
      hunt_start_at = case when status = 'vorsprung' then start_at + make_interval(mins => v_head, secs => v_paused) else hunt_start_at end,
      exit_reveal_at = case when exit_revealed then exit_reveal_at
        when public.cfg_bool(p_config, 'exit', 'enabled', true) then v_ends - make_interval(mins => v_reveal) end
    where id = p_game_id;
    perform public.notify(p_game_id, 'alle', null, 'config_changed', 'Regeln geändert',
      'Der Host hat während der Pause die Einstellungen angepasst. Schau unter „Regeln“ nach.', '{}', 'hoch');
  elsif g.status in ('vorsprung', 'laeuft', 'finale') then
    raise exception 'Regeln lassen sich im laufenden Spiel nur während einer Pause ändern.' using errcode = 'P0001';
  else
    raise exception 'Die Regeln lassen sich nach dem Start nicht mehr ändern.' using errcode = 'P0001';
  end if;
  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value)
    values (p_game_id, auth.uid(), v_change ->> 'path', v_change -> 'old', v_change -> 'new');
  end loop;
  perform public.log_game_event(p_game_id, 'config_changed', jsonb_build_object('changes', jsonb_array_length(coalesce(p_changes, '[]'::jsonb))));
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Fang: lehnt der Spieler ab, gilt der Fang nicht. Der Hunter kann dann den Zahlencode verlangen.
create or replace function public.catch_respond(p_catch_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.catches;
  v_me public.participants;
  g public.games;
begin
  select * into v_c from public.catches where id = p_catch_id;
  if v_c.id is null then raise exception 'Fang nicht gefunden.' using errcode = 'P0001'; end if;
  v_me := public.require_participant(v_c.game_id);
  g := public.require_running(v_c.game_id, true);
  if v_c.status <> 'wartet_auf_bestaetigung' then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  if v_me.id <> v_c.runner_id then raise exception 'Nur die gefangene Person.' using errcode = '42501'; end if;
  if p_accept then
    perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
  else
    update public.catches set status = 'abgelehnt', reason = 'Vom Spieler abgelehnt', expires_at = null where id = v_c.id;
    perform public.notify(g.id, null, v_c.hunter_id, 'catch_rejected', 'Fang abgelehnt',
      public.pname(v_c.runner_id) || ' sagt, es war kein Fang. Lass dir den Fang-Code zeigen und gib ihn ein.', '{}', 'hoch');
  end if;
  perform public.bump(g.id);
end; $$;

-- ---------------------------------------------------------------------------
-- Spiel abgebrochen: keiner hat gewonnen, niemand verliert.
alter function public.finish_game(public.games, timestamptz, text) rename to finish_game_basis;
revoke execute on function public.finish_game_basis(public.games, timestamptz, text) from public, anon, authenticated;

create or replace function public.finish_game(p_game public.games, p_now timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sh public.speedhunts;
begin
  if p_reason is distinct from 'abgebrochen' then
    perform public.finish_game_basis(p_game, p_now, p_reason);
    return;
  end if;
  if p_game.status = 'beendet' then return; end if;
  for v_sh in select * from public.speedhunts where game_id = p_game.id and status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') loop
    perform public.end_speedhunt(p_game, v_sh, 'spielende', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);
  update public.active_effects set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);
  update public.games set status = 'beendet', ended_at = p_now, paused_at = null, pause_kind = null, result_json = jsonb_build_object(
    'reason', 'abgebrochen', 'winners', '[]'::jsonb, 'mode', public.cfg_text(p_game.config_json, 'win', 'mode', 'alle_ueberlebenden'),
    'scores', '{}'::jsonb,
    'hours', round((extract(epoch from (p_now - coalesce(p_game.hunt_start_at, p_now))) / 3600.0)::numeric, 2),
    'catches', (select count(*) from public.catches where game_id = p_game.id and status = 'gueltig'),
    'pings', (select count(*) from public.pings where game_id = p_game.id),
    'speedhunts', (select count(*) from public.speedhunts where game_id = p_game.id and started_at is not null)
  ) where id = p_game.id;
  perform public.notify(p_game.id, 'alle', null, 'game_end', 'Spiel abgebrochen', 'Keiner hat gewonnen.', jsonb_build_object('reason', 'abgebrochen'), 'hoch');
  perform public.log_game_event(p_game.id, 'game_ended', jsonb_build_object('reason', 'abgebrochen'));
end; $$;
revoke execute on function public.finish_game(public.games, timestamptz, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Wiederholung: der ganze Weg ab Spielstart, ein Punkt alle 10 s.
create or replace function public.game_replay(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if not public.is_game_member(p_game_id) then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if g.status not in ('beendet', 'archiviert') then
    raise exception 'Die Wiederholung gibt es erst nach Spielende.' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'start', coalesce(g.start_at, g.hunt_start_at), 'hunt_start', g.hunt_start_at, 'end', coalesce(g.ended_at, now() + g.clock_offset),
    'tracks', (
      select coalesce(jsonb_object_agg(pid, pts), '{}') from (
        select participant_id pid, jsonb_agg(jsonb_build_array(b, round(lat::numeric, 6), round(lng::numeric, 6)) order by b) pts
        from (
          select distinct on (participant_id, floor(extract(epoch from at) / 10)) participant_id,
                 (floor(extract(epoch from at) / 10) * 10)::bigint b, ST_Y(geom) lat, ST_X(geom) lng
          from public.location_samples
          where game_id = p_game_id and not is_mock and coalesce(accuracy_m, 0) <= 100
          order by participant_id, floor(extract(epoch from at) / 10), accuracy_m nulls last, at desc
        ) s group by participant_id
      ) t
    ),
    'pings', (select coalesce(jsonb_agg(jsonb_build_object('participant_id', participant_id, 'at', at, 'lat', lat, 'lng', lng, 'source', source, 'is_fake', is_fake) order by at), '[]')
              from public.pings where game_id = p_game_id and lat is not null),
    'catches', (select coalesce(jsonb_agg(jsonb_build_object('runner_id', runner_id, 'hunter_id', hunter_id, 'at', at, 'lat', lat, 'lng', lng)), '[]')
                from public.catches where game_id = p_game_id and status = 'gueltig'),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'type', type, 'payload', payload_json) order by at), '[]')
               from public.game_events where game_id = p_game_id)
  );
end; $$;

-- ---------------------------------------------------------------------------
-- Spielstand: Art der Pause und wer den Sicherheitshinweis noch nicht bestätigt hat.
alter function public.game_state(uuid) rename to game_state_basis;
revoke execute on function public.game_state_basis(uuid) from public, anon, authenticated;

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v jsonb;
  g public.games;
  me public.participants;
begin
  v := public.game_state_basis(p_game_id);
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  v := jsonb_set(v, '{game,pause_kind}', coalesce(to_jsonb(case when g.paused_at is not null then coalesce(g.pause_kind, 'notfall') end), 'null'::jsonb));
  v := jsonb_set(v, '{me,safety_ok}', to_jsonb(me.safety_ok_at is not null));
  v := v || jsonb_build_object('safety_missing', (
    select coalesce(jsonb_agg(p.id), '[]') from public.participants p
    where p.game_id = p_game_id and p.role in ('spieler', 'hunter', 'zentrale') and p.safety_ok_at is null));
  return v;
end; $$;
revoke execute on function public.game_state(uuid) from public, anon;
grant execute on function public.game_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Eigene Spiel-Varianten (nur für die Person, die sie gespeichert hat).
create table if not exists public.config_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  config_json jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists config_templates_user_idx on public.config_templates (user_id, created_at desc);
alter table public.config_templates enable row level security;
drop policy if exists "Varianten: eigene" on public.config_templates;
create policy "Varianten: eigene" on public.config_templates for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.config_templates to authenticated;
