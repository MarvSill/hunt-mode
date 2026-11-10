-- 0022: Rückmeldungen aus dem Testspiel
-- 1. Spielzeit gilt alles inklusive: vom Start (mit Vorsprung) bis zum Ende, ohne Nachspielzeit.
-- 2. Nach dem Vorsprung kommt sofort ein Ping (kein "Erster Ping nach …" mehr).
-- 3. Fluchtpunkt: Bekanntgabe X min vor Schluss, nutzbar erst Y min vor Schluss (bis Spielende).
-- 4. Blitzjagd: beim Start gleich die erste Abfrage; nie zweimal hintereinander dieselbe Person.
-- 5. Countdown ausserhalb des Spielfelds läuft auch ab, wenn das Handy gerade keinen neuen Standort schickt.
-- 6. Spieler haben Buchstaben (A, B, C …), damit die Pings nummeriert werden können (A1, A2 …).
-- 7. Vergangene Spiele löschen.

-- Länge der Jagd (Spielzeit ohne Vorsprung), mindestens 5 min.
create or replace function public.hunt_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select greatest(5, public.cfg_int(p_cfg, 'game', 'duration_minutes', 180) - public.cfg_int(p_cfg, 'start', 'head_start_minutes', 0));
$$;

-- Phasen der Verkleinerung passen in die Jagd (nach dem Vorsprung).
create or replace function public.phase_count(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.shrink_every_minutes(p_cfg) > 0
    then least(50, greatest(1, ceil(public.hunt_minutes(p_cfg)::numeric / public.shrink_every_minutes(p_cfg))::int))
    else public.cfg_int(p_cfg, 'game', 'days', 4) end;
$$;

-- Nutzbar ab so vielen Minuten vor Schluss (höchstens so viel wie die Bekanntgabe).
create or replace function public.exit_usable_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select least(public.cfg_int(p_cfg, 'exit', 'reveal_minutes_before_end', 20),
               greatest(0, public.cfg_int(p_cfg, 'exit', 'usable_minutes_before_end', 2)));
$$;

create or replace function public.exit_active(p_game public.games, p_now timestamptz)
returns boolean language sql stable as $$
  select p_game.exit_revealed and p_game.ends_at is not null
     and p_now >= p_game.ends_at - make_interval(mins => public.exit_usable_minutes(p_game.config_json));
$$;

-- ---------------------------------------------------------------------------
-- Start: Zeiten neu berechnen (alles inklusive), Spieler bekommen Buchstaben.
alter function public.start_game(uuid, boolean) rename to start_game_basis;
revoke execute on function public.start_game_basis(uuid, boolean) from public, anon, authenticated;

create or replace function public.start_game(p_game_id uuid, p_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_total int;
  v_head int;
  v_reveal int;
  v_z public.zones;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null then raise exception 'Spiel nicht gefunden.' using errcode = 'P0001'; end if;
  v_cfg := g.config_json;
  v_total := public.cfg_int(v_cfg, 'game', 'duration_minutes', 180);
  v_head := public.cfg_int(v_cfg, 'start', 'head_start_minutes', 0);
  if v_head > v_total - 5 then
    raise exception 'Der Vorsprung muss mindestens 5 min kürzer sein als die Spielzeit.' using errcode = 'P0001';
  end if;

  perform public.start_game_basis(p_game_id, p_test);

  select * into g from public.games where id = p_game_id for update;
  v_reveal := least(public.cfg_int(v_cfg, 'exit', 'reveal_minutes_before_end', 20), v_total - v_head);
  update public.games set
    ends_at = start_at + make_interval(mins => v_total),
    deadline_at = start_at + make_interval(mins => v_total),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true)
      then start_at + make_interval(mins => v_total - v_reveal) end
  where id = p_game_id returning * into g;
  if public.shrink_every_minutes(v_cfg) > 0 then
    update public.games set state_json = state_json || jsonb_build_object('next_phase_at',
      case when public.phase_count(v_cfg) > 1 and public.phase_start(g, 2) < g.ends_at then public.phase_start(g, 2) end)
    where id = p_game_id returning * into g;
  end if;
  -- Phasen nach Spielende gibt es nicht.
  for v_z in select * from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index > public.phase_count(v_cfg) loop
    update public.zones set visible_from = 'infinity' where id = v_z.id;
  end loop;

  -- Spieler: Buchstaben A, B, C … (danach A2, B2 …); Hunter bleiben H1, H2 …
  update public.participants p set tag = chr(65 + ((n.rn - 1) % 26)::int) || case when n.rn > 26 then ((n.rn - 1) / 26 + 1)::text else '' end
  from (select id, row_number() over (order by joined_at, id) rn
        from public.participants where game_id = p_game_id and role = 'spieler') n
  where p.id = n.id;

  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;
revoke execute on function public.start_game(uuid, boolean) from public, anon;
grant execute on function public.start_game(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Jagdbeginn: sofort ein Ping für alle Spieler, danach im eingestellten Abstand.
create or replace function public.hunt_begin(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public as $$
begin
  update public.games set status = 'laeuft', current_day = 0 where id = p_game.id returning * into p_game;
  p_game := public.day_reset(p_game, p_now);
  update public.participants set next_ping_at = p_game.hunt_start_at, ping_pending_until = null
  where game_id = p_game.id and role = 'spieler' and state = 'aktiv';
  perform public.notify(p_game.id, 'alle', null, 'hunt_begin', 'Die Jagd beginnt!', 'Die Hunter sind unterwegs.', '{}', 'hoch');
  perform public.log_game_event(p_game.id, 'hunt_begin');
  return p_game;
end; $$;

-- Ping-Takt ab Jagdbeginn (ohne Verzögerung des ersten Pings).
create or replace function public.next_ping_time(p_game public.games, p_from timestamptz, p_interval int)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_offset int := public.cfg_int(v_cfg, 'ping', 'offset_minutes', 0);
  v_jitter int := public.cfg_int(v_cfg, 'ping', 'jitter_minutes', 0);
  v_local timestamp;
  v_midnight timestamp;
  v_min double precision;
  v_k bigint;
  v_t timestamptz;
begin
  if public.cfg_bool(v_cfg, 'time', 'align_to_full_hour', false) then
    v_local := p_from at time zone p_game.timezone;
    v_midnight := date_trunc('day', v_local);
    v_min := extract(epoch from (v_local - v_midnight)) / 60.0;
    v_k := floor((v_min - v_offset) / p_interval) + 1;
    v_t := (v_midnight + make_interval(mins => (v_offset + v_k * p_interval)::int)) at time zone p_game.timezone;
  else
    v_k := greatest(1, floor(extract(epoch from (p_from - p_game.hunt_start_at)) / 60.0 / p_interval) + 1);
    v_t := p_game.hunt_start_at + make_interval(mins => (v_k * p_interval)::int);
  end if;
  if v_t <= p_from then v_t := v_t + make_interval(mins => p_interval); end if;
  if v_jitter > 0 then v_t := v_t + make_interval(secs => floor(random() * v_jitter * 60)); end if;
  return v_t;
end; $$;

-- ---------------------------------------------------------------------------
-- Fluchtpunkt erst nutzbar ab Y min vor Schluss.
create or replace function public.process_location(p_game public.games, p_p public.participants, p_point extensions.geometry, p_speed real, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_hq public.zones;
  v_exit public.zones;
begin
  if p_game.status = 'vorsprung' and p_p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'start', 'hunters_must_stay_in_hq', true) then
    select * into v_hq from public.zones where game_id = p_game.id and kind = 'hq' limit 1;
    if v_hq.id is not null and public.dist_m(v_hq.geom, p_point) > coalesce(v_hq.radius_m, public.cfg_int(v_cfg, 'start', 'hq_radius_m', 100)) + public.cfg_int(v_cfg, 'zone', 'edge_tolerance_m', 25)
       and not exists (select 1 from public.violations where participant_id = p_p.id and type = 'hunter_hq') then
      perform public.create_violation(p_game, p_p.id, 'hunter_hq', jsonb_build_object('lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
    return;
  end if;

  if p_p.role <> 'spieler' or p_game.status not in ('laeuft', 'finale') then return; end if;
  if p_p.state not in ('aktiv', 'ausserhalb') then return; end if;

  perform public.check_player_zone(p_game, p_p, p_point, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_transport(p_game, p_p, p_point, p_speed, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_hideout(p_game, p_p, p_point, p_now);

  if p_game.exit_zone_id is not null and public.exit_active(p_game, p_now)
     and public.cfg_text(v_cfg, 'exit', 'confirm', 'geofence') = 'geofence' and p_now <= p_game.deadline_at then
    select * into v_exit from public.zones where id = p_game.exit_zone_id;
    if public.dist_m(v_exit.geom, p_point) <= coalesce(v_exit.radius_m, public.cfg_int(v_cfg, 'exit', 'radius_m', 30)) then
      perform public.reach_exit(p_game, p_p.id, p_now);
    end if;
  end if;
end; $$;

create or replace function public.confirm_exit(p_game_id uuid, p_participant uuid default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.participants;
  g public.games;
  v_exit public.zones;
  v_pos public.positions;
  v_now timestamptz;
begin
  v_me := public.require_participant(p_game_id);
  g := public.require_running(p_game_id);
  v_now := public.engine_now(p_game_id);
  if not g.exit_revealed then raise exception 'Der Fluchtpunkt ist noch nicht bekannt.' using errcode = 'P0001'; end if;
  if not public.exit_active(g, v_now) then
    raise exception 'Der Fluchtpunkt ist erst ab % offen.', to_char((g.ends_at - make_interval(mins => public.exit_usable_minutes(g.config_json))) at time zone g.timezone, 'HH24:MI')
      using errcode = 'P0001';
  end if;
  if v_me.role = 'gm' and p_participant is not null then
    perform public.reach_exit(g, p_participant, v_now);
  elsif v_me.role = 'spieler' then
    select * into v_exit from public.zones where id = g.exit_zone_id;
    select * into v_pos from public.positions where participant_id = v_me.id;
    if v_pos.participant_id is null or public.dist_m(v_exit.geom, v_pos.geom) > coalesce(v_exit.radius_m, 30) + coalesce(v_pos.accuracy_m, 0) + 20 then
      raise exception 'Du bist noch nicht am Fluchtpunkt.' using errcode = 'P0001';
    end if;
    perform public.reach_exit(g, v_me.id, v_now);
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Tick: Bekanntgabe und Freigabe des Fluchtpunkts, Countdown ausserhalb auch ohne neuen Standort.
alter function public.tick_game(uuid) rename to tick_game_basis;
revoke execute on function public.tick_game_basis(uuid) from public, anon, authenticated;

create or replace function public.tick_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_open timestamptz;
  v_name text;
  v_p public.participants;
  v_pos public.positions;
  v_grace int;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or g.status not in ('laeuft', 'finale') or g.paused_at is not null then
    perform public.tick_game_basis(p_game_id);
    return;
  end if;
  v_cfg := g.config_json;
  v_now := now() + g.clock_offset;
  v_open := g.ends_at - make_interval(mins => public.exit_usable_minutes(v_cfg));

  -- Bekanntgabe (vor dem Basis-Tick, damit dort nichts doppelt passiert).
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    select * into g from public.games where id = p_game_id for update;
    if not g.exit_revealed then
      if g.exit_zone_id is null then
        update public.games set exit_zone_id = (
          select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
          order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.phase_count(v_cfg)), z.geom), z.geom) then 0 else 1 end, random()
          limit 1)
        where id = g.id returning * into g;
      end if;
      update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
      update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
      select coalesce(nullif(name, ''), 'siehe Karte') into v_name from public.zones where id = g.exit_zone_id;
      perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(v_name, 'siehe Karte'),
        'Er ist erst ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' offen. Seid zwischen '
        || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' und ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI')
        || ' im Kreis. Ab jetzt dürft ihr auch zusammen sein.', jsonb_build_object('open_at', v_open), 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
        'Ihr erfahrt ihn nicht. Er ist ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' bis zum Spielende offen.', '{}', 'hoch');
    end if;
  end if;

  perform public.tick_game_basis(p_game_id);

  select * into g from public.games where id = p_game_id;
  if g.status not in ('laeuft', 'finale') or g.paused_at is not null then return; end if;

  -- Freigabe: ab jetzt zählt, wer im Kreis steht.
  if g.exit_revealed and g.exit_zone_id is not null and v_now >= v_open and not coalesce((g.state_json ->> 'exit_open')::boolean, false) then
    update public.games set state_json = state_json || '{"exit_open": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_open', 'Fluchtpunkt ist jetzt offen!',
      'Seid bis ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI') || ' im Kreis, dann seid ihr gerettet.', '{}', 'kritisch');
    perform public.recheck_exit(g, v_now);
    select * into g from public.games where id = p_game_id;
    if g.status not in ('laeuft', 'finale') then perform public.bump(g.id); return; end if;
  end if;

  -- Countdown abgelaufen, aber kein neuer Standort: mit dem letzten bekannten Standort weiterprüfen.
  v_grace := public.cfg_int(v_cfg, 'out_of_bounds', 'grace_seconds', 60);
  for v_p in select * from public.participants
             where game_id = g.id and role = 'spieler' and state = 'aktiv'
               and ((out_pending_since is not null and out_pending_since <= v_now - make_interval(secs => v_grace))
                 or (restricted_zone_id is not null and not restricted_violated and restricted_since <= v_now - make_interval(secs => v_grace))) loop
    select * into v_pos from public.positions where participant_id = v_p.id;
    if v_pos.participant_id is not null then
      perform public.check_player_zone(g, v_p, v_pos.geom, v_now);
    end if;
  end loop;
  perform public.bump(g.id);
end; $$;
revoke execute on function public.tick_game(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Blitzjagd: Start mit Bestätigung in der App, dann gleich die erste Abfrage.
-- Nie zweimal hintereinander dieselbe Person (auch wenn nur noch eine frei ist).
create or replace function public.speedhunt_start(p_game_id uuid, p_target uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_t public.participants;
  v_sh public.speedhunts;
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(p_game_id);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  if not public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then raise exception 'Blitzjagden sind ausgeschaltet.' using errcode = 'P0001'; end if;
  if g.speedhunts_left <= 0 then raise exception 'Keine Blitzjagd mehr übrig.' using errcode = 'P0001'; end if;
  if (select count(*) from public.speedhunts where game_id = p_game_id and status = 'laeuft' and not is_penalty)
     >= public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) then
    raise exception 'Schon % Blitzjagden gleichzeitig.', public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) using errcode = 'P0001';
  end if;
  select * into v_t from public.participants where id = p_target and game_id = p_game_id;
  if v_t.id is null or v_t.role <> 'spieler' or v_t.state not in ('aktiv', 'ausserhalb') then
    raise exception 'Dieses Ziel kann nicht gejagt werden.' using errcode = 'P0001';
  end if;
  if (public.running_speedhunt_on(p_target)).id is not null then raise exception 'Auf dieses Ziel läuft schon eine Blitzjagd.' using errcode = 'P0001'; end if;
  if public.has_effect(p_target, 'regeneration', v_now) then raise exception 'Ziel ist durch einen Joker geschützt.' using errcode = 'P0001'; end if;
  if g.last_speedhunt_target = p_target then
    raise exception 'Nicht zweimal hintereinander dasselbe Ziel.' using errcode = 'P0001';
  end if;
  if public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) > 0
     and (select count(*) from public.speedhunts where target_id = p_target and not is_penalty and started_at is not null)
       >= public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) then
    raise exception 'Dieses Ziel hatte schon genug Blitzjagden.' using errcode = 'P0001';
  end if;
  if public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0) > 0
     and public.cfg_text(v_cfg, 'speedhunt', 'early_start_policy', 'silent_zaehlt_als_abfrage') = 'verbieten'
     and v_t.last_silent_ping_at > v_now - make_interval(mins => public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0)) then
    raise exception 'Erst % min nach dem letzten Ping möglich.', public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0) using errcode = 'P0001';
  end if;

  update public.games set speedhunts_left = speedhunts_left - 1 where id = p_game_id;
  v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now);
  if v_sh.status = 'laeuft' and v_sh.queries_used < v_sh.queries_total then
    perform public.speedhunt_query_internal(g, v_sh, v_now);
  end if;
  perform public.log_game_event(p_game_id, 'speedhunt_start', jsonb_build_object('target', p_target, 'by', v_me.id));
  perform public.bump(p_game_id);
  return v_sh.id;
