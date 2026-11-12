-- Runde 16:
-- 1. Spieler sehen die Pings der anderen Spieler (gleiche Pings wie die Hunter, aber ohne Blitzjagd-Pings),
--    damit sie sich besser auf der Karte verteilen können.
-- 2. Neuer Joker "Nähe-Radar": zeigt eine eingestellte Zeit lang, ob ein Hunter näher als ein eingestellter Abstand ist (nicht wo).
-- 3. Der Nähe-Alarm zweier Spieler wird ganz entfernt (Prüfung im Spieltakt, Funktion, Tabelle).

-- ---------------------------------------------------------------------------
-- Abstand je Joker (nur Nähe-Radar), beim Freischalten aus der Einstellung übernommen.
alter table public.inventory_items add column if not exists distance_m int;

-- grant_jokers: mit Abstand und Texten für den Nähe-Radar (zuletzt in 0016_ein_startpunkt_ohne_zentrale.sql)
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
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, distance_m, granted_day, granted_at, source)
      values (p_game.id, v_p.id, 'joker', v_t ->> 'type', (v_t ->> 'minutes')::int,
              case when v_t ->> 'type' = 'naehe_radar' then coalesce((v_t ->> 'distance_m')::int, 500) end,
              greatest(p_game.current_day, 1), p_now, 'zeit');
      perform public.notify(p_game.id, null, v_p.id, 'joker', 'Neuer Joker: ' || case v_t ->> 'type'
          when 'regeneration' then 'Regeneration'
          when 'hunter_erfragen' then 'Hunter-Standorte'
          when 'naehe_radar' then 'Nähe-Radar'
          when 'catch_free' then 'Schutzschild'
          else replace(v_t ->> 'type', '_', ' ') end,
        case v_t ->> 'type'
          when 'regeneration' then 'Du wirst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gepingt, und keine Blitzjagd auf dich ist möglich. Einsetzen unter Aktionen (nicht während einer Blitzjagd).'
          when 'hunter_erfragen' then 'Zeigt dir beim Einsetzen einmalig, wo alle Hunter gerade sind (nicht live). Einsetzen unter Aktionen.'
          when 'naehe_radar' then 'Zeigt dir ' || coalesce(v_t ->> 'minutes', '15') || ' min lang, ob ein Hunter näher als ' || coalesce(v_t ->> 'distance_m', '500') || ' m ist (nicht wo). Einsetzen unter Aktionen.'
          when 'catch_free' then 'Du kannst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gefangen werden. Einsetzen unter Aktionen.'
          else '' end, '{}', 'hoch');
    end loop;
  end loop;
end; $$;

-- ---------------------------------------------------------------------------
-- use_item: Nähe-Radar hier, alle anderen Joker wie bisher.
alter function public.use_item(uuid, jsonb) rename to use_item_basis;
revoke execute on function public.use_item_basis(uuid, jsonb) from public, anon, authenticated;

