-- Alarm bei jedem Ping und jeder Blitzjagd, Blitzjagd nur durch Hunter und ohne Zeitlimit, kein Schutzschild.
-- * Bei jedem Ping bekommen alle Spieler eine Meldung (der gepingte Spieler: "Du wurdest gepingt").
-- * Blitzjagden starten nur die Hunter: keine Zufalls-Blitzjagden, keine Straf-Blitzjagden.
--   Die Strafstufe dazwischen ist jetzt "15 min live sichtbar".
-- * Eine Blitzjagd hat keine Höchstdauer mehr.
-- * Der Joker "Schutzschild" (catch_free) ist entfernt.
-- * Der Alarm, wenn Spieler zusammen laufen, heisst Nähe-Alarm.

-- Noch nicht gestartete Spiele anpassen.
update public.games set config_json = config_json
  || jsonb_build_object('speedhunt', coalesce(config_json -> 'speedhunt', '{}'::jsonb) || '{"trigger_mode": "taskforce"}'::jsonb)
  || jsonb_build_object('ping', coalesce(config_json -> 'ping', '{}'::jsonb) - 'notify_player')
  || jsonb_build_object('penalty', coalesce(config_json -> 'penalty', '{}'::jsonb)
       || '{"escalation": ["verwarnung", "live_standort", "disqualifikation"]}'::jsonb)
where status in ('entwurf', 'geplant', 'lobby');

