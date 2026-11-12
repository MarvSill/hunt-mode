-- Runde 16:
-- 1. Spieler sehen die Pings der anderen Spieler (gleiche Pings wie die Hunter, aber ohne Blitzjagd- und Nähe-Alarm-Pings),
--    damit sie sich besser auf der Karte verteilen können.
-- 2. Neuer Joker "Nähe-Radar": zeigt eine eingestellte Zeit lang, ob ein Hunter näher als ein eingestellter Abstand ist (nicht wo).

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
    -- Ohne Blitzjagd- und Nähe-Alarm-Pings der anderen.
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
          or (p.role = 'spieler' and pg.visible_at <= v_now and pg.source not in ('speedhunt', 'proximity'))
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
-- Nähe-Alarm zweier Spieler (zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql):
-- - aktiv sofort nach dem Vorsprung (keine Wartezeit mehr),
-- - Meldungen mit dem Buchstaben des Spielers statt dem Namen,
-- - Regeneration schützt hier nicht: gepingt wird trotzdem, und der Spieler wird darauf hingewiesen.
create or replace function public.player_letter(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select 'Spieler ' || coalesce(nullif(tag, ''), '?') from public.participants where id = p_id;
$$;
revoke execute on function public.player_letter(uuid) from public, anon, authenticated;

create or replace function public.check_proximity(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_dist int := public.cfg_int(v_cfg, 'proximity', 'distance_m', 150);
  v_hyst int := public.cfg_int(v_cfg, 'proximity', 'hysteresis_m', 50);
  v_wait int := public.cfg_int(v_cfg, 'proximity', 'warn_minutes', 2);
  v_pair record;
  v_state public.proximity_pairs;
  v_id uuid;
begin
  if not public.cfg_bool(v_cfg, 'proximity', 'enabled', true) then return; end if;
  -- Ab der Bekanntgabe des Fluchtpunkts dürfen die Spieler zusammen sein.
  if p_game.exit_revealed then return; end if;
  -- Aktiv, sobald der Vorsprung vorbei ist.
  if p_game.hunt_start_at is null or p_now < p_game.hunt_start_at then return; end if;

  for v_pair in
    select a.id a_id, b.id b_id, pa.lat alat, pa.lng alng, pa.accuracy_m aacc, pb.lat blat, pb.lng blng, pb.accuracy_m bacc,
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
      if v_state.a is null or v_state.warned_at is null then
        -- 1. Beide warnen und den Standort des anderen zeigen.
        insert into public.proximity_pairs (game_id, a, b, alerted, warned_at) values (p_game.id, v_pair.a_id, v_pair.b_id, false, p_now)
        on conflict (a, b) do update set warned_at = p_now, alerted = false;
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_self', 'Nähe-Alarm: ' || public.player_letter(v_pair.b_id) || ' ist in der Nähe',
          'Ihr seid unter ' || v_dist || ' m. Entfernt euch innerhalb von ' || v_wait || ' min, sonst bekommen die Hunter euren Standort.',
          jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'tag', (select coalesce(nullif(tag, ''), '?') from public.participants where id = v_pair.b_id), 'deadline', p_now + make_interval(mins => v_wait)), 'kritisch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Nähe-Alarm: ' || public.player_letter(v_pair.a_id) || ' ist in der Nähe',
          'Ihr seid unter ' || v_dist || ' m. Entfernt euch innerhalb von ' || v_wait || ' min, sonst bekommen die Hunter euren Standort.',
          jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'tag', (select coalesce(nullif(tag, ''), '?') from public.participants where id = v_pair.a_id), 'deadline', p_now + make_interval(mins => v_wait)), 'kritisch');
        foreach v_id in array array[v_pair.a_id, v_pair.b_id] loop
          if public.has_effect(v_id, 'regeneration', p_now) then
            perform public.notify(p_game.id, null, v_id, 'proximity_self', 'Regeneration schützt hier nicht',
              'Beim Nähe-Alarm wirst du trotzdem gepingt, auch mit Regeneration.', '{}', 'kritisch');
          end if;
        end loop;
      elsif not v_state.alerted and p_now >= v_state.warned_at + make_interval(mins => v_wait) then
        -- 2. Nach Ablauf immer noch zu nahe: Ping beider an die Hunter (auch mit Regeneration).
        update public.proximity_pairs set alerted = true, last_alert_at = p_now where a = v_pair.a_id and b = v_pair.b_id;
        perform public.create_ping(p_game, v_pair.a_id, 'proximity', v_pair.alat, v_pair.alng, v_pair.aacc, null, null, null, null, 0, p_now);
        perform public.create_ping(p_game, v_pair.b_id, 'proximity', v_pair.blat, v_pair.blng, v_pair.bacc, null, null, null, null, 0, p_now);
        perform public.notify(p_game.id, 'taskforce', null, 'proximity', 'Nähe-Alarm',
          public.player_letter(v_pair.a_id) || ' und ' || public.player_letter(v_pair.b_id) || ' sind zusammen (unter ' || v_dist || ' m). Ping auf der Karte.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_ping', 'Die Hunter haben euren Standort', 'Ihr wart zu lange zusammen.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_ping', 'Die Hunter haben euren Standort', 'Ihr wart zu lange zusammen.', '{}', 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.a is not null and (v_state.warned_at is not null or v_state.alerted) then
      update public.proximity_pairs set alerted = false, warned_at = null where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;
