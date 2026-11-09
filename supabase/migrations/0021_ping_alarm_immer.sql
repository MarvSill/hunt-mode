-- 0021: Bei jedem Ping klingelt es bei allen Spielern, auch wenn vom gepingten Spieler
-- gerade kein Standort da ist. Die Hunter bekommen dann die Meldung "Kein Standort".

create or replace function public.ping_alarm(p_game public.games, p_p public.participants)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
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
    -- Auch ohne Standort klingelt es bei allen Spielern; die Hunter erfahren, dass kein Standort kam.
    perform public.notify(p_game.id, 'taskforce', null, 'ping_missing', 'Kein Standort: ' || public.pname(p_p.id),
      'Das Handy hat noch keinen Standort gesendet (App geschlossen oder kein GPS).', '{}', 'hoch');
    perform public.ping_alarm(p_game, p_p);
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
  perform public.ping_alarm(p_game, p_p);
end; $$;

-- Hunter sehen alle bisherigen Pings (vorher höchstens 5 je Spieler).
update public.games
set config_json = jsonb_set(config_json, '{ping,history_per_player}', '200'::jsonb, true)
where config_json ? 'ping' and coalesce((config_json #>> '{ping,history_per_player}')::int, 0) < 200;
