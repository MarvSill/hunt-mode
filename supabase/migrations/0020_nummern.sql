-- Feste Nummern für Spieler (1, 2, 3 …) und Hunter (H1, H2 …), vergeben beim Start in der Reihenfolge der Lobby.
-- Die Nummer steht in den Punkten auf der Karte (Pings, Positionen) und neben den Namen.
alter table public.participants add column if not exists tag text;

-- start_game: vergibt beim Start feste Nummern (zuletzt in 0019_fluchtpunkte_innerste_zone.sql)
create or replace function public.start_game(p_game_id uuid, p_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz := now();
  v_players int;
  v_hunters int;
  v_open int;
  v_field extensions.geometry;
  v_exit uuid;
  v_days int;
  v_d int;
  v_center extensions.geometry;
  v_factor double precision;
  v_z public.zones;
  v_sec record;
  v_i int := 0;
  v_ids uuid[];
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur der Host kann das Spiel starten.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id for update;
  if g.status not in ('entwurf', 'geplant', 'lobby') then raise exception 'Das Spiel wurde schon gestartet.' using errcode = 'P0001'; end if;
  v_cfg := g.config_json;
  select count(*) filter (where role = 'spieler'), count(*) filter (where role = 'hunter'), count(*) filter (where role = 'offen')
    into v_players, v_hunters, v_open from public.participants where game_id = p_game_id;
  if v_open > 0 then raise exception 'Noch % Person(en) ohne Rolle.', v_open using errcode = 'P0001'; end if;
  if v_players < 1 then raise exception 'Mindestens 1 Spieler nötig.' using errcode = 'P0001'; end if;
  if v_hunters < 1 then raise exception 'Mindestens 1 Hunter nötig.' using errcode = 'P0001'; end if;
  if v_players > public.cfg_int(v_cfg, 'roles', 'players_max', 9) then raise exception 'Zu viele Spieler für die Regeln.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'spielfeld') then
    raise exception 'Zeichne zuerst ein Spielfeld auf der Karte.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'treffpunkt') then
    raise exception 'Setze den Startpunkt auf der Karte.' using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
     and (select count(*) from public.zones where game_id = p_game_id and kind = 'exit') < 4 then
    raise exception 'Setze mindestens 4 Fluchtpunkt-Kandidaten auf der Karte (oder schalte den Fluchtpunkt aus).' using errcode = 'P0001';
  end if;

  -- Kartenprüfungen (22.4)
  if exists (
    select 1 from public.zones t
    where t.game_id = p_game_id and t.kind = 'treffpunkt'
      and public.spielfeld_day(p_game_id, 1) is not null
      and not ST_DWithin(public.spielfeld_day(p_game_id, 1)::geography, t.geom::geography, 25)
  ) then
    raise exception 'Der Startpunkt liegt ausserhalb des Spielfelds.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.zones p join public.zones s on s.game_id = p.game_id and s.kind = 'sperrzone'
    where p.game_id = p_game_id and p.kind in ('treffpunkt', 'exit', 'hq') and ST_Intersects(s.geom, p.geom)
  ) then
    raise exception 'Der Startpunkt oder ein Fluchtpunkt liegt in einer Gefahrenzone.' using errcode = 'P0001';
  end if;

  -- Fluchtpunkt: alle Kandidaten sind während des Spiels verborgen; gewählt wird erst bei der Bekanntgabe.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit';
  end if;

  -- Automatische Verkleinerung: um x % (Fläche) Richtung Mitte des Spielfelds (der Fluchtpunkt steht noch nicht fest).
  -- Phasen: alle X Minuten.
  v_days := public.phase_count(v_cfg);
  if public.cfg_text(v_cfg, 'zone', 'shrink_mode', 'manuell') = 'auto' and v_days > 1
     and not exists (select 1 from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index is not null) then
    v_field := public.spielfeld_day(p_game_id, 1);
    if v_field is not null then
      select coalesce((select geom from public.zones where id = v_exit), ST_Centroid(v_field)) into v_center;
      if not ST_Covers(v_field, v_center) then v_center := ST_PointOnSurface(v_field); end if;
      update public.zones set day_index = 1 where game_id = p_game_id and kind = 'spielfeld' and day_index is null;
      for v_d in 2..v_days loop
        v_factor := sqrt(power(1 - public.cfg_int(v_cfg, 'zone', 'auto_shrink_percent', 20) / 100.0, v_d - 1));
        insert into public.zones (game_id, kind, name, geom, day_index)
        values (p_game_id, 'spielfeld', case when public.shrink_every_minutes(v_cfg) > 0 then 'Spielfeld Phase ' else 'Spielfeld Tag ' end || v_d,
          ST_Translate(ST_Scale(ST_Translate(v_field, -ST_X(v_center), -ST_Y(v_center)), v_factor, v_factor), ST_X(v_center), ST_Y(v_center)), v_d);
      end loop;
    end if;
  end if;

  -- Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase), sonst sind sie am Ende nicht erreichbar.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and exists (
    select 1 from public.zones e
    where e.game_id = p_game_id and e.kind = 'exit'
      and not ST_DWithin(public.spielfeld_day(p_game_id, greatest(v_days, 1))::geography, e.geom::geography, 5)
  ) then
    raise exception 'Alle Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase).' using errcode = 'P0001';
  end if;

  -- Spielfelder künftiger Tage erst mit der Ankündigung sichtbar
  for v_z in select * from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index > 1 loop
    update public.zones set visible_from = 'infinity' where id = v_z.id;
  end loop;

  -- Sektionen zuweisen (falls nicht schon manuell vergeben)
  if public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false) then
    select array_agg(id order by random()) into v_ids from public.participants where game_id = p_game_id and role = 'spieler';
    for v_sec in select id from public.zones where game_id = p_game_id and kind = 'sektion' and owner_participant_id is null order by created_at loop
      exit when v_i >= coalesce(array_length(v_ids, 1), 0);
      v_i := v_i + 1;
      if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'sektion' and owner_participant_id = v_ids[v_i]) then
        update public.zones set owner_participant_id = v_ids[v_i] where id = v_sec.id;
      end if;
    end loop;
  end if;

  update public.participants set state = 'aktiv', out_accum_s = 0, ready = true where game_id = p_game_id;
  -- Feste Nummern: Spieler 1, 2, 3 … und Hunter H1, H2 … in der Reihenfolge der Lobby.
  update public.participants p set tag = case when n.role = 'hunter' then 'H' else '' end || n.rn
  from (select id, role, row_number() over (partition by role order by joined_at, id) rn
        from public.participants where game_id = p_game_id and role in ('spieler', 'hunter')) n
  where p.id = n.id;
  update public.games set
    status = 'vorsprung',
    is_test = p_test,
    clock_offset = interval '0',
    hunt_start_at = v_now + make_interval(mins => public.cfg_int(v_cfg, 'start', 'head_start_minutes', 60)),
    exit_zone_id = v_exit,
    last_tick_at = v_now,
    current_day = 0,
    state_json = '{}'
  where id = p_game_id returning * into g;
  update public.games set
    start_at = v_now,
    ends_at = g.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'game', 'duration_minutes', 5760)),
    deadline_at = g.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'game', 'duration_minutes', 5760)
      + case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then public.cfg_int(v_cfg, 'exit', 'arrival_deadline_offset_minutes', 15) else 0 end),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then g.hunt_start_at
      + make_interval(mins => greatest(0, public.cfg_int(v_cfg, 'game', 'duration_minutes', 5760) - public.cfg_int(v_cfg, 'exit', 'reveal_minutes_before_end', 120))) end
  where id = p_game_id returning * into g;
  if public.shrink_every_minutes(v_cfg) > 0 then
    update public.games set state_json = state_json || jsonb_build_object('phase', 1, 'next_phase_at',
      case when public.phase_count(v_cfg) > 1 and public.phase_start(g, 2) < g.ends_at then public.phase_start(g, 2) end)
    where id = p_game_id returning * into g;
  end if;
  -- Zukünftige Spielfelder werden zur Ankündigungszeit sichtbar
  for v_z in select * from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index > 1 loop
    update public.zones set visible_from = public.phase_start(g, v_z.day_index) - make_interval(mins => public.cfg_int(v_cfg, 'zone', 'shrink_announce_minutes', 180))
    where id = v_z.id;
  end loop;

  perform public.notify(p_game_id, 'spieler', null, 'game_start', 'Los! Ihr habt Vorsprung',
    public.cfg_int(v_cfg, 'start', 'head_start_minutes', 60) || ' min, dann startet die Jagd.', '{}', 'kritisch');
  perform public.notify(p_game_id, 'taskforce', null, 'game_start', 'Spiel gestartet',
    'Wartet am Startpunkt. Die Jagd beginnt um ' || to_char(g.hunt_start_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'game_started', jsonb_build_object('test', p_test));
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;

-- game_state: mit Nummer (tag) je Person (zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql)
create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  me public.participants;
  v_role text;
  v_now timestamptz;
  v_tf boolean;
  v_gm boolean;
  v_ended boolean;
  v_delay int;
  v_hist int;
  v_out jsonb;
begin
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if me.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  v_cfg := g.config_json;
  v_role := me.role;
  v_now := now() + g.clock_offset;
  v_gm := v_role = 'gm';
  v_tf := v_role in ('hunter', 'zentrale');
  v_ended := g.status in ('beendet', 'archiviert');
  v_delay := public.cfg_int(v_cfg, 'spectator', 'delay_minutes', 30);
  v_hist := public.cfg_int(v_cfg, 'ping', 'history_per_player', 5);

  v_out := jsonb_build_object(
    'now', v_now,
    'server_now', now(),
    'game', jsonb_build_object(
      'id', g.id, 'name', g.name, 'code', g.code, 'status', g.status, 'is_test', g.is_test, 'host', g.host_id = auth.uid(),
      'start_at', g.start_at, 'hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at, 'deadline_at', g.deadline_at,
      'next_day_at', g.next_day_at, 'current_day', g.current_day,
      'phase', public.field_phase(g.id, g.current_day), 'phase_count', public.phase_count(v_cfg),
      'next_phase_at', case when public.shrink_every_minutes(v_cfg) > 0 then (g.state_json ->> 'next_phase_at')::timestamptz else g.next_day_at end, 'paused', g.paused_at is not null, 'pause_reason', g.pause_reason,
      'timezone', g.timezone, 'speedhunts_left', g.speedhunts_left, 'exit_revealed', g.exit_revealed, 'exit_reveal_at', g.exit_reveal_at,
      'map_version', g.map_version, 'result', g.result_json, 'meeting_point', g.meeting_point, 'config', v_cfg, 'group_id', g.group_id,
      'quiet', public.in_quiet_hours(g, v_now)
    ),
    'me', jsonb_build_object(
      'id', me.id, 'role', me.role, 'state', me.state, 'budget', me.budget_balance, 'bounty', me.bounty,
      'next_ping_at', case when v_role = 'spieler' then me.next_ping_at end,
      'location_requested', me.location_request_at is not null,
      'hideout_prompt', me.hideout_prompted_at is not null and not exists (select 1 from public.hideouts where participant_id = me.id and status = 'aktiv' and inside),
      'transport_prompt', me.transport_prompted_at is not null,
      'out_accum_s', me.out_accum_s, 'out_pending', me.out_pending_since is not null, 'in_restricted', me.restricted_zone_id is not null,
      'briefing_done', me.briefing_done_day = g.current_day,
      'live', public.has_live_window(me.id, v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.type, 'ends_at', e.ends_at, 'payload', e.payload)), '[]')
                  from public.active_effects e where e.participant_id = me.id and e.starts_at <= v_now and (e.ends_at is null or e.ends_at > v_now) and not (e.payload ? 'done')),
      'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'source', i.source) order by i.granted_at), '[]')
                    from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired),
      'hideout', (select jsonb_build_object('id', h.id, 'inside', h.inside, 'accum_s', h.accum_s, 'entered_at', h.entered_at,
                    'max_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))
                  from public.hideouts h where h.participant_id = me.id and h.status = 'aktiv' limit 1),
      'transit', (select jsonb_build_object('id', t.id, 'mode', t.mode, 'line', t.line, 'started_at', t.started_at)
                  from public.transit_sessions t where t.participant_id = me.id and t.ended_at is null limit 1),
      'device_check', me.device_check
    ),
    'participants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', pr.display_name, 'username', pr.username, 'role', p.role, 'color', p.color, 'tag', p.tag,
        'state', case when v_gm or v_ended or p.id = me.id or p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren', 'ausserhalb', 'notfall') then p.state else 'aktiv' end,
        'battery', case when v_gm or (v_tf and p.role in ('hunter', 'zentrale')) then p.battery end,
        'last_seen_at', case when v_gm then p.last_seen_at end,
        'bounty', p.bounty,
        'budget', case when v_gm then p.budget_balance end,
        'device_check', case when v_gm or p.id = me.id or g.status in ('lobby', 'geplant', 'entwurf') then p.device_check end,
        'next_ping_at', case when (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true)) or v_gm then p.next_ping_at end,
        'protected', case when v_tf or v_gm then (public.has_effect(p.id, 'regeneration', v_now) or public.has_effect(p.id, 'hotel', v_now)) end,
        'catch_free', case when v_tf or v_gm then public.has_effect(p.id, 'catch_free', v_now) end,
        'briefing_done', p.briefing_done_day = g.current_day
      ) order by p.role, pr.display_name), '[]')
      from public.participants p join public.profiles pr on pr.user_id = p.user_id
      where p.game_id = g.id
    ),
    -- Positionen: Spielleitung alles, Taskforce die eigenen Leute und Spieler im Live-Fenster,
    -- Spieler nur sich selbst, Zuschauer verzögert (5.2, 7.18).
    'positions', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', x.participant_id, 'lat', x.lat, 'lng', x.lng, 'accuracy_m', x.accuracy_m,
        'speed_mps', x.speed_mps, 'heading', x.heading, 'at', x.at, 'live', x.live)), '[]')
      from (
        select pos.participant_id, pos.lat, pos.lng, pos.accuracy_m, pos.speed_mps, pos.heading, pos.at,
               public.has_live_window(pos.participant_id, v_now) live
        from public.positions pos join public.participants p on p.id = pos.participant_id
        where pos.game_id = g.id and v_role <> 'zuschauer' and (
          v_gm or v_ended or pos.participant_id = me.id
          or (v_tf and p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'taskforce', 'share_positions_internally', true))
          or (v_tf and p.role = 'spieler' and public.has_live_window(p.id, v_now) and p.state in ('aktiv', 'ausserhalb', 'notfall'))
          or (v_role = 'spieler' and p.role = 'spieler' and p.state = 'notfall')
        )
        union all
        (select distinct on (s.participant_id) s.participant_id, ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.speed_mps, s.heading, s.at, false
        from public.location_samples s
        where s.game_id = g.id and v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false)
          and s.at <= v_now - make_interval(mins => v_delay)
        order by s.participant_id, s.at desc)
      ) x
    ),
    -- Pings: Taskforce sieht die letzten n je Spieler (ohne Fake-Markierung), Spieler die eigenen,
    -- Spielleitung alles inkl. echter Position, Zuschauer verzögert.
    'pings', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds,
        'is_fake', case when v_gm or v_ended or x.participant_id = me.id then x.is_fake end,
        'truth', case when (v_gm or v_ended) and x.is_fake then (select jsonb_build_object('lat', t.lat, 'lng', t.lng) from public.ping_truth t where t.ping_id = x.id) end
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg
        where pg.game_id = g.id and (
          v_gm or v_ended
          or (v_tf and pg.visible_at <= v_now)
          or (v_role = 'spieler' and pg.participant_id = me.id)
          or (v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false) and pg.visible_at <= v_now - make_interval(mins => v_delay))
        )
      ) x where x.rn <= case when v_gm or v_ended then 1000 else v_hist end
    ),
    'speedhunts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty,
        'target_id', case when v_gm or v_tf or v_ended or (s.target_id = me.id and public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false)) then s.target_id end,
        'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
        'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
      from public.speedhunts s where s.game_id = g.id and (s.status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') or s.ended_at > v_now - interval '2 hours' or v_gm or v_ended)
        and (s.status <> 'wartet_auf_freigabe' or v_gm or v_tf) and (s.status <> 'aufgeschoben' or v_gm or v_tf)
        and not (s.status = 'beendet' and s.started_at is null and not v_gm)
    ),
    'catches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'runner_id', c.runner_id, 'hunter_id', c.hunter_id, 'at', c.at, 'method', c.method,
        'status', c.status, 'expires_at', c.expires_at, 'distance_m', c.distance_m, 'reason', c.reason, 'lat', case when v_gm or v_ended then c.lat end,
        'lng', case when v_gm or v_ended then c.lng end) order by c.at desc), '[]')
      from public.catches c where c.game_id = g.id and (c.status = 'gueltig' or v_gm or c.runner_id = me.id or c.hunter_id = me.id)
    ),
    'violations', (
      select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'participant_id', v.participant_id, 'type', v.type, 'at', v.at, 'evidence', v.evidence,
        'proposed_penalty', v.proposed_penalty, 'decided_penalty', v.decided_penalty, 'status', v.status, 'auto_apply_at', v.auto_apply_at,
        'explanation', v.explanation, 'detected_by', v.detected_by) order by v.at desc), '[]')
      from public.violations v where v.game_id = g.id and (v_gm or v.participant_id = me.id or v_ended)
    ),
    'challenges', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'description', c.description, 'template', c.template,
        'lat', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lat end,
        'lng', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lng end,
        'radius_m', c.radius_m, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'announce_at', c.announce_at, 'proof_type', c.proof_type,
        'secret_code', case when v_gm then c.secret_code end, 'reward_type', c.reward_type, 'reward_value', c.reward_value, 'status', c.status,
        'max_participants', c.max_participants,
        'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'result', e.result, 'proof_path', case when v_gm then e.proof_path end, 'proof_text', case when v_gm then e.proof_text end)), '[]')
                    from public.challenge_entries e where e.challenge_id = c.id and (v_gm or e.participant_id = me.id or v_ended))
      ) order by c.starts_at), '[]')
      from public.challenges c where c.game_id = g.id and (v_gm or c.status <> 'geplant')
    ),
    'emergencies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'status', e.status)), '[]')
      from public.emergencies e where e.game_id = g.id and e.status = 'offen'
    ),
    'transits', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', t.participant_id, 'mode', t.mode, 'line', t.line, 'from', t.from_station, 'to', t.to_station,
        'started_at', t.started_at)), '[]')
      from public.transit_sessions t where t.game_id = g.id and t.ended_at is null and (v_gm or v_tf or t.participant_id = me.id)
    ),
    'hideouts', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', h.participant_id, 'inside', h.inside, 'accum_s', h.accum_s, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))), '[]')
      from public.hideouts h where h.game_id = g.id and h.status = 'aktiv' and v_gm
    ),
    'purchases', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', u.participant_id, 'amount', u.amount, 'category', u.category, 'note', u.note, 'at', u.at) order by u.at desc), '[]')
      from public.purchases u where u.game_id = g.id and (v_gm or u.participant_id = me.id)
    ),
    'notifications', (
      select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
        select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
        from public.notifications n where n.game_id = g.id and public.can_see_notification(n)
        order by n.id desc limit 60
      ) q
    ),
    'next_silent_ping_at', case when v_gm or (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true))
      then (select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb')) end,
    'free_players', public.free_players(g.id)
  );
  return v_out;
