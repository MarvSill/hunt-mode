-- Runde 17 (Rückmeldungen Marvin, 2026-11-14)
-- 1. Spielfeld verlassen: kein Countdown mehr, sofort live für die Hunter und Alarm. (Gefahrenzonen behalten den Countdown.)
-- 2. Fluchtpunkt: öffnet erst, wenn die Spielzeit abgelaufen ist. Danach läuft das Spiel weiter, bis alle Spieler gefangen
--    oder am Fluchtpunkt sind, höchstens aber die eingestellte Zeit (exit.arrival_deadline_offset_minutes, Standard 60 min).
--    Wer dann nicht angekommen ist, hat verloren. Ohne Fluchtpunkt endet das Spiel mit der Spielzeit; wer noch frei ist, gewinnt.

-- ---------------------------------------------------------------------------
-- Fluchtpunkt öffnet mit dem Ende der Spielzeit (nicht mehr X min vorher).
create or replace function public.exit_usable_minutes(p_cfg jsonb)
returns int language sql immutable as $$ select 0 $$;

-- Höchstzeit nach der Spielzeit (min), 5 bis 240; alte Spiele mit 0 bekommen 60. Ohne Fluchtpunkt 0.
create or replace function public.exit_extra_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.cfg_bool(p_cfg, 'exit', 'enabled', true) and public.cfg_text(p_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
    then least(240, greatest(5, coalesce(nullif(public.cfg_int(p_cfg, 'exit', 'arrival_deadline_offset_minutes', 60), 0), 60))) else 0 end;
$$;

-- Spielende (deadline_at) folgt immer der Spielzeit (ends_at) plus Höchstzeit: beim Start, bei Pausen und bei
-- Regeländerungen in der Pause. So müssen die vielen Stellen, die ends_at setzen, nicht einzeln angepasst werden.
create or replace function public.games_deadline()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.ends_at is not null and new.status in ('vorsprung', 'laeuft', 'finale')
     and (tg_op = 'INSERT' or new.ends_at is distinct from old.ends_at or new.config_json is distinct from old.config_json
          or new.deadline_at is distinct from old.deadline_at) then
    new.deadline_at := new.ends_at + make_interval(mins => public.exit_extra_minutes(new.config_json));
  end if;
  return new;
end; $$;
drop trigger if exists games_deadline on public.games;
create trigger games_deadline before insert or update on public.games
for each row execute function public.games_deadline();

-- Laufende Spiele gleich nachziehen.
update public.games set deadline_at = ends_at + make_interval(mins => public.exit_extra_minutes(config_json))
where status in ('vorsprung', 'laeuft', 'finale') and ends_at is not null;

-- ---------------------------------------------------------------------------
-- Spielfeld verlassen: sofort live und Alarm (zuletzt in 0016).
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
-- Spieltakt: Texte zum Fluchtpunkt (öffnet am Ende der Spielzeit, Ankunft bis zum Spielende). Zuletzt in 0025.
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
        'Er öffnet um ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' (Ende der Spielzeit). Dann habt ihr bis '
        || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' Zeit, in den Kreis zu kommen.', jsonb_build_object('open_at', v_open), 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
        'Ihr erfahrt ihn nicht. Er öffnet um ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || '. Gejagt wird bis '
        || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' oder bis alle gefangen oder angekommen sind.', '{}', 'hoch');
    end if;
  end if;

  perform public.tick_game_basis(p_game_id);

  select * into g from public.games where id = p_game_id;
  if g.status not in ('laeuft', 'finale') or g.paused_at is not null then return; end if;

  -- Freigabe: ab jetzt zählt, wer im Kreis steht.
  if g.exit_revealed and g.exit_zone_id is not null and v_now >= v_open and not coalesce((g.state_json ->> 'exit_open')::boolean, false) then
    update public.games set state_json = state_json || '{"exit_open": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_open', 'Fluchtpunkt ist jetzt offen!',
      'Wer bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' in den Kreis kommt, ist gerettet.', '{}', 'kritisch');
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