end; $$;

-- ---------------------------------------------------------------------------
-- Vergangene Spiele löschen: der Host löscht das ganze Spiel, alle anderen entfernen es aus ihrer Liste.
create or replace function public.delete_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null then raise exception 'Spiel nicht gefunden.' using errcode = 'P0001'; end if;
  if g.status in ('vorsprung', 'laeuft', 'pausiert', 'finale') then
    raise exception 'Ein laufendes Spiel kann nicht gelöscht werden.' using errcode = 'P0001';
  end if;
  if g.host_id = auth.uid() then
    delete from public.games where id = p_game_id;
  elsif exists (select 1 from public.participants where game_id = p_game_id and user_id = auth.uid()) then
    delete from public.participants where game_id = p_game_id and user_id = auth.uid();
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
end; $$;
revoke execute on function public.delete_game(uuid) from public, anon;
grant execute on function public.delete_game(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Bestehende, noch nicht gestartete Spiele an die neuen Regeln anpassen.
update public.games set config_json = jsonb_set(jsonb_set(jsonb_set(config_json,
    '{ping,first_ping_delay_minutes}', '0'::jsonb, true),
    '{exit,arrival_deadline_offset_minutes}', '0'::jsonb, true),
    '{speedhunt,no_consecutive_same_target}', 'true'::jsonb, true)
where status in ('entwurf', 'geplant', 'lobby');
update public.games set config_json = jsonb_set(config_json, '{exit,usable_minutes_before_end}', '2'::jsonb, true)
where status in ('entwurf', 'geplant', 'lobby') and not (config_json -> 'exit' ? 'usable_minutes_before_end');

-- ---------------------------------------------------------------------------
-- Verständliche Meldungen statt alter Entwickler-Hinweise.
create or replace function public.remove_participant(p_participant_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p public.participants;
  v_game public.games;
begin
  select * into v_p from public.participants where id = p_participant_id;
  if v_p.id is null then return; end if;
  select * into v_game from public.games where id = v_p.game_id;
  if v_p.user_id <> auth.uid() and v_game.host_id <> auth.uid() then
    raise exception 'Keine Berechtigung.' using errcode = '42501';
  end if;
  if v_p.user_id = v_game.host_id then
    raise exception 'Der Host kann das Spiel nicht verlassen.' using errcode = 'P0001';
  end if;
  if v_game.status not in ('entwurf', 'geplant', 'lobby', 'beendet', 'archiviert') then
    raise exception 'Das Spiel läuft. Verlassen geht nur über „Aufgeben“.' using errcode = 'P0001';
  end if;
  delete from public.participants where id = p_participant_id;
  perform public.log_game_event(v_p.game_id, 'participant_left', jsonb_build_object('user_id', v_p.user_id));
end; $$;

create or replace function public.update_game_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_change jsonb;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Regeln ändern.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = p_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Die Regeln lassen sich nach dem Start nicht mehr ändern.' using errcode = 'P0001';
  end if;
  update public.games
  set config_json = p_config, timezone = coalesce(p_config #>> '{game,timezone}', timezone), updated_at = now()
  where id = p_game_id;
  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value)
    values (p_game_id, auth.uid(), v_change ->> 'path', v_change -> 'old', v_change -> 'new');
  end loop;
  perform public.log_game_event(p_game_id, 'config_changed', jsonb_build_object('changes', jsonb_array_length(coalesce(p_changes, '[]'::jsonb))));
end; $$;
