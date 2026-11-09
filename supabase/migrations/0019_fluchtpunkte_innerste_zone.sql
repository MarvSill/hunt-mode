-- Fluchtpunkte in der innersten Zone.
-- Beim Start prüft die App, dass jeder Fluchtpunkt-Kandidat im Spielfeld der letzten Phase liegt.
-- Liegt einer weiter aussen, wäre er nach der Verkleinerung nicht mehr erreichbar.

-- start_game: prüft zusätzlich, dass alle Fluchtpunkte in der innersten Zone liegen (zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql)
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