update public.games set config_json = jsonb_set(config_json, '{joker,types}', (
    select coalesce(jsonb_agg(t), '[]'::jsonb) from jsonb_array_elements(config_json #> '{joker,types}') t
    where t ->> 'type' <> 'catch_free'))
where status in ('entwurf', 'geplant', 'lobby') and jsonb_typeof(config_json #> '{joker,types}') = 'array';

-- Laufende Blitzjagden ohne Zeitlimit weiterführen.
update public.speedhunts set deadline_at = null where status = 'laeuft';

-- Nicht eingesetzte Schutzschild-Joker verfallen.
update public.inventory_items set expired = true where kind = 'joker' and type = 'catch_free' and used_at is null and not expired;

-- default_penalty (zuletzt in 0004_engine_logik.sql)
create or replace function public.default_penalty(p_cfg jsonb, p_type text)
returns text language sql immutable as $$
  select case p_type
    when 'ausserhalb_limit' then 'live_standort'
    when 'sperrzone' then 'verwarnung'
    when 'verschanzen_limit' then 'live_standort'
    when 'versteck_gesperrt' then 'live_standort'
    when 'oev_nicht_angemeldet' then 'live_standort'
    when 'fahrzeug_verbotene_zone' then 'live_standort'
    when 'faehren_limit' then 'verwarnung'
    when 'signalverlust' then 'live_standort'
    when 'hunter_hq' then 'verwarnung'
    else 'verwarnung'
  end;
$$;

-- apply_penalty (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.apply_penalty(p_game public.games, p_violation_id uuid, p_penalty text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.violations;
  v_p public.participants;
begin
  select * into v from public.violations where id = p_violation_id;
  select * into v_p from public.participants where id = v.participant_id;
  update public.violations set status = 'verhaengt', decided_penalty = p_penalty, decided_at = p_now where id = v.id;
  if v_p.state not in ('aktiv', 'ausserhalb', 'notfall') and v_p.role = 'spieler' then return; end if;
  case p_penalty
    when 'verwarnung' then
      perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Verwarnung', replace(v.type, '_', ' '), '{}', 'hoch');
    -- Blitzjagden starten nur die Hunter; eine alte Stufe "Straf-Blitzjagd" wird zu 15 min live.
    when 'straf_speedhunt', 'live_standort' then
      if v_p.role <> 'spieler' then
        perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Verwarnung', replace(v.type, '_', ' '), '{}', 'hoch');
      else
        perform public.open_live_window(p_game.id, v.participant_id, 'strafe', p_now, p_now + interval '15 minutes');
        perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Strafe: 15 min live',
          'Die Hunter sehen dich 15 Minuten live (' || replace(v.type, '_', ' ') || ').', '{}', 'kritisch');
        perform public.notify(p_game.id, 'taskforce', null, 'penalty', public.pname(v.participant_id) || ' ist 15 min live',
          'Strafe: ' || replace(v.type, '_', ' '), '{}', 'hoch');
      end if;
    when 'disqualifikation' then
      perform public.disqualify(p_game, v.participant_id, 'Strafe: ' || replace(v.type, '_', ' '), p_now);
    when 'catch' then
      perform public.auto_catch(p_game, v.participant_id, 'Strafe: ' || v.type, p_now);
    when 'sofort_ping' then
      declare v_pos record;
      begin
        select * into v_pos from public.best_position(v.participant_id, p_now);
        perform public.create_ping(p_game, v.participant_id, 'penalty', v_pos.lat, v_pos.lng, v_pos.accuracy_m, v_pos.age_s, null, null, 'Strafe', 0, p_now);
      end;
    else
      null;
  end case;
end; $$;

-- start_speedhunt_internal (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.start_speedhunt_internal(p_game public.games, p_target uuid, p_by uuid,
  p_is_penalty boolean, p_now timestamptz, p_status text default 'laeuft')
returns public.speedhunts language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_sh public.speedhunts;
  v_queries int := public.cfg_int(v_cfg, 'speedhunt', 'queries', 4);
  v_used int := 0;
  v_min_after int := public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0);
  v_last timestamptz;
  v_text text := public.cfg_text(v_cfg, 'speedhunt', 'announce_text', 'Blitzjagd gestartet!');
begin
  if p_status = 'laeuft' and not p_is_penalty and v_min_after > 0 then
    select last_silent_ping_at into v_last from public.participants where id = p_target;
    if v_last is not null and v_last > p_now - make_interval(mins => v_min_after) then
      v_used := 1; -- Der letzte Ping zählt als erste Abfrage
    end if;
  end if;
  insert into public.speedhunts (game_id, target_id, day_index, triggered_by, is_penalty, status, queries_total, queries_used,
                                 created_at, started_at, deadline_at)
  values (p_game.id, p_target, p_game.current_day, p_by, p_is_penalty, p_status, v_queries, v_used, p_now,
          case when p_status = 'laeuft' then p_now end,
          null) -- keine Höchstdauer: endet, wenn alle Abfragen gemacht sind oder das Ziel gefangen ist
  returning * into v_sh;

  if p_status = 'laeuft' then
    update public.games set last_speedhunt_target = p_target where id = p_game.id;
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_start', 'BLITZJAGD!',
      v_text || ' Einer von euch wird gejagt.', jsonb_build_object('speedhunt_id', v_sh.id), 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_start',
      case when p_is_penalty then 'Straf-Blitzjagd: ' else 'Blitzjagd: ' end || public.pname(p_target),
      v_queries - v_used || ' Abfragen, ohne Zeitlimit',
      jsonb_build_object('speedhunt_id', v_sh.id), 'kritisch');
    if public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false) then
      perform public.notify(p_game.id, null, p_target, 'speedhunt_target', 'Du bist das Ziel!', '', '{}', 'kritisch');
    end if;
    if v_used = 1 then
      perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_info', 'Ping zählt als Abfrage 1',
        'Der letzte Ping liegt weniger als ' || v_min_after || ' min zurück.', '{}', 'normal');
    end if;
  end if;
  return v_sh;
end; $$;

-- speedhunt_query_internal (zuletzt in 0004_engine_logik.sql)
create or replace function public.speedhunt_query_internal(p_game public.games, p_sh public.speedhunts, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_pos record;
  v_n int := p_sh.queries_used + 1;
  v_ping uuid;
  v_live int := public.cfg_int(v_cfg, 'speedhunt', 'vehicle_live_seconds', 60);
  v_speed real;
  v_in_vehicle boolean;
begin
  select * into v_pos from public.best_position(p_sh.target_id, p_now);
  v_ping := public.create_ping(p_game, p_sh.target_id, 'speedhunt', v_pos.lat, v_pos.lng, v_pos.accuracy_m,
    case when v_pos.age_s > public.cfg_int(v_cfg, 'ping', 'max_age_seconds', 60) then v_pos.age_s end,
    v_n, p_sh.id, null, 0, p_now);
  update public.speedhunts set queries_used = v_n, last_query_at = p_now where id = p_sh.id;
  update public.participants set location_request_at = p_now where id = p_sh.target_id;

  select speed_mps into v_speed from public.positions where participant_id = p_sh.target_id;
  v_in_vehicle := exists (select 1 from public.transit_sessions where participant_id = p_sh.target_id and ended_at is null)
    or coalesce(v_speed, 0) * 3.6 > public.cfg_int(v_cfg, 'transport', 'speed_threshold_kmh', 8);
  if v_in_vehicle and v_live > 0 then
    perform public.open_live_window(p_game.id, p_sh.target_id, 'fahrzeug', p_now, p_now + make_interval(secs => v_live));
  end if;

  if public.cfg_bool(v_cfg, 'speedhunt', 'notify_each_query_to_players', true) then
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_query', 'BLITZJAGD: Abfrage ' || v_n || ' von ' || p_sh.queries_total,
      '', jsonb_build_object('speedhunt_id', p_sh.id), 'hoch');
  end if;
  perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_query',
    'Abfrage ' || v_n || '/' || p_sh.queries_total || ': ' || public.pname(p_sh.target_id),
    case when v_in_vehicle and v_live > 0 then 'Ziel ist unterwegs: ' || v_live || ' s live.' else '' end,
    jsonb_build_object('speedhunt_id', p_sh.id, 'ping_id', v_ping), 'hoch');

  if v_n >= p_sh.queries_total then
    select * into p_sh from public.speedhunts where id = p_sh.id;
    perform public.end_speedhunt(p_game, p_sh, 'abfragen_aufgebraucht', p_now);
  end if;
  return v_ping;