create or replace function public.use_item(p_item_id uuid, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_i public.inventory_items;
  v_me public.participants;
  g public.games;
  v_now timestamptz;
  v_minutes int;
  v_dist int;
begin
  select * into v_i from public.inventory_items where id = p_item_id;
  if v_i.id is null then raise exception 'Gegenstand nicht gefunden.' using errcode = 'P0001'; end if;
  if v_i.type <> 'naehe_radar' then return public.use_item_basis(p_item_id, p_payload); end if;
  v_me := public.require_participant(v_i.game_id, array['spieler']);
  if v_me.id <> v_i.participant_id then raise exception 'Nicht dein Gegenstand.' using errcode = '42501'; end if;
  g := public.require_running(v_i.game_id);
  v_now := public.engine_now(g.id);
  if v_i.used_at is not null or v_i.expired then raise exception 'Schon benutzt oder verfallen.' using errcode = 'P0001'; end if;
  if v_me.state not in ('aktiv', 'ausserhalb') then raise exception 'Du bist nicht mehr im Spiel.' using errcode = 'P0001'; end if;
  v_minutes := coalesce(v_i.minutes, 15);
  v_dist := coalesce(v_i.distance_m, 500);
  insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
  values (g.id, v_me.id, 'naehe_radar', v_now, v_now + make_interval(mins => v_minutes), jsonb_build_object('distance_m', v_dist), v_i.id);
  perform public.notify(g.id, null, v_me.id, 'joker', 'Nähe-Radar aktiv',
    v_minutes || ' min lang siehst du, ob ein Hunter näher als ' || v_dist || ' m ist.', '{}', 'normal');
  update public.inventory_items set used_at = v_now where id = v_i.id;
  perform public.log_game_event(g.id, 'item_used', jsonb_build_object('type', 'naehe_radar', 'participant', v_me.id));
  perform public.bump(g.id);
  return jsonb_build_object('type', 'naehe_radar');
end; $$;
revoke execute on function public.use_item(uuid, jsonb) from public, anon;
grant execute on function public.use_item(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Spielstand (zuletzt in 0023_pause_sicherheit_fang.sql):
-- Spieler bekommen zusätzlich die Pings der anderen Spieler und den Stand ihres Nähe-Radars.
create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v jsonb;
  g public.games;
  me public.participants;
  v_now timestamptz;
  v_hist int;
  v_radar public.active_effects;
  v_my public.positions;
  v_dist int;
begin
  v := public.game_state_basis(p_game_id);
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  v_now := public.engine_now(g.id);
  v := jsonb_set(v, '{game,pause_kind}', coalesce(to_jsonb(case when g.paused_at is not null then coalesce(g.pause_kind, 'notfall') end), 'null'::jsonb));
  v := jsonb_set(v, '{me,safety_ok}', to_jsonb(me.safety_ok_at is not null));
  v := v || jsonb_build_object('safety_missing', (
    select coalesce(jsonb_agg(p.id), '[]') from public.participants p
    where p.game_id = p_game_id and p.role in ('spieler', 'hunter', 'zentrale') and p.safety_ok_at is null));

  if me.role = 'spieler' and g.status not in ('beendet', 'archiviert') then
    v_hist := public.cfg_int(g.config_json, 'ping', 'history_per_player', 200);
    -- Eigene Pings wie bisher, dazu die Pings der anderen Spieler, sobald die Hunter sie auch sehen.
    -- Ohne Blitzjagd-Pings der anderen.
    v := jsonb_set(v, '{pings}', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds, 'is_fake', case when x.participant_id = me.id then x.is_fake end, 'truth', null
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg join public.participants p on p.id = pg.participant_id
        where pg.game_id = g.id and (
          pg.participant_id = me.id
          or (p.role = 'spieler' and pg.visible_at <= v_now and pg.source <> 'speedhunt')
        )
      ) x where x.rn <= v_hist
    ));

    -- Joker mit Abstand (Nähe-Radar).
    v := jsonb_set(v, '{me,inventory}', (
      select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'distance_m', i.distance_m, 'source', i.source) order by i.granted_at), '[]')
      from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired));

    -- Nähe-Radar: nur ja/nein, nie wo. Zählt Hunter mit einem Standort der letzten 10 min.
    select * into v_radar from public.active_effects
    where participant_id = me.id and type = 'naehe_radar' and starts_at <= v_now and ends_at > v_now
    order by ends_at desc limit 1;
    if v_radar.id is not null then
      v_dist := coalesce((v_radar.payload ->> 'distance_m')::int, 500);
      select * into v_my from public.positions where participant_id = me.id;
      v := jsonb_set(v, '{me,radar}', jsonb_build_object(
        'ends_at', v_radar.ends_at, 'distance_m', v_dist,
        'near', case when v_my.participant_id is null then null else exists (
          select 1 from public.positions hp join public.participants h on h.id = hp.participant_id
          where h.game_id = g.id and h.role = 'hunter' and hp.at > v_now - interval '10 minutes'
            and public.dist_m(hp.geom, v_my.geom) <= v_dist) end));
    end if;
  end if;
  return v;
