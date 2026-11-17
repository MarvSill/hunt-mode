-- Runde 21 (Rückmeldungen Marvin, 2026-11-15)
-- 1. Blitzjagd: der gejagte Spieler bekommt bei jeder Abfrage "Blitzjagd – dein Standort wurde geteilt" (statt nichts bzw.
--    einem normalen Ping-Text), damit man sieht, dass es eine Blitzjagd war.
-- 2. Gefahrenzonen mit Puffer nach innen: erst ab 8 m innerhalb zählt man als drin.
-- 3. Wiederholung: ein Punkt alle 5 s (statt 10 s), damit man die Wege genauer nachvollziehen kann.

-- ---------------------------------------------------------------------------
alter function public.speedhunt_query_internal(public.games, public.speedhunts, timestamptz) rename to speedhunt_query_basis;
revoke execute on function public.speedhunt_query_basis(public.games, public.speedhunts, timestamptz) from public, anon, authenticated;
create or replace function public.speedhunt_query_internal(p_game public.games, p_sh public.speedhunts, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_ping uuid;
begin
  v_ping := public.speedhunt_query_basis(p_game, p_sh, p_now);
  perform public.notify(p_game.id, null, p_sh.target_id, 'speedhunt_self', 'Blitzjagd – dein Standort wurde geteilt',
    'Abfrage ' || (p_sh.queries_used + 1) || ' von ' || p_sh.queries_total, jsonb_build_object('speedhunt_id', p_sh.id), 'hoch');
  return v_ping;
end; $$;
revoke execute on function public.speedhunt_query_internal(public.games, public.speedhunts, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Gefahrenzonen mit Puffer nach innen (zuletzt in 0027_fluchtpunkt_nach_spielzeit.sql).
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
  -- Nur wer mindestens 8 m innerhalb der Gefahrenzone ist, zählt (Puffer nach innen): wer daneben auf dem Trottoir
  -- steht, löst wegen der GPS-Ungenauigkeit keinen Alarm aus.
  select * into v_restricted from public.zones where game_id = p_game.id and kind = 'sperrzone' and ST_Covers(geom, p_point)
    and ST_Distance(ST_Boundary(geom)::geography, p_point::geography) >= 8 limit 1;
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
  -- Spielfeld verlassen: kein Countdown mehr. Sofort live für die Hunter und Alarm auf dem Handy.
  update public.participants set state = 'ausserhalb', out_pending_since = coalesce(out_pending_since, p_now), out_exits = out_exits + 1
  where id = p_p.id;
  perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
  perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb des Spielfelds!',
    'Die Hunter sehen dich jetzt live. Geh sofort zurück ins Spielfeld. Noch ' || greatest(0, v_max - p_p.out_accum_s / 60) || ' min, dann ' ||
    case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
      when 'catch' then 'giltst du als gefangen' when 'disqualify' then 'bist du disqualifiziert' else 'gibt es eine Strafe' end || '.',
    '{}', 'kritisch');
  perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
end; $$;

-- ---------------------------------------------------------------------------
-- Wiederholung: ein Punkt alle 5 s (zuletzt in 0023_pause_sicherheit_fang.sql, seit 0026 als game_replay_basis).
create or replace function public.game_replay_basis(p_game_id uuid)
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
          select distinct on (participant_id, floor(extract(epoch from at) / 5)) participant_id,
                 (floor(extract(epoch from at) / 5) * 5)::bigint b, ST_Y(geom) lat, ST_X(geom) lng
          from public.location_samples
          where game_id = p_game_id and not is_mock and coalesce(accuracy_m, 0) <= 100
          order by participant_id, floor(extract(epoch from at) / 5), accuracy_m nulls last, at desc
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
revoke execute on function public.game_replay_basis(uuid) from public, anon, authenticated;
