-- Zuschauer sehen das ganze Spiel live, können aber nichts tun.
-- Vorher bekamen sie Standorte und Pings nur mit Verzögerung (Standard 30 min) und nur, wenn „Zuschauer erlaubt“ an war.
-- Jetzt immer und ohne Verzögerung:
--   * wo alle Spieler und Hunter gerade sind, wie schnell sie sich bewegen, Akku, Zustand (frei, gefangen, ausserhalb …)
--   * alle Pings (auch Blitzjagd-Pings) und wann der nächste Ping jedes Spielers kommt
--   * welche Joker jeder hat und welche gerade wirken; jedes Einsetzen und Freischalten als Meldung
--   * Blitzjagden mit Ziel, Fänge, Gefahrenzonen, Spielfeld verlassen usw. (alle Meldungen an Spieler und Hunter, ohne Chat)
-- Die Einstellungen „Zuschauer erlaubt“ und „Verzögerung“ gelten nicht mehr.

-- Alte Prüfung der Zielgruppe entfernen (egal unter welchem Namen), dann neu mit 'zuschauer'.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.notifications'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%audience%'
  loop
    execute format('alter table public.notifications drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.notifications add constraint notifications_audience_check
  check (audience in ('alle', 'spieler', 'taskforce', 'gm', 'zuschauer'));

-- ---------------------------------------------------------------------------
-- Meldungen: neue Zielgruppe 'zuschauer'. Zuschauer sehen auch die Meldungen an die Hunter, aber nie den Chat
-- (zuletzt in 0003_engine_tabellen.sql).
create or replace function public.can_see_notification(n public.notifications)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.participants := public.my_participant(n.game_id);
begin
  if v_p.id is null then return false; end if;
  if n.recipient_id is not null then return n.recipient_id = v_p.id; end if;
  if v_p.role = 'zuschauer' then
    return n.kind <> 'chat' and n.audience in ('alle', 'spieler', 'taskforce', 'zuschauer');
  end if;
  return case n.audience
    when 'alle' then true
    when 'spieler' then v_p.role in ('spieler', 'zuschauer', 'gm')
    when 'taskforce' then v_p.role in ('hunter', 'zentrale', 'gm')
    when 'gm' then v_p.role = 'gm'
    else false
  end;
end; $$;

-- ---------------------------------------------------------------------------
-- Joker: Freischalten und Einsetzen als Meldung nur für Zuschauer.
create or replace function public.joker_name(p_type text)
returns text language sql immutable as $$
  select case p_type
    when 'regeneration' then 'Regeneration'
    when 'hunter_erfragen' then 'Hunter-Standorte'
    when 'naehe_radar' then 'Nähe-Radar'
    when 'catch_free' then 'Schutzschild'
    when 'wahl' then 'nach Wahl'
    else replace(coalesce(p_type, ''), '_', ' ')
  end;
$$;

create or replace function public.zuschauer_joker_meldung()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'joker' then return new; end if;
  if tg_op = 'INSERT' then
    perform public.notify(new.game_id, 'zuschauer', null, 'joker', public.pname(new.participant_id) || ' bekommt Joker: ' || public.joker_name(new.type), '', '{}', 'normal');
  elsif old.used_at is null and new.used_at is not null then
    perform public.notify(new.game_id, 'zuschauer', null, 'joker', public.pname(new.participant_id) || ' setzt Joker ein: ' || public.joker_name(new.type),
      case when new.minutes is not null and new.type in ('regeneration', 'naehe_radar', 'catch_free') then 'Wirkt ' || new.minutes || ' min.' else '' end,
      '{}', 'hoch');
  end if;
  return new;
end; $$;

drop trigger if exists zuschauer_joker_meldung on public.inventory_items;
create trigger zuschauer_joker_meldung after insert or update of used_at on public.inventory_items
for each row execute function public.zuschauer_joker_meldung();

-- ---------------------------------------------------------------------------
-- Spielstand für Zuschauer: alles live (zuletzt in 0030_nur_buchstaben.sql).
alter function public.game_state(uuid) rename to game_state_ohne_zuschauer;
revoke execute on function public.game_state_ohne_zuschauer(uuid) from public, anon, authenticated;

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v jsonb;
  g public.games;
  me public.participants;
  v_now timestamptz;
begin
  v := public.game_state_ohne_zuschauer(p_game_id);
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if v is null or me.role is distinct from 'zuschauer' or g.status in ('entwurf', 'geplant', 'lobby') then
    return v;
  end if;
  v_now := public.engine_now(g.id);

  -- Alle Teilnehmenden mit echtem Zustand, Akku, nächstem Ping, wirkenden und vorhandenen Jokern.
  v := jsonb_set(v, '{participants}', coalesce((
    select jsonb_agg(e.value || jsonb_build_object(
      'state', p.state,
      'battery', p.battery,
      'next_ping_at', case when p.role = 'spieler' then p.next_ping_at end,
      'protected', public.has_effect(p.id, 'regeneration', v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('type', a.type, 'ends_at', a.ends_at) order by a.starts_at), '[]')
                  from public.active_effects a
                  where a.participant_id = p.id and a.type <> 'hunter_snapshot' and a.starts_at <= v_now
                    and (a.ends_at is null or a.ends_at > v_now) and not (a.payload ? 'done')),
      'jokers', (select coalesce(jsonb_agg(i.type order by i.granted_at), '[]')
                 from public.inventory_items i where i.participant_id = p.id and i.kind = 'joker' and i.used_at is null and not i.expired)
    ) order by e.ordinality)
    from jsonb_array_elements(v -> 'participants') with ordinality e
    join public.participants p on p.id = (e.value ->> 'id')::uuid
  ), '[]'::jsonb));

  -- Live-Standorte aller Spieler und Hunter (mit Tempo).
  v := jsonb_set(v, '{positions}', (
    select coalesce(jsonb_agg(jsonb_build_object('participant_id', pos.participant_id, 'lat', pos.lat, 'lng', pos.lng, 'accuracy_m', pos.accuracy_m,
      'speed_mps', pos.speed_mps, 'heading', pos.heading, 'at', pos.at, 'live', true)), '[]')
    from public.positions pos join public.participants p on p.id = pos.participant_id
    where pos.game_id = g.id and p.role in ('spieler', 'hunter')));

  -- Alle Pings, sobald die Hunter sie sehen (auch Blitzjagd-Pings).
  v := jsonb_set(v, '{pings}', (
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
      'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
      'stale_seconds', x.stale_seconds, 'is_fake', null, 'truth', null) order by x.at), '[]')
    from (
      select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
      from public.pings pg where pg.game_id = g.id and pg.visible_at <= v_now
    ) x where x.rn <= 200));

  -- Blitzjagden mit Ziel.
  v := jsonb_set(v, '{speedhunts}', (
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty, 'target_id', s.target_id,
      'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
      'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
    from public.speedhunts s
    where s.game_id = g.id and s.started_at is not null and (s.status = 'laeuft' or s.ended_at > v_now - interval '2 hours')));

  v := jsonb_set(v, '{next_silent_ping_at}', coalesce(to_jsonb((
    select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb'))), 'null'::jsonb));

  -- Meldungen: was Spieler und Hunter erfahren, ohne Chat und ohne doppelte (gleiche Meldung an Spieler und an Hunter),
  -- dazu die eigenen Zuschauer-Meldungen. Die alten Joker-Meldungen an die Hunter ersetzen die Zuschauer-Meldungen.
  v := jsonb_set(v, '{notifications}', (
    select coalesce(jsonb_agg(q.x order by q.id desc), '[]') from (
      select n.id, jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
      from public.notifications n
      where n.game_id = g.id and n.recipient_id is null and n.kind <> 'chat'
        and (n.audience in ('alle', 'zuschauer')
          or (n.audience = 'taskforce' and n.kind <> 'joker')
          or (n.audience = 'spieler' and n.kind not in ('game_start', 'exit_reveal', 'speedhunt_start', 'speedhunt_query', 'challenge_announce')))
      order by n.id desc limit 60
    ) q));
  return v;
end; $$;
revoke execute on function public.game_state(uuid) from public, anon;
grant execute on function public.game_state(uuid) to authenticated;

-- Zuschauer sind immer erlaubt: in allen Spielen und Vorlagen einschalten, ohne Verzögerung.
update public.games set config_json = jsonb_set(config_json, '{spectator}',
  coalesce(config_json -> 'spectator', '{}'::jsonb) || '{"enabled": true, "delay_minutes": 0}'::jsonb)
where config_json is not null and jsonb_typeof(config_json) = 'object';