end; $$;
revoke execute on function public.game_state(uuid) from public, anon;
grant execute on function public.game_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Nähe-Alarm zweier Spieler entfernt.
-- tick_game_basis: wie zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql (als tick_game, in 0022 umbenannt),
-- nur ohne die Prüfung, ob zwei Spieler zu nahe sind.
create or replace function public.tick_game_basis(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_delta int;
  v_p public.participants;
  v_e public.active_effects;
  v_sh public.speedhunts;
  v_h public.hideouts;
  v_v public.violations;
  v_c public.catches;
  v_ch public.challenges;
  v_pos record;
  v_max int;
  v_remaining int;
  v_announce int;
  v_times jsonb;
  v_t jsonb;
  v_target uuid;
  v_leave int;
  v_loss int;
  v_runner_pos public.positions;
  v_hunter_pos public.positions;
begin
  select * into g from public.games where id = p_game_id for update skip locked;
  if g.id is null or g.status not in ('vorsprung', 'laeuft', 'finale') then return; end if;
  v_now := now() + g.clock_offset;
  if g.paused_at is not null then return; end if;
  v_cfg := g.config_json;
  v_delta := greatest(0, extract(epoch from (v_now - coalesce(g.last_tick_at, v_now)))::int);

  -- Jagdbeginn
  if g.status = 'vorsprung' and v_now >= g.hunt_start_at then
    g := public.hunt_begin(g, v_now);
  end if;
  if g.status = 'vorsprung' then
    update public.games set last_tick_at = v_now where id = g.id;
    perform public.bump(g.id);
    return;
  end if;

  -- 1. Tagesreset
  while g.next_day_at is not null and g.next_day_at <= v_now loop
    g := public.day_reset(g, v_now);
  end loop;

  -- Joker, sobald ihre Freischaltzeit erreicht ist
  perform public.grant_jokers(g, v_now);

  -- Spielfeld-Phasen alle X Minuten
  if public.shrink_every_minutes(v_cfg) > 0 then
    while (g.state_json ->> 'next_phase_at') is not null and (g.state_json ->> 'next_phase_at')::timestamptz <= v_now loop
      g := public.phase_advance(g, v_now);
    end loop;
    g := public.phase_announce(g, v_now);
  end if;

  -- Ankündigung der Spielfeldänderung
  v_announce := public.cfg_int(v_cfg, 'zone', 'shrink_announce_minutes', 180);
  if public.shrink_every_minutes(v_cfg) = 0 and g.next_day_at is not null and g.next_day_at - make_interval(mins => v_announce) <= v_now
     and coalesce((g.state_json ->> 'announced_day')::int, 0) < g.current_day + 1
     and exists (select 1 from public.zones where game_id = g.id and kind = 'spielfeld' and day_index = g.current_day + 1) then
    update public.games set state_json = state_json || jsonb_build_object('announced_day', g.current_day + 1), map_version = map_version + 1
    where id = g.id returning * into g;
    perform public.notify(g.id, 'alle', null, 'zone_announce', 'Neues Spielfeld ab ' || to_char(g.next_day_at at time zone g.timezone, 'HH24:MI'),
      'Die neuen Grenzen sind auf der Karte gestrichelt.', '{}', 'hoch');
  end if;

  -- 3. Effekt-Enden
  for v_e in select * from public.active_effects where game_id = g.id and ends_at is not null and ends_at <= v_now and not (payload ? 'done') loop
    update public.active_effects set payload = payload || '{"done": true}' where id = v_e.id;
    if v_e.type = 'hotel' then
      perform public.create_ping(g, v_e.participant_id, 'hotel_end', (v_e.payload ->> 'lat')::double precision, (v_e.payload ->> 'lng')::double precision,
        null, null, null, null, 'Hotel', 0, v_now);
      perform public.notify(g.id, null, v_e.participant_id, 'hotel_end', 'Hotel vorbei: du wurdest erkannt!',
        'Die Hunter kennen deinen Ort. Verlass ihn sofort.', '{}', 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'hotel_end', 'Hotel-Ping: ' || public.pname(v_e.participant_id), '', '{}', 'hoch');
    elsif v_e.type in ('regeneration', 'catch_free', 'leo') then
      perform public.notify(g.id, null, v_e.participant_id, 'effect_end',
        case v_e.type when 'regeneration' then 'Regeneration vorbei' when 'catch_free' then 'Schutzschild vorbei' else 'Schonzeit vorbei' end,
        '', '{}', 'normal');
    end if;
  end loop;
  -- Aufgeschobene Straf-Blitzjagds starten, sobald keine Regeneration mehr läuft.
  for v_sh in select * from public.speedhunts where game_id = g.id and status = 'aufgeschoben' loop
    if not public.has_effect(v_sh.target_id, 'regeneration', v_now) then
      update public.speedhunts set status = 'beendet', ended_at = v_now, end_reason = 'neu_gestartet' where id = v_sh.id;
      perform public.start_speedhunt_internal(g, v_sh.target_id, v_sh.triggered_by, true, v_now);
    end if;
  end loop;

  -- 4. Pings
  for v_p in select * from public.participants where game_id = g.id and role = 'spieler' and next_ping_at is not null and next_ping_at <= v_now loop
    perform public.process_ping_due(g, v_p, v_now);
  end loop;

  -- 5. Speedhunt-Timeouts und Zufalls-Speedhunts
  for v_sh in select * from public.speedhunts where game_id = g.id and status = 'laeuft' and deadline_at <= v_now loop
    perform public.end_speedhunt(g, v_sh, 'zeit_abgelaufen', v_now);
  end loop;
  v_times := coalesce(g.state_json -> 'random_speedhunts', '[]');
  if jsonb_array_length(v_times) > 0 then
    for v_t in select * from jsonb_array_elements(v_times) loop
      if (v_t #>> '{}')::timestamptz <= v_now and g.speedhunts_left > 0 then
        select p.id into v_target from public.participants p
        where p.game_id = g.id and p.role = 'spieler' and p.state = 'aktiv'
          and not public.has_effect(p.id, 'regeneration', v_now) and not public.has_effect(p.id, 'hotel', v_now)
          and (public.running_speedhunt_on(p.id)).id is null
        order by random() limit 1;
        if v_target is not null then
          perform public.start_speedhunt_internal(g, v_target, null, false, v_now);
          update public.games set speedhunts_left = speedhunts_left - 1 where id = g.id returning * into g;
        end if;
        v_times := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(v_times) x where x <> v_t);
      end if;
    end loop;
    update public.games set state_json = state_json || jsonb_build_object('random_speedhunts', v_times) where id = g.id returning * into g;
  end if;

  -- Ausserhalb-Zeit
  v_max := public.cfg_int(v_cfg, 'out_of_bounds', 'max_minutes', 120);
  for v_p in select * from public.participants where game_id = g.id and role = 'spieler' and state = 'ausserhalb' loop
    update public.participants set out_accum_s = out_accum_s + v_delta where id = v_p.id returning * into v_p;
    if v_p.out_accum_s >= v_max * 60 then
      perform public.close_live_windows(v_p.id, 'ausserhalb', v_now);
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
        when 'catch' then perform public.auto_catch(g, v_p.id, 'Zu lange ausserhalb', v_now);
        when 'disqualify' then perform public.disqualify(g, v_p.id, 'Zu lange ausserhalb des Spielfelds', v_now);
        else
          update public.participants set out_accum_s = 0 where id = v_p.id;
          perform public.create_violation(g, v_p.id, 'ausserhalb_limit', '{}', v_now);
      end case;
      select * into g from public.games where id = g.id;
      exit when g.status = 'beendet';
    end if;
  end loop;
  if g.status = 'beendet' then perform public.bump(g.id); return; end if;

  -- Verschanzen-Zeit (7.8)
  v_max := public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120);
  for v_h in select h.* from public.hideouts h join public.participants p on p.id = h.participant_id
             where h.game_id = g.id and h.status = 'aktiv' and h.inside and p.state in ('aktiv', 'ausserhalb') loop
    if public.has_effect(v_h.participant_id, 'hotel', v_now) then continue; end if;
    update public.hideouts set accum_s = accum_s + v_delta where id = v_h.id returning * into v_h;
    v_remaining := v_max * 60 - v_h.accum_s;
    if v_remaining <= 0 then
      update public.hideouts set status = 'abgelaufen', inside = false, left_at = v_now where id = v_h.id;
      if public.cfg_text(v_cfg, 'hideout', 'on_timeout', 'catch') = 'catch' then
        perform public.auto_catch(g, v_h.participant_id, 'Verschanzen über dem Limit', v_now);
      else
        perform public.create_violation(g, v_h.participant_id, 'verschanzen_limit', '{}', v_now);
      end if;
      select * into g from public.games where id = g.id;
      exit when g.status = 'beendet';
    elsif v_remaining <= 120 and v_h.warned < 3 then
      update public.hideouts set warned = 3 where id = v_h.id;
      perform public.notify(g.id, null, v_h.participant_id, 'hideout_warning', 'Noch 2 min verschanzt!',
        'Dann musst du raus (' || public.cfg_int(v_cfg, 'hideout', 'min_leave_distance_m', 200) || ' m Abstand).', '{}', 'kritisch');
    elsif v_remaining <= 600 and v_h.warned < 2 then
      update public.hideouts set warned = 2 where id = v_h.id;
      perform public.notify(g.id, null, v_h.participant_id, 'hideout_warning', 'Noch 10 min verschanzt',
        'Dann musst du raus (' || public.cfg_int(v_cfg, 'hideout', 'min_leave_distance_m', 200) || ' m Abstand).', '{}', 'hoch');
    elsif v_remaining <= 1800 and v_h.warned < 1 then
      update public.hideouts set warned = 1 where id = v_h.id;
      perform public.notify(g.id, null, v_h.participant_id, 'hideout_warning', 'Noch 30 min verschanzt', '', '{}', 'hoch');
    end if;
  end loop;
  if g.status = 'beendet' then perform public.bump(g.id); return; end if;

  -- Verstösse automatisch verhängen
  for v_v in select * from public.violations where game_id = g.id and status = 'offen' and auto_apply_at is not null and auto_apply_at <= v_now loop
    perform public.apply_penalty(g, v_v.id, v_v.proposed_penalty, v_now);
    select * into g from public.games where id = g.id;
    exit when g.status = 'beendet';
  end loop;
  if g.status = 'beendet' then perform public.bump(g.id); return; end if;

  -- Fang-Bestätigungen und Beweise, die abgelaufen sind
  for v_c in select * from public.catches where game_id = g.id and status in ('wartet_auf_bestaetigung', 'wartet_auf_beweis') and expires_at <= v_now loop
    if v_c.status = 'wartet_auf_beweis' then
      update public.catches set status = 'abgelehnt', reason = 'Kein Beweis innerhalb der Frist' where id = v_c.id;
      perform public.notify(g.id, null, v_c.hunter_id, 'catch_rejected', 'Fang ungültig', 'Kein Foto/Video innerhalb von 2 min.', '{}', 'hoch');
    elsif public.cfg_text(v_cfg, 'roles', 'gm_mode', 'auto') = 'mensch' then
      perform public.notify(g.id, 'gm', null, 'catch_decide', 'Fang bestätigen?', public.pname(v_c.runner_id) || ' hat nicht reagiert.', jsonb_build_object('catch_id', v_c.id), 'hoch');
      update public.catches set expires_at = null where id = v_c.id;
    else
      -- Automatisch: gültig, wenn der GPS-Abstand passt.
      select * into v_runner_pos from public.positions where participant_id = v_c.runner_id;
      select * into v_hunter_pos from public.positions where participant_id = v_c.hunter_id;
      if v_runner_pos.participant_id is not null and v_hunter_pos.participant_id is not null
         and public.dist_m(v_runner_pos.geom, v_hunter_pos.geom) <= public.cfg_int(v_cfg, 'catch', 'max_distance_m', 30) + coalesce(v_runner_pos.accuracy_m, 0) + coalesce(v_hunter_pos.accuracy_m, 0) then
        perform public.apply_catch(g, v_c.id, v_now);
      else
        update public.catches set status = 'abgelehnt', reason = 'Keine Bestätigung, GPS-Abstand zu gross' where id = v_c.id;
        perform public.notify(g.id, null, v_c.hunter_id, 'catch_rejected', 'Fang abgelehnt', 'Keine Bestätigung und GPS-Abstand zu gross.', '{}', 'hoch');
      end if;
      select * into g from public.games where id = g.id;
      exit when g.status = 'beendet';
    end if;
  end loop;
  if g.status = 'beendet' then perform public.bump(g.id); return; end if;

  -- Challenges
  for v_ch in select * from public.challenges where game_id = g.id and status in ('geplant', 'angekuendigt', 'laeuft') loop
    if v_ch.status = 'geplant' and coalesce(v_ch.announce_at, v_ch.starts_at) <= v_now then
      update public.challenges set status = 'angekuendigt' where id = v_ch.id;
      perform public.notify(g.id, 'spieler', null, 'challenge_announce', 'Challenge: ' || v_ch.title,
        'Start ' || to_char(v_ch.starts_at at time zone g.timezone, 'HH24:MI') || '. ' || left(v_ch.description, 200), jsonb_build_object('challenge_id', v_ch.id), 'hoch');
      if v_ch.reveal_location_to_taskforce then
        perform public.notify(g.id, 'taskforce', null, 'challenge_announce', 'Challenge der Spieler: ' || v_ch.title,
          'Start ' || to_char(v_ch.starts_at at time zone g.timezone, 'HH24:MI'), jsonb_build_object('challenge_id', v_ch.id), 'normal');
      end if;
      v_ch.status := 'angekuendigt';
    end if;
    if v_ch.status = 'angekuendigt' and v_ch.starts_at <= v_now then
      update public.challenges set status = 'laeuft' where id = v_ch.id;
      perform public.notify(g.id, 'spieler', null, 'challenge_start', 'Challenge läuft: ' || v_ch.title, '', jsonb_build_object('challenge_id', v_ch.id), 'hoch');
      v_ch.status := 'laeuft';
    end if;
    if v_ch.status = 'laeuft' and v_ch.ends_at <= v_now then
      update public.challenges set status = 'beendet' where id = v_ch.id;
      update public.challenge_entries set result = 'gescheitert', decided_at = v_now where challenge_id = v_ch.id and result = 'offen';
      perform public.notify(g.id, 'spieler', null, 'challenge_end', 'Challenge beendet: ' || v_ch.title, '', jsonb_build_object('challenge_id', v_ch.id), 'normal');
    end if;
  end loop;

  -- Signalverlust und Akku (7.18, 15)
  v_loss := public.cfg_int(v_cfg, 'tracking', 'signal_loss_max_minutes', 15);
  for v_p in select * from public.participants where game_id = g.id and role in ('spieler', 'hunter', 'zentrale') and state in ('aktiv', 'ausserhalb')
             and last_seen_at is not null and last_seen_at < v_now - make_interval(mins => v_loss)
             and (signal_warned_at is null or signal_warned_at < last_seen_at) loop
    update public.participants set signal_warned_at = v_now where id = v_p.id;
    perform public.notify(g.id, 'gm', null, 'signal_loss', 'Signalverlust: ' || public.pname(v_p.id),
      'Seit ' || to_char(v_p.last_seen_at at time zone g.timezone, 'HH24:MI') || ' keine Daten.', '{}', 'hoch');
  end loop;


  -- Fluchtpunkt bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    -- Erst jetzt zufällig einen Kandidaten wählen, bevorzugt im aktuellen Spielfeld. Nur die Spieler sehen ihn.
    if g.exit_zone_id is null then
      update public.games set exit_zone_id = (
        select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
        order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.field_phase(g.id, g.current_day)), z.geom), z.geom) then 0 else 1 end, random()
        limit 1)
      where id = g.id returning * into g;
    end if;
    update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '. Ab jetzt dürft ihr auch zusammen sein.', '{}', 'kritisch');
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
      'Ihr erfahrt ihn nicht. Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
  end if;

  -- Spielende
  if v_now >= g.ends_at and not coalesce((g.state_json ->> 'end_notified')::boolean, false) and public.cfg_bool(v_cfg, 'exit', 'enabled', true)
     and g.deadline_at > g.ends_at then
    update public.games set state_json = state_json || '{"end_notified": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'alle', null, 'time_up', 'Spielzeit vorbei', 'Ankunft am Fluchtpunkt noch bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
  end if;
  if v_now >= g.deadline_at then
    perform public.finish_game(g, v_now, 'zeit_abgelaufen');
  end if;

  update public.games set last_tick_at = v_now where id = g.id;
  perform public.bump(g.id);
end; $$;
revoke execute on function public.tick_game_basis(uuid) from public, anon, authenticated;

drop function if exists public.check_proximity(public.games, timestamptz);
drop table if exists public.proximity_pairs;