end; $$;

-- use_item: Hunter-Standorte mit Nummer (zuletzt in 0016_ein_startpunkt_ohne_zentrale.sql)
create or replace function public.use_item(p_item_id uuid, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_i public.inventory_items;
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_type text;
  v_minutes int;
  v_pos public.positions;
  v_target extensions.geometry;
  v_snapshot jsonb;
begin
  select * into v_i from public.inventory_items where id = p_item_id;
  if v_i.id is null then raise exception 'Gegenstand nicht gefunden.' using errcode = 'P0001'; end if;
  v_me := public.require_participant(v_i.game_id, array['spieler']);
  if v_me.id <> v_i.participant_id then raise exception 'Nicht dein Gegenstand.' using errcode = '42501'; end if;
  g := public.require_running(v_i.game_id);
  v_cfg := g.config_json;
  v_now := public.engine_now(g.id);
  if v_i.used_at is not null or v_i.expired then raise exception 'Schon benutzt oder verfallen.' using errcode = 'P0001'; end if;
  if v_me.state not in ('aktiv', 'ausserhalb') then raise exception 'Du bist nicht mehr im Spiel.' using errcode = 'P0001'; end if;
  v_type := v_i.type;
  v_minutes := v_i.minutes;
  if v_type = 'wahl' then
    -- Joker-Wahl: Typ aus den erlaubten wählen
    select e ->> 'type', (e ->> 'minutes')::int into v_type, v_minutes
    from jsonb_array_elements(coalesce(v_cfg -> 'joker' -> 'types', '[]')) e where e ->> 'type' = p_payload ->> 'type';
    if v_type is null then raise exception 'Bitte einen Joker-Typ wählen.' using errcode = 'P0001'; end if;
  end if;
  select * into v_pos from public.positions where participant_id = v_me.id;

  case v_type
    when 'regeneration' then
      -- Nicht während eines laufenden Speedhunts (auf irgendwen) (14.3, Regel 2).
      if exists (select 1 from public.speedhunts where game_id = g.id and status = 'laeuft') then
        raise exception 'Während einer Blitzjagd nicht möglich.' using errcode = 'P0001';
      end if;
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, source_item_id)
      values (g.id, v_me.id, 'regeneration', v_now, v_now + make_interval(mins => coalesce(v_minutes, 240)), v_i.id);
      perform public.notify(g.id, 'taskforce', null, 'joker', 'Joker: Regeneration', 'Ein Spieler ist für ' || coalesce(v_minutes, 240) || ' min nicht ortbar.', '{}', 'normal');
    when 'catch_free' then
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, source_item_id)
      values (g.id, v_me.id, 'catch_free', v_now, v_now + make_interval(mins => coalesce(v_minutes, 180)), v_i.id);
      perform public.notify(g.id, 'taskforce', null, 'joker', 'Joker: Schutzschild', public.pname(v_me.id) || ' kann ' || coalesce(v_minutes, 180) || ' min nicht gefangen werden.', '{}', 'hoch');
    when 'hunter_erfragen' then
      select coalesce(jsonb_agg(jsonb_build_object('name', public.pname(p.id), 'tag', p.tag, 'lat', pos.lat, 'lng', pos.lng, 'at', pos.at)), '[]') into v_snapshot
      from public.participants p join public.positions pos on pos.participant_id = p.id
      where p.game_id = g.id and p.role = 'hunter';
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
      values (g.id, v_me.id, 'hunter_snapshot', v_now, greatest(coalesce(g.deadline_at, g.ends_at), v_now + interval '5 minutes'), jsonb_build_object('hunters', v_snapshot), v_i.id);
      perform public.notify(g.id, null, v_me.id, 'joker', 'Hunter-Standorte', 'Einmaliger Ping aller Hunter von ' || to_char(v_now at time zone g.timezone, 'HH24:MI') || ', nicht live. Auf der Karte eingezeichnet.', jsonb_build_object('hunters', v_snapshot), 'hoch');
    when 'fake_ping' then
      if (p_payload ->> 'lat') is null then raise exception 'Bitte einen Ort auf der Karte wählen.' using errcode = 'P0001'; end if;
      v_target := public.pt((p_payload ->> 'lat')::double precision, (p_payload ->> 'lng')::double precision);
      if v_pos.participant_id is not null and public.dist_m(v_pos.geom, v_target) > public.cfg_int(v_cfg, 'bonus', 'fake_ping_max_distance_m', 3000) then
        raise exception 'Zu weit weg (max. % m).', public.cfg_int(v_cfg, 'bonus', 'fake_ping_max_distance_m', 3000) using errcode = 'P0001';
      end if;
      if not ST_DWithin(coalesce(public.allowed_area(g.id, v_me.id, g.current_day, public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false)), v_target)::geography, v_target::geography, 1) then
        raise exception 'Der Fake-Ping muss im Spielfeld liegen.' using errcode = 'P0001';
      end if;
      insert into public.active_effects (game_id, participant_id, type, starts_at, payload, source_item_id)
      values (g.id, v_me.id, 'fake_ping', v_now, jsonb_build_object('lat', p_payload -> 'lat', 'lng', p_payload -> 'lng',
              'applies', coalesce(nullif(p_payload ->> 'applies', ''), 'beide')), v_i.id);
    when 'hotel' then
      if v_pos.participant_id is null then raise exception 'Noch kein Standort.' using errcode = 'P0001'; end if;
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
      values (g.id, v_me.id, 'hotel', v_now, v_now + make_interval(mins => public.cfg_int(v_cfg, 'bonus', 'hotel_minutes', 360)),
              jsonb_build_object('lat', v_pos.lat, 'lng', v_pos.lng, 'radius_m', public.cfg_int(v_cfg, 'bonus', 'hotel_radius_m', 50)), v_i.id);
      perform public.notify(g.id, 'taskforce', null, 'bonus', 'Bonus: Hotel', 'Ein Spieler ist ' || public.cfg_int(v_cfg, 'bonus', 'hotel_minutes', 360) || ' min geschützt.', '{}', 'normal');
    when 'budget' then
      update public.participants set budget_balance = budget_balance + coalesce(v_minutes, 10) where id = v_me.id;
    else
      raise exception 'Unbekannter Gegenstand.' using errcode = 'P0001';
  end case;
  update public.inventory_items set used_at = v_now, type = v_type where id = v_i.id;
  perform public.log_game_event(g.id, 'item_used', jsonb_build_object('type', v_type, 'participant', v_me.id));
  perform public.bump(g.id);
  return jsonb_build_object('type', v_type);
end; $$;

