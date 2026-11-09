-- Ein Startpunkt für alle, keine Zentrale, keine Ping-Ungenauigkeit.
-- * Spieler und Hunter starten am selben Punkt (Zone `treffpunkt`). Den Wartebereich der Hunter (Zone `hq`)
--   legt die Datenbank selbst an diesen Punkt; die Hunter warten dort während des Vorsprungs.
-- * Die Rolle "Zentrale" gibt es nicht mehr: alle Hunter jagen gemeinsam unterwegs.
-- * Pings zeigen immer den genauen Ort (keine Ungenauigkeit).
-- * Spielfeld verlassen: 1. und 2. Mal Alarm und 1 Minute Countdown, danach live; ab dem 3. Mal sofort live.
-- * Gefahrenzone betreten: gleiche Regel mit eigener Zählung; zu lange drin = Folge wie ausserhalb.
-- * Joker Hunter-Standorte: einmaliger Ping aller Hunter im Moment des Einsetzens, bleibt mit Uhrzeit auf der Karte.

-- Rolle Zentrale wird Hunter.
update public.participants set role = 'hunter' where role = 'zentrale';
update public.participants set wished_role = 'hunter' where wished_role = 'zentrale';

do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.participants'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%zentrale%'
  loop
    execute format('alter table public.participants drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.participants drop constraint if exists participants_role_check;
alter table public.participants add constraint participants_role_check
  check (role in ('offen', 'spieler', 'hunter', 'zuschauer'));
alter table public.participants drop constraint if exists participants_wished_role_check;
alter table public.participants add constraint participants_wished_role_check
  check (wished_role in ('spieler', 'hunter', 'zuschauer'));

-- Noch nicht gestartete Spiele: genaue Pings, keine Regeln mehr für Abstand zum HQ oder Zentrale.
update public.games set config_json = config_json
  || jsonb_build_object('ping', coalesce(config_json -> 'ping', '{}'::jsonb) - 'precision_blur_m')
  || jsonb_build_object('start', coalesce(config_json -> 'start', '{}'::jsonb) - 'hq_min_distance_m')
  || jsonb_build_object('taskforce', coalesce(config_json -> 'taskforce', '{}'::jsonb) - 'hq_required')
where status in ('entwurf', 'geplant', 'lobby');

-- Wartebereich der Hunter an den Startpunkt legen (ersetzt ein eigenes HQ).
create or replace function public.place_hunter_wait(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_start public.zones;
begin
  delete from public.zones where game_id = p_game_id and kind = 'hq';
  select * into v_start from public.zones where game_id = p_game_id and kind = 'treffpunkt' limit 1;
  if v_start.id is null then return; end if;
  insert into public.zones (game_id, kind, name, geom, radius_m)
  values (p_game_id, 'hq', 'Wartebereich der Hunter', v_start.geom,
    public.cfg_int((select config_json from public.games where id = p_game_id), 'start', 'hq_radius_m', 100));
end; $$;
revoke all on function public.place_hunter_wait(uuid) from public, anon, authenticated;

do $$
declare g record;
begin
  for g in select id from public.games where status in ('entwurf', 'geplant', 'lobby') loop
    perform public.place_hunter_wait(g.id);
  end loop;
end $$;

-- set_participant_role (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.set_participant_role(p_participant_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game_id uuid;
  v_user uuid;
begin
  select game_id, user_id into v_game_id, v_user from public.participants where id = p_participant_id;
  if v_game_id is null or not public.is_game_host(v_game_id) then
    raise exception 'Nur der Host kann Rollen vergeben.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = v_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Rollen können nur vor dem Start geändert werden.' using errcode = 'P0001';
  end if;
  if p_role not in ('offen', 'spieler', 'hunter', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;

  update public.participants set role = p_role, ready = (v_user = auth.uid()) where id = p_participant_id;
  perform public.log_game_event(v_game_id, 'role_assigned', jsonb_build_object('participant_id', p_participant_id, 'role', p_role));
end;
$$;

-- set_ready (zuletzt in 0001_fundament.sql)
create or replace function public.set_ready(p_game_id uuid, p_ready boolean, p_wished_role text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_wished_role is not null and p_wished_role not in ('spieler', 'hunter', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;
  update public.participants
  set ready = p_ready,
      wished_role = coalesce(p_wished_role, wished_role),
      rules_accepted_at = case when p_ready then coalesce(rules_accepted_at, now()) else rules_accepted_at end
  where game_id = p_game_id and user_id = auth.uid();
end;
$$;

-- save_map (zuletzt in 0014_nur_ein_spielfeld.sql)
create or replace function public.save_map(p_game_id uuid, p_features jsonb)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  f jsonb;
  n int := 0;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Karte bearbeiten.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = p_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Die Karte ist ab Spielstart gesperrt.' using errcode = 'P0001';
  end if;
  delete from public.zones where game_id = p_game_id;
  -- Nur noch Spielfeld, Gefahrenzonen und Punkte; andere Gebiete werden nicht gespeichert.
  for f in select value from jsonb_array_elements(coalesce(p_features, '[]'::jsonb))
           where value #>> '{properties,kind}' in ('spielfeld', 'sperrzone', 'exit', 'treffpunkt') loop
    insert into public.zones (
      game_id, kind, name, color, geom, radius_m, day_index, grows, ping_interval_override,
      crossing_allowed, restricted_type, owner_participant_id
    ) values (
      p_game_id,
      f #>> '{properties,kind}',
      coalesce(f #>> '{properties,name}', ''),
      f #>> '{properties,color}',
      ST_SetSRID(ST_GeomFromGeoJSON((f -> 'geometry')::text), 4326),
      nullif(f #>> '{properties,radius_m}', '')::int,
      nullif(f #>> '{properties,day_index}', '')::int,
      coalesce((f #>> '{properties,grows}')::boolean, false),
      nullif(f #>> '{properties,ping_interval_override}', '')::int,
      coalesce((f #>> '{properties,crossing_allowed}')::boolean, false),
      f #>> '{properties,restricted_type}',
      nullif(f #>> '{properties,owner_participant_id}', '')::uuid
    );
    n := n + 1;
  end loop;
  -- Alle starten am selben Punkt: der Wartebereich der Hunter liegt immer am Startpunkt.
  perform public.place_hunter_wait(p_game_id);
  perform public.log_game_event(p_game_id, 'map_saved', jsonb_build_object('zones', n));
  return n;
end; $$;

-- use_item: Hunter-Standorte als einmaliger Ping (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
      select coalesce(jsonb_agg(jsonb_build_object('name', public.pname(p.id), 'lat', pos.lat, 'lng', pos.lng, 'at', pos.at)), '[]') into v_snapshot
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

-- grant_jokers: Texte zu den Jokern (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.grant_jokers(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_types jsonb := coalesce(v_cfg -> 'joker' -> 'types', '[]');
  v_done jsonb;
  v_t jsonb;
  v_p public.participants;
  i int;
begin
  if not public.cfg_bool(v_cfg, 'joker', 'enabled', false) or jsonb_typeof(v_types) <> 'array' or jsonb_array_length(v_types) = 0 then return; end if;
  if p_game.status not in ('laeuft', 'finale') or p_game.hunt_start_at is null then return; end if;
  -- Sperrt die Zeile, damit zwei gleichzeitige Ticks einen Joker nicht doppelt vergeben.
  select coalesce(state_json -> 'jokers_granted', '[]') into v_done from public.games where id = p_game.id for update;
  for i in 0 .. jsonb_array_length(v_types) - 1 loop
    v_t := v_types -> i;
    continue when v_done @> jsonb_build_array(i);
    continue when p_now < p_game.hunt_start_at + make_interval(mins => coalesce((v_t ->> 'after_minutes')::int, 0));
    v_done := v_done || jsonb_build_array(i);
    update public.games set state_json = state_json || jsonb_build_object('jokers_granted', v_done) where id = p_game.id;
    for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall') loop
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
      values (p_game.id, v_p.id, 'joker', v_t ->> 'type', (v_t ->> 'minutes')::int, greatest(p_game.current_day, 1), p_now, 'zeit');
      perform public.notify(p_game.id, null, v_p.id, 'joker', 'Neuer Joker: ' || case v_t ->> 'type'
          when 'regeneration' then 'Regeneration'
          when 'hunter_erfragen' then 'Hunter-Standorte'
          when 'catch_free' then 'Schutzschild'
          else replace(v_t ->> 'type', '_', ' ') end,
        case v_t ->> 'type'
          when 'regeneration' then 'Du wirst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gepingt, und keine Blitzjagd auf dich ist möglich. Einsetzen unter Aktionen (nicht während einer Blitzjagd).'
          when 'hunter_erfragen' then 'Zeigt dir beim Einsetzen einmalig, wo alle Hunter gerade sind (nicht live). Einsetzen unter Aktionen.'
          when 'catch_free' then 'Du kannst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gefangen werden. Einsetzen unter Aktionen.'
          else '' end, '{}', 'hoch');
    end loop;
  end loop;
end; $$;

-- Spielfeld verlassen: wie oft jemand draussen war.
alter table public.participants add column if not exists out_exits int not null default 0;
alter table public.participants add column if not exists danger_exits int not null default 0;

-- check_player_zone: Countdown beim 1. und 2. Verlassen, ab dem 3. Mal sofort live (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
create or replace function public.check_player_zone(p_game public.games, p_p public.participants, p_point extensions.geometry, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_area extensions.geometry;
  v_inside boolean;
  v_tol int := public.cfg_int(v_cfg, 'zone', 'edge_tolerance_m', 25);
  v_grace int := public.cfg_int(v_cfg, 'out_of_bounds', 'grace_seconds', 60);
  v_max int := public.cfg_int(v_cfg, 'out_of_bounds', 'max_minutes', 120);
  v_restricted public.zones;
  v_cross int := public.cfg_int(v_cfg, 'zone', 'restricted_crossing_max_seconds', 60);
  v_exits int := p_p.out_exits;
  v_danger int := p_p.danger_exits;
begin
  v_area := public.allowed_area(p_game.id, p_p.id, p_game.current_day, public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false));
  v_inside := v_area is null or ST_DWithin(v_area::geography, p_point::geography, v_tol);

  -- Gefahrenzonen: gleiche Regel wie beim Verlassen des Spielfelds, mit eigener Zählung.
  -- 1. und 2. Mal: Alarm und Countdown, danach live. Ab dem 3. Mal: sofort live. Zu lange drin: Folge wie ausserhalb.
  -- Zonen mit "Überqueren erlaubt" (z. B. Brücken) lösen nichts aus, solange man sie in der erlaubten Zeit überquert.
  select * into v_restricted from public.zones where game_id = p_game.id and kind = 'sperrzone' and ST_Covers(geom, p_point) limit 1;
  if v_restricted.id is not null and v_restricted.crossing_allowed then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false where id = p_p.id;
    elsif not p_p.restricted_violated and p_now - p_p.restricted_since > make_interval(secs => v_cross) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'sperrzone',
        jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
  elsif v_restricted.id is not null then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false,
        danger_exits = danger_exits + 1 where id = p_p.id
      returning danger_exits into v_danger;
      p_p.restricted_since := p_now;
      p_p.restricted_violated := false;
      if v_grace > 0 and v_danger <= 2 then
        perform public.notify(p_game.id, null, p_p.id, 'danger_warning', 'Gefahrenzone! Sofort raus',
          coalesce(nullif(v_restricted.name, ''), 'Gefahrenzone') || ': du hast ' || v_grace || ' Sekunden Zeit, sonst sehen dich die Hunter live ('
          || v_danger || '. Mal von 2 mit Countdown).',
          jsonb_build_object('deadline', p_now + make_interval(secs => v_grace), 'exits', v_danger), 'kritisch');
      else
        p_p.restricted_since := p_now - make_interval(secs => v_grace);
      end if;
    end if;
    if not p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.open_live_window(p_game.id, p_p.id, 'gefahrenzone', p_now, null);
      perform public.notify(p_game.id, null, p_p.id, 'danger_live', 'Du bist in einer Gefahrenzone!',
        'Die Hunter sehen dich live. Verlass die Zone sofort. Nach ' || v_max || ' min gilt: ' ||
        case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch') when 'catch' then 'gefangen' when 'disqualify' then 'disqualifiziert' else 'Strafe' end || '.',
        '{}', 'kritisch');
      perform public.notify(p_game.id, 'taskforce', null, 'danger_live', public.pname(p_p.id) || ' ist in einer Gefahrenzone', 'Live-Standort sichtbar.', '{}', 'hoch');
    elsif p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) + make_interval(mins => v_max) then
      update public.participants set restricted_zone_id = null, restricted_since = null, restricted_violated = false where id = p_p.id;
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
        when 'catch' then perform public.auto_catch(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        when 'disqualify' then perform public.disqualify(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        else perform public.create_violation(p_game, p_p.id, 'sperrzone', jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
      end case;
      return;
    end if;
  elsif p_p.restricted_zone_id is not null then
    if p_p.restricted_violated then
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      perform public.notify(p_game.id, 'taskforce', null, 'back_inside', public.pname(p_p.id) || ' hat die Gefahrenzone verlassen', 'Live-Standort beendet.', '{}', 'normal');
    end if;
    update public.participants set restricted_zone_id = null, restricted_since = null, restricted_violated = false where id = p_p.id;
  end if;
  if v_inside or (p_p.grace_until is not null and p_p.grace_until > p_now) then
    if p_p.state = 'ausserhalb' then
      update public.participants set state = 'aktiv', out_pending_since = null,
        out_accum_s = case when public.cfg_text(v_cfg, 'out_of_bounds', 'count_mode', 'pro_ausflug') = 'pro_ausflug' then 0 else out_accum_s end
      where id = p_p.id;
      perform public.close_live_windows(p_p.id, 'ausserhalb', p_now);
      perform public.notify(p_game.id, null, p_p.id, 'back_inside', 'Zurück im Spielfeld', '', '{}', 'normal');
      perform public.notify(p_game.id, 'taskforce', null, 'back_inside', public.pname(p_p.id) || ' ist zurück im Spielfeld', 'Live-Standort beendet.', '{}', 'normal');
    elsif p_p.out_pending_since is not null then
      update public.participants set out_pending_since = null where id = p_p.id;
    end if;
    return;
  end if;

  if p_p.state = 'ausserhalb' then return; end if;
  if p_p.out_pending_since is null then
    -- Jedes Verlassen zählt. 1. und 2. Mal: Alarm und Countdown. Ab dem 3. Mal: sofort live.
    update public.participants set out_pending_since = p_now, out_exits = out_exits + 1 where id = p_p.id
    returning out_exits into v_exits;
    if v_grace > 0 and v_exits <= 2 then
      perform public.notify(p_game.id, null, p_p.id, 'outside_warning', 'Zurück ins Spielfeld!',
        'Du hast ' || v_grace || ' Sekunden Zeit, sonst sehen dich die Hunter live (' || v_exits || '. Mal von 2 mit Countdown).',
        jsonb_build_object('deadline', p_now + make_interval(secs => v_grace), 'exits', v_exits), 'kritisch');
      return;
    end if;
    p_p.out_pending_since := p_now - make_interval(secs => v_grace);
  end if;
  if p_now - p_p.out_pending_since >= make_interval(secs => v_grace) then
    update public.participants set state = 'ausserhalb' where id = p_p.id;
    -- Immer live an die Hunter, solange die Person ausserhalb ist.
    perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
    perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb!',
      case when v_exits > 2 then 'Schon das ' || v_exits || '. Mal: kein Countdown mehr. ' else '' end ||
      greatest(0, v_max - p_p.out_accum_s / 60) || ' min bis ' ||
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'disqualify')
        when 'catch' then 'zum Fang' when 'disqualify' then 'zur Disqualifikation' else 'zur Strafe' end || '. Die Hunter sehen dich live.',
      '{}', 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
  end if;
end; $$;