end; $$;

-- process_ping_due (zuletzt in 0004_engine_logik.sql)
create or replace function public.process_ping_due(p_game public.games, p_p public.participants, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_suppressed boolean;
  v_pos record;
  v_max_age int := public.cfg_int(v_cfg, 'ping', 'max_age_seconds', 60);
  v_wait int := public.cfg_int(v_cfg, 'ping', 'fresh_fix_wait_seconds', 30);
  v_hotel public.active_effects;
begin
  if p_p.next_ping_at is null or p_p.next_ping_at > p_now then return; end if;
  if p_p.state not in ('aktiv', 'ausserhalb') then
    if p_p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel') then
      update public.participants set next_ping_at = null where id = p_p.id;
    else
      perform public.schedule_next_ping(p_game, p_p.id, p_now);
    end if;
    return;
  end if;

  select * into v_hotel from public.active_effects
  where participant_id = p_p.id and type = 'hotel' and starts_at <= p_now and (ends_at is null or ends_at > p_now) limit 1;
  v_suppressed := public.in_quiet_hours(p_game, p_now)
    or public.has_effect(p_p.id, 'regeneration', p_now)
    or public.has_effect(p_p.id, 'leo', p_now)
    or (public.cfg_text(v_cfg, 'ping', 'during_speedhunt', 'weiterlaufen') = 'aussetzen' and (public.running_speedhunt_on(p_p.id)).id is not null)
    or (v_hotel.id is not null and public.cfg_text(v_cfg, 'bonus', 'hotel_pings', 'weiter') = 'pausiert');
  if v_suppressed then
    if public.cfg_bool(v_cfg, 'ping', 'show_suppressed_to_taskforce', false) then
      perform public.create_ping(p_game, p_p.id, 'kein_signal', null, null, null, null, null, null, null, 0, p_now);
    end if;
    perform public.schedule_next_ping(p_game, p_p.id, p_now);
    return;
  end if;

  select * into v_pos from public.best_position(p_p.id, p_now);
  if v_pos.lat is null then
    perform public.create_ping(p_game, p_p.id, 'kein_signal', null, null, null, null, null, null, 'Noch kein Standort', 0, p_now);
    perform public.schedule_next_ping(p_game, p_p.id, p_now);
    return;
  end if;
  if v_pos.age_s > v_max_age then
    if p_p.ping_pending_until is null then
      update public.participants set ping_pending_until = p_now + make_interval(secs => v_wait), location_request_at = p_now
      where id = p_p.id;
      return;
    elsif p_now < p_p.ping_pending_until then
      return;
    end if;
  end if;

  perform public.create_ping(p_game, p_p.id, 'silent', v_pos.lat, v_pos.lng, v_pos.accuracy_m,
    case when v_pos.age_s > v_max_age then v_pos.age_s end, null, null, null, 0, p_now);
  update public.participants set last_silent_ping_at = p_now, location_request_at = null where id = p_p.id;
  perform public.schedule_next_ping(p_game, p_p.id, p_now);
  -- Bei jedem Ping werden alle Spieler alarmiert; wer gepingt wurde, erfährt es.
  declare v_o record;
  begin
    for v_o in select id from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall') loop
      if v_o.id = p_p.id then
        perform public.notify(p_game.id, null, v_o.id, 'ping_self', 'Du wurdest gepingt', 'Die Hunter sehen jetzt, wo du gerade bist.', '{}', 'hoch');
      else
        perform public.notify(p_game.id, null, v_o.id, 'ping', 'Ping', 'Die Hunter haben gerade den Standort eines Spielers bekommen.', '{}', 'hoch');
      end if;
    end loop;
  end;
end; $$;

-- schedule_random_speedhunts: Blitzjagden starten nur noch die Hunter, nie der Zufall.
create or replace function public.schedule_random_speedhunts(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.games set state_json = state_json - 'random_speedhunts' where id = p_game.id;
end; $$;

-- check_proximity (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.check_proximity(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_dist int := public.cfg_int(v_cfg, 'proximity', 'distance_m', 250);
  v_hyst int := public.cfg_int(v_cfg, 'proximity', 'hysteresis_m', 50);
  v_repeat int := public.cfg_int(v_cfg, 'proximity', 'repeat_minutes', 0);
  v_pair record;
  v_state public.proximity_pairs;
  v_suspended boolean;
begin
  if not public.cfg_bool(v_cfg, 'proximity', 'enabled', true) then return; end if;
  if p_now < p_game.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'proximity', 'active_after_minutes', 60)) then return; end if;
  -- Challenge-Fenster: Regel ausgesetzt (7.13, 7.14)
  v_suspended := exists (
    select 1 from public.challenges c where c.game_id = p_game.id and c.status <> 'abgesagt'
      and p_now between c.starts_at - make_interval(mins => public.cfg_int(v_cfg, 'challenge', 'suspend_proximity_before_minutes', 60))
                    and c.ends_at + make_interval(mins => public.cfg_int(v_cfg, 'challenge', 'suspend_proximity_after_minutes', 60))
  );
  if v_suspended then return; end if;

  for v_pair in
    select a.id a_id, b.id b_id, pa.geom ga, pb.geom gb, pa.lat alat, pa.lng alng, pa.accuracy_m aacc, pb.lat blat, pb.lng blng, pb.accuracy_m bacc,
           public.dist_m(pa.geom, pb.geom) d
    from public.participants a
    join public.participants b on b.game_id = a.game_id and b.id > a.id
    join public.positions pa on pa.participant_id = a.id
    join public.positions pb on pb.participant_id = b.id
    where a.game_id = p_game.id and a.role = 'spieler' and b.role = 'spieler'
      and a.state in ('aktiv', 'ausserhalb') and b.state in ('aktiv', 'ausserhalb')
      and pa.at > p_now - interval '5 minutes' and pb.at > p_now - interval '5 minutes'
  loop
    select * into v_state from public.proximity_pairs where a = v_pair.a_id and b = v_pair.b_id;
    if v_pair.d < v_dist then
      if v_state.a is null or not v_state.alerted
         or (v_repeat > 0 and v_state.last_alert_at <= p_now - make_interval(mins => v_repeat)) then
        insert into public.proximity_pairs (game_id, a, b, alerted, last_alert_at) values (p_game.id, v_pair.a_id, v_pair.b_id, true, p_now)
        on conflict (a, b) do update set alerted = true, last_alert_at = p_now;
        -- Regenerations-Joker unterdrückt nur die eigene Position (7.14).
        if not public.has_effect(v_pair.a_id, 'regeneration', p_now) then
          perform public.create_ping(p_game, v_pair.a_id, 'proximity', v_pair.alat, v_pair.alng, v_pair.aacc, null, null, null, null, 0, p_now);
        end if;
        if not public.has_effect(v_pair.b_id, 'regeneration', p_now) then
          perform public.create_ping(p_game, v_pair.b_id, 'proximity', v_pair.blat, v_pair.blng, v_pair.bacc, null, null, null, null, 0, p_now);
        end if;
        perform public.notify(p_game.id, 'taskforce', null, 'proximity', 'Nähe-Alarm',
          public.pname(v_pair.a_id) || ' und ' || public.pname(v_pair.b_id) || ' sind unter ' || v_dist || ' m.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.b_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'name', public.pname(v_pair.b_id)), 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.a_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'name', public.pname(v_pair.a_id)), 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.alerted then
      update public.proximity_pairs set alerted = false where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;

