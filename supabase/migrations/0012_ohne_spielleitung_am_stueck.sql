-- Eigenständiges Spiel ohne Spielleitung, am Stück, mit neuen Begriffen.
-- * Keine Spielleitung mehr: der Host wählt selbst eine Rolle (Spieler, Hunter, Zentrale oder Zuschauer).
-- * Das Spiel läuft am Stück: ein einziger Abschnitt, keine jagdfreien Zeiten, keine Pause.
-- * Challenges, Boni und die Schonzeit nach einer Blitzjagd sind entfernt.
-- * Joker werden pro Eintrag nach einer festen Spielzeit freigeschaltet (joker.types[].after_minutes).
-- * Chat: Spieler schreiben den Huntern (geht an alle Hunter), Hunter schreiben einem Spieler oder allen Spielern,
--   Hunter haben ihren eigenen Kanal. Spieler schreiben nie mit anderen Spielern.
-- * Meldungstexte: Blitzjagd, Ping, Fluchtpunkt, Schutzschild, Hunter.

-- ---------------------------------------------------------------------------
-- 1. Bestehende Spiele anpassen
-- ---------------------------------------------------------------------------

update public.games set preset_id = 'eigenes' where preset_id like 'original\_%';

-- Werte, die es nicht mehr gibt (gilt für alle Spiele, damit sie lesbar bleiben).
update public.games set config_json = jsonb_set(config_json, '{exit,confirm}', '"geofence"')
  where config_json #>> '{exit,confirm}' = 'spielleitung';
update public.games set config_json = jsonb_set(config_json, '{speedhunt,trigger_mode}', '"taskforce"')
  where config_json #>> '{speedhunt,trigger_mode}' = 'gm';

-- Noch nicht gestartete Spiele: am Stück, ohne Spielleitung, ohne Challenges, Boni und Schonzeit.
update public.games set config_json = config_json
  || jsonb_build_object('game', coalesce(config_json -> 'game', '{}'::jsonb) || jsonb_build_object(
       'days', 1,
       'day_length_minutes', least(1440, coalesce((config_json #>> '{game,duration_minutes}')::int, 1440)),
       'quiet_hours', '[]'::jsonb))
  || jsonb_build_object('roles', coalesce(config_json -> 'roles', '{}'::jsonb) || '{"gm_mode": "auto"}'::jsonb)
  || jsonb_build_object('speedhunt', coalesce(config_json -> 'speedhunt', '{}'::jsonb) || '{"gm_approval": false}'::jsonb)
  || jsonb_build_object('safety', coalesce(config_json -> 'safety', '{}'::jsonb) || '{"emergency_pauses": "person"}'::jsonb)
  || jsonb_build_object('taskforce', coalesce(config_json -> 'taskforce', '{}'::jsonb) || '{"daily_briefing": false}'::jsonb)
  || '{"leo": {"enabled": false}, "challenge": {"enabled": false}, "bonus": {"enabled": false}}'::jsonb
where status in ('entwurf', 'geplant', 'lobby');

-- Joker: bisherige "verfügbar ab"-Zeit wird die Freischaltzeit jedes Jokers.
update public.games set config_json = jsonb_set(config_json, '{joker,types}', (
    select coalesce(jsonb_agg(t || jsonb_build_object('after_minutes',
      coalesce(t -> 'after_minutes', to_jsonb(coalesce((config_json #>> '{joker,available_after_minutes}')::int, 0))))), '[]'::jsonb)
    from jsonb_array_elements(config_json #> '{joker,types}') t))
where status in ('entwurf', 'geplant', 'lobby') and jsonb_typeof(config_json #> '{joker,types}') = 'array';

-- ---------------------------------------------------------------------------
-- 2. Rolle "Spielleitung" entfernen
-- ---------------------------------------------------------------------------

update public.participants p set role = 'offen', ready = (p.user_id = g.host_id)
  from public.games g where g.id = p.game_id and p.role = 'gm' and g.status in ('entwurf', 'geplant', 'lobby');
update public.participants set role = 'zuschauer' where role = 'gm';

do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.participants'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%role%gm%'
  loop
    execute format('alter table public.participants drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.participants drop constraint if exists participants_role_check;
alter table public.participants add constraint participants_role_check
  check (role in ('offen', 'spieler', 'hunter', 'zentrale', 'zuschauer'));

-- Der Host ist beim Erstellen noch ohne Rolle und wählt sie in der Lobby selbst.
create or replace function public.create_game(p_name text, p_preset_id text, p_config jsonb, p_start_at timestamptz default null)
returns public.games
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_game public.games;
begin
  perform public.assert_can_play();

  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.games where code = v_code);
  end loop;

  insert into public.games (code, host_id, name, preset_id, config_json, start_at, timezone)
  values (
    v_code,
    auth.uid(),
    p_name,
    p_preset_id,
    coalesce(p_config, '{}'::jsonb),
    p_start_at,
    coalesce(p_config #>> '{game,timezone}', 'Europe/Zurich')
  )
  returning * into v_game;

  insert into public.participants (game_id, user_id, role, ready)
  values (v_game.id, auth.uid(), 'offen', true);

  perform public.log_game_event(v_game.id, 'game_created', jsonb_build_object('preset', p_preset_id));
  return v_game;
end;
$$;

-- Host vergibt Rollen, auch sich selbst. Der Host gilt immer als bereit.
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
  if p_role not in ('offen', 'spieler', 'hunter', 'zentrale', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;

  update public.participants set role = p_role, ready = (v_user = auth.uid()) where id = p_participant_id;
  perform public.log_game_event(v_game_id, 'role_assigned', jsonb_build_object('participant_id', p_participant_id, 'role', p_role));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Chat
--   taskforce   Hunter-Team: nur Hunter und Zentrale
--   spieler     An alle Spieler: Hunter schreiben, Spieler und Hunter lesen
--   sp:<id>     Gespräch eines Spielers mit den Huntern: der Spieler und alle Hunter
-- ---------------------------------------------------------------------------

create or replace function public.can_see_message(m public.messages)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.participants;
begin
  if m.group_id is not null then return public.is_group_member(m.group_id); end if;
  v_p := public.my_participant(m.game_id);
  if v_p.id is null then return false; end if;
  if m.channel = 'taskforce' then return v_p.role in ('hunter', 'zentrale'); end if;
  if m.channel = 'spieler' then return v_p.role in ('spieler', 'hunter', 'zentrale'); end if;
  if m.channel like 'sp:%' then return v_p.role in ('hunter', 'zentrale') or m.channel = 'sp:' || v_p.id::text; end if;
  -- Ältere Kanäle bleiben für die Beteiligten lesbar.
  if m.channel = 'ankuendigung' then return true; end if;
  if m.channel = 'gm:' || v_p.id::text then return true; end if;
  return false;
end; $$;

create or replace function public.send_message(p_game_id uuid, p_channel text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  v_hunter boolean;
  v_target uuid;
  v_body text := trim(p_body);
  v_short text;
begin
  v_me := public.require_participant(p_game_id);
  v_hunter := v_me.role in ('hunter', 'zentrale');
  v_short := case when char_length(v_body) > 120 then left(v_body, 117) || '…' else v_body end;
  if p_channel = 'taskforce' then
    if not v_hunter then raise exception 'Nur für Hunter.' using errcode = '42501'; end if;
  elsif p_channel = 'spieler' then
    if not v_hunter then raise exception 'An alle Spieler schreiben nur die Hunter.' using errcode = '42501'; end if;
  elsif p_channel like 'sp:%' then
    begin
      v_target := substr(p_channel, 4)::uuid;
    exception when others then
      raise exception 'Unbekannter Kanal.' using errcode = 'P0001';
    end;
    if not exists (select 1 from public.participants where id = v_target and game_id = p_game_id and role = 'spieler') then
      raise exception 'Unbekannter Kanal.' using errcode = 'P0001';
    end if;
    if v_me.role = 'spieler' and v_target <> v_me.id then
      raise exception 'Spieler schreiben nie mit anderen Spielern.' using errcode = '42501';
    elsif v_me.role not in ('spieler', 'hunter', 'zentrale') then
      raise exception 'Nur Spieler und Hunter schreiben hier.' using errcode = '42501';
    end if;
  else
    raise exception 'Unbekannter Kanal.' using errcode = 'P0001';
  end if;

  insert into public.messages (game_id, channel, sender_id, sender_name, body, at)
  values (p_game_id, p_channel, auth.uid(), public.pname(v_me.id), v_body, now());

  -- Kurze Meldung an die Empfänger, damit niemand eine Nachricht verpasst.
  if p_channel = 'spieler' then
    perform public.notify(p_game_id, 'spieler', null, 'chat', 'Nachricht der Hunter an alle', v_short, '{}', 'normal');
  elsif p_channel like 'sp:%' and v_me.role = 'spieler' then
    perform public.notify(p_game_id, 'taskforce', null, 'chat', 'Nachricht von ' || public.pname(v_me.id), v_short, '{}', 'normal');
  elsif p_channel like 'sp:%' then
    perform public.notify(p_game_id, null, v_target, 'chat', 'Nachricht von ' || public.pname(v_me.id) || ' (Hunter)', v_short, '{}', 'normal');
  end if;
end; $$;

-- ---------------------------------------------------------------------------
-- 4. Joker: jeder Eintrag wird nach seiner Spielzeit einmal an alle Spieler vergeben
-- ---------------------------------------------------------------------------

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
          when 'regeneration' then 'Du wirst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gepingt. Einsetzen unter Aktionen.'
          when 'hunter_erfragen' then 'Zeigt dir 5 min lang, wo die Hunter sind. Einsetzen unter Aktionen.'
          when 'catch_free' then 'Du kannst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gefangen werden. Einsetzen unter Aktionen.'
          else '' end, '{}', 'hoch');
    end loop;
  end loop;
end; $$;

revoke all on function public.grant_jokers(public.games, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Funktionen der Spielleitung, Pause und Challenges abschalten
-- ---------------------------------------------------------------------------

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             'pause_game', 'resume_game', 'speedhunt_approve', 'gm_catch_decide', 'gm_grant_item', 'gm_ping', 'gm_add_zone',
             'gm_set_state', 'gm_update_config', 'violation_decide', 'violation_report', 'briefing_confirm',
             'challenge_create', 'challenge_cancel', 'challenge_join', 'challenge_submit', 'challenge_decide'])
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Meldungstexte mit den neuen Begriffen (Funktionen unverändert übernommen, nur Texte neu)
-- ---------------------------------------------------------------------------

-- save_map (zuletzt in 0002_karte_gruppen.sql)
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
  for f in select * from jsonb_array_elements(coalesce(p_features, '[]'::jsonb)) loop
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
  perform public.log_game_event(p_game_id, 'map_saved', jsonb_build_object('zones', n));
  return n;
end; $$;

-- start_speedhunt_internal (zuletzt in 0004_engine_logik.sql)
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
          case when p_status = 'laeuft' then p_now + make_interval(mins => public.cfg_int(v_cfg, 'speedhunt', 'max_duration_minutes', 90)) end)
  returning * into v_sh;

  if p_status = 'laeuft' then
    update public.games set last_speedhunt_target = p_target where id = p_game.id;
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_start', 'SPEEDHUNT!',
      v_text || ' Einer von euch wird gejagt.', jsonb_build_object('speedhunt_id', v_sh.id), 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_start',
      case when p_is_penalty then 'Straf-Blitzjagd: ' else 'Blitzjagd: ' end || public.pname(p_target),
      v_queries - v_used || ' Abfragen, max. ' || public.cfg_int(v_cfg, 'speedhunt', 'max_duration_minutes', 90) || ' min',
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

-- end_speedhunt (zuletzt in 0004_engine_logik.sql)
create or replace function public.end_speedhunt(p_game public.games, p_sh public.speedhunts, p_reason text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_leo_end timestamptz;
begin
  update public.speedhunts set status = 'beendet', ended_at = p_now, end_reason = p_reason where id = p_sh.id;
  if p_sh.status <> 'laeuft' then return; end if;
  perform public.notify(p_game.id, 'alle', null, 'speedhunt_end', 'Blitzjagd beendet', '',
    jsonb_build_object('speedhunt_id', p_sh.id, 'reason', p_reason), 'normal');
  if p_reason <> 'gefangen' and public.cfg_bool(v_cfg, 'leo', 'enabled', false) then
    if public.cfg_text(v_cfg, 'leo', 'mode', 'bis_ende_naechste_volle_stunde') = 'feste_dauer' then
      v_leo_end := p_now + make_interval(mins => public.cfg_int(v_cfg, 'leo', 'duration_minutes', 60));
    else
      -- Ende der nächsten vollen Stunde: 14:20 -> 16:00 (Akzeptanztest 6).
      v_leo_end := date_trunc('hour', p_now) + interval '2 hours';
    end if;
    insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at)
    values (p_game.id, p_sh.target_id, 'leo', p_now, v_leo_end);
  end if;
end; $$;

-- finish_game (zuletzt in 0004_engine_logik.sql)
create or replace function public.finish_game(p_game public.games, p_now timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_exit boolean := public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender';
  v_missed text := public.cfg_text(v_cfg, 'exit', 'missed_policy', 'verloren');
  v_mode text := public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden');
  v_winners jsonb;
  v_scores jsonb;
  v_hours double precision;
  v_sh public.speedhunts;
  v_names text;
begin
  if p_game.status = 'beendet' then return; end if;
  for v_sh in select * from public.speedhunts where game_id = p_game.id and status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') loop
    perform public.end_speedhunt(p_game, v_sh, 'spielende', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);
  update public.active_effects set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);

  select coalesce(jsonb_agg(id), '[]') into v_winners from public.participants
  where game_id = p_game.id and role = 'spieler' and (
    state = 'im_ziel'
    or (state in ('aktiv', 'ausserhalb', 'notfall') and (not v_exit or v_missed = 'gewonnen_ohne_exit'))
  );

  -- Punkte (win.mode = punkte): Spieler 10 pro überlebte Stunde, 50 für den Exit, 20 pro Challenge; Hunter Kopfgeld.
  select coalesce(jsonb_object_agg(p.id, case
      when p.role = 'spieler' then
        round(10 * extract(epoch from (coalesce(p.caught_at, p.finished_at, p_now) - p_game.hunt_start_at)) / 3600.0)
        + case when p.state = 'im_ziel' then 50 else 0 end
        + 20 * (select count(*) from public.challenge_entries e where e.participant_id = p.id and e.result = 'erfolgreich')
      else p.bounty end), '{}')
    into v_scores
  from public.participants p where p.game_id = p_game.id and p.role in ('spieler', 'hunter', 'zentrale');

  v_hours := extract(epoch from (p_now - p_game.hunt_start_at)) / 3600.0;
  update public.games set status = 'beendet', ended_at = p_now, result_json = jsonb_build_object(
    'reason', p_reason,
    'winners', v_winners,
    'mode', v_mode,
    'scores', v_scores,
    'hours', round(v_hours::numeric, 2),
    'catches', (select count(*) from public.catches where game_id = p_game.id and status = 'gueltig'),
    'pings', (select count(*) from public.pings where game_id = p_game.id),
    'speedhunts', (select count(*) from public.speedhunts where game_id = p_game.id and started_at is not null)
  ) where id = p_game.id;
  update public.participants set state = 'verloren' where game_id = p_game.id and role = 'spieler'
    and state in ('aktiv', 'ausserhalb', 'notfall') and not (v_winners ? id::text);

  select string_agg(public.pname(w::uuid), ', ') into v_names from jsonb_array_elements_text(v_winners) w;
  perform public.notify(p_game.id, 'alle', null, 'game_end', 'Spielende!',
    case when v_names is null then 'Keine Sieger: die Hunter haben gewonnen.' else 'Sieger: ' || v_names end,
    jsonb_build_object('reason', p_reason), 'hoch');
  perform public.log_game_event(p_game.id, 'game_ended', jsonb_build_object('reason', p_reason));
end; $$;

-- apply_penalty (zuletzt in 0004_engine_logik.sql)
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
    when 'straf_speedhunt' then
      if v_p.role <> 'spieler' then
        perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Verwarnung', replace(v.type, '_', ' '), '{}', 'hoch');
      elsif public.has_effect(v.participant_id, 'regeneration', p_now) then
        -- Straf-Blitzjagds werden bis zum Ende des Regenerations-Jokers aufgeschoben (14.3, Regel 3).
        perform public.start_speedhunt_internal(p_game, v.participant_id, null, true, p_now, 'aufgeschoben');
      else
        perform public.start_speedhunt_internal(p_game, v.participant_id, null, true, p_now);
      end if;
      perform public.notify(p_game.id, 'gm', null, 'penalty', 'Straf-Blitzjagd: ' || public.pname(v.participant_id), replace(v.type, '_', ' '), '{}', 'normal');
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
    when 'live_standort' then
      perform public.open_live_window(p_game.id, v.participant_id, 'strafe', p_now, p_now + interval '15 minutes');
    else
      null;
  end case;
end; $$;

-- day_reset (zuletzt in 0008_zonen_phasen.sql)
create or replace function public.day_reset(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_day int := p_game.current_day + 1;
  v_days int := public.cfg_int(v_cfg, 'game', 'days', 4);
  v_next timestamptz;
  v_grace int := public.cfg_int(v_cfg, 'zone', 'shrink_grace_minutes', 0);
  v_left int;
  v_changed boolean;
begin
  -- 1. Abschnitt-Zähler (das Spiel hat nur noch einen Abschnitt: am Stück)
  v_next := case when v_day < v_days then public.day_start(p_game, v_day + 1) end;
  if v_next is not null and v_next >= p_game.ends_at then v_next := null; end if;
  v_left := public.speedhunt_quota(v_cfg, v_day)
    + case when public.cfg_bool(v_cfg, 'speedhunt', 'carry_over', false) then p_game.speedhunts_left else 0 end;
  update public.games set current_day = v_day, next_day_at = v_next, speedhunts_left = v_left where id = p_game.id
  returning * into p_game;

  -- 2. Neues Spielfeld
  v_changed := public.shrink_every_minutes(v_cfg) = 0 and exists (select 1 from public.zones where game_id = p_game.id and kind = 'spielfeld' and day_index = v_day);
  if v_changed then
    if v_grace > 0 then
      update public.participants set grace_until = p_now + make_interval(mins => v_grace) where game_id = p_game.id and role = 'spieler';
    end if;
    perform public.recheck_zones(p_game, p_now);
    perform public.notify(p_game.id, 'alle', null, 'zone_active', 'Das Spielfeld hat sich geändert', 'Neue Grenzen gelten jetzt.', '{}', 'hoch');
    update public.games set map_version = map_version + 1 where id = p_game.id;
  end if;

  -- 3. Budget
  if public.cfg_bool(v_cfg, 'budget', 'enabled', false) then
    update public.participants set budget_balance = case when public.cfg_bool(v_cfg, 'budget', 'allow_saving', false)
      then budget_balance + public.cfg_int(v_cfg, 'budget', 'daily_amount', 30) else public.cfg_int(v_cfg, 'budget', 'daily_amount', 30) end
    where game_id = p_game.id and role = 'spieler';
  end if;

  -- 4. Joker
  perform public.grant_jokers(p_game, p_now);

  -- 5. Boni verfallen
  if public.cfg_bool(v_cfg, 'bonus', 'expire_at_day_reset', true) then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'bonus' and used_at is null and not expired;
    update public.active_effects set ends_at = p_now, payload = payload || '{"done": true}'
      where game_id = p_game.id and type = 'fake_ping' and (ends_at is null or ends_at > p_now);
  end if;

  -- 6. ÖV-Nachlauf und Fähren-Zähler zurücksetzen; Ausserhalb-Zeit pro Tag
  update public.participants set rides_today = 0, ferry_stops_today = 0,
    out_accum_s = case when public.cfg_text(v_cfg, 'out_of_bounds', 'count_mode', 'pro_ausflug') = 'pro_tag' then 0 else out_accum_s end
  where game_id = p_game.id;

  -- 7. Speedhunt-Kontingent (oben gesetzt), Zufalls-Speedhunts planen
  perform public.schedule_random_speedhunts(p_game, p_now);

  -- 9. Mitteilung
  if v_day > 1 then
    perform public.notify(p_game.id, 'alle', null, 'day_reset', 'Neuer Abschnitt: ' || v_day || ' von ' || v_days,
      case when public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then 'Blitzjagden übrig: ' || v_left else '' end, '{}', 'hoch');
  end if;
  if public.cfg_bool(v_cfg, 'taskforce', 'daily_briefing', false) then
    perform public.notify(p_game.id, 'taskforce', null, 'briefing', 'Einsatzbesprechung', 'Bitte trefft euch und bestätigt das Briefing.', '{}', 'normal');
  end if;
  perform public.log_game_event(p_game.id, 'day_reset', jsonb_build_object('day', v_day));
  return p_game;
end; $$;

-- hunt_begin (zuletzt in 0004_engine_logik.sql)
create or replace function public.hunt_begin(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_p public.participants;
begin
  update public.games set status = 'laeuft', current_day = 0 where id = p_game.id returning * into p_game;
  if public.cfg_bool(v_cfg, 'budget', 'enabled', false) then
    update public.participants set budget_balance = public.cfg_int(v_cfg, 'budget', 'start_amount', 30)
    where game_id = p_game.id and role = 'spieler';
  end if;
  p_game := public.day_reset(p_game, p_now);
  -- Budget am ersten Tag: Startbetrag statt Tagesbetrag
  if public.cfg_bool(v_cfg, 'budget', 'enabled', false) then
    update public.participants set budget_balance = public.cfg_int(v_cfg, 'budget', 'start_amount', 30)
    where game_id = p_game.id and role = 'spieler';
  end if;
  for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state = 'aktiv' loop
    perform public.schedule_next_ping(p_game, v_p.id,
      p_game.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'ping', 'first_ping_delay_minutes', 0)));
  end loop;
  perform public.notify(p_game.id, 'alle', null, 'hunt_begin', 'Die Jagd beginnt!', 'Die Hunter sind unterwegs.', '{}', 'hoch');
  perform public.log_game_event(p_game.id, 'hunt_begin');
  return p_game;
end; $$;

-- check_player_zone (zuletzt in 0009_notfall_joker_chat.sql)
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
begin
  v_area := public.allowed_area(p_game.id, p_p.id, p_game.current_day, public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false));
  v_inside := v_area is null or ST_DWithin(v_area::geography, p_point::geography, v_tol);

  -- Sperrzonen (22.3)
  select * into v_restricted from public.zones where game_id = p_game.id and kind = 'sperrzone' and ST_Covers(geom, p_point) limit 1;
  if v_restricted.id is not null then
    if public.cfg_bool(v_cfg, 'zone', 'restricted_counts_as_outside', false) then v_inside := false; end if;
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false where id = p_p.id;
      perform public.notify(p_game.id, null, p_p.id, 'restricted', 'Sperrzone! Sofort verlassen', coalesce(nullif(v_restricted.name, ''), 'Sperrzone'), '{}', 'kritisch');
      p_p.restricted_since := p_now;
      p_p.restricted_violated := false;
    end if;
    if not p_p.restricted_violated and (not v_restricted.crossing_allowed or p_now - p_p.restricted_since > make_interval(secs => v_cross)) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'sperrzone',
        jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
  elsif p_p.restricted_zone_id is not null then
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
    update public.participants set out_pending_since = p_now where id = p_p.id;
    if v_grace > 0 then
      perform public.notify(p_game.id, null, p_p.id, 'outside_warning', 'Achtung: Spielfeldgrenze',
        'Du bist am Rand oder ausserhalb. Geh zurück.', '{}', 'hoch');
      return;
    end if;
    p_p.out_pending_since := p_now;
  end if;
  if p_now - p_p.out_pending_since >= make_interval(secs => v_grace) then
    update public.participants set state = 'ausserhalb' where id = p_p.id;
    -- Immer live an die Hunter, solange die Person ausserhalb ist.
    perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
    perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb!',
      greatest(0, v_max - p_p.out_accum_s / 60) || ' min bis ' ||
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'disqualify')
        when 'catch' then 'zum Fang' when 'disqualify' then 'zur Disqualifikation' else 'zur Strafe' end || '. Die Hunter sehen dich live.',
      '{}', 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
    perform public.notify(p_game.id, 'gm', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', '', '{}', 'normal');
  end if;
end; $$;

-- check_proximity (zuletzt in 0004_engine_logik.sql)
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
        perform public.notify(p_game.id, 'taskforce', null, 'proximity', 'Teambildungs-Alarm',
          public.pname(v_pair.a_id) || ' und ' || public.pname(v_pair.b_id) || ' sind unter ' || v_dist || ' m.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_self', 'Teambildung: ' || public.pname(v_pair.b_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'name', public.pname(v_pair.b_id)), 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Teambildung: ' || public.pname(v_pair.a_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'name', public.pname(v_pair.a_id)), 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.alerted then
      update public.proximity_pairs set alerted = false where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;

-- reach_exit (zuletzt in 0004_engine_logik.sql)
create or replace function public.reach_exit(p_game public.games, p_participant uuid, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare v_sh public.speedhunts;
begin
  update public.participants set state = 'im_ziel', finished_at = p_now, next_ping_at = null where id = p_participant and state in ('aktiv', 'ausserhalb');
  if not found then return; end if;
  for v_sh in select * from public.speedhunts where target_id = p_participant and status = 'laeuft' loop
    perform public.end_speedhunt(p_game, v_sh, 'im_ziel', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where participant_id = p_participant and (ends_at is null or ends_at > p_now);
  perform public.notify(p_game.id, null, p_participant, 'exit_reached', 'Geschafft!', 'Du bist am Fluchtpunkt und in Sicherheit.', '{}', 'hoch');
  perform public.notify(p_game.id, 'alle', null, 'exit_reached', public.pname(p_participant) || ' hat den Fluchtpunkt erreicht', '', '{}', 'normal');
  if public.free_players(p_game.id) = 0 then
    select * into p_game from public.games where id = p_game.id;
    perform public.finish_game(p_game, p_now, 'alle_im_ziel_oder_gefangen');
  end if;
end; $$;

-- tick_game (zuletzt in 0009_notfall_joker_chat.sql)
create or replace function public.tick_game(p_game_id uuid)
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
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'disqualify')
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

  -- Teambildung (alle 30 s)
  if coalesce((g.state_json ->> 'last_proximity')::timestamptz, '-infinity') <= v_now - interval '30 seconds' then
    perform public.check_proximity(g, v_now);
    update public.games set state_json = state_json || jsonb_build_object('last_proximity', v_now) where id = g.id returning * into g;
  end if;

  -- Fluchtpunkt bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now and g.exit_zone_id is not null then
    update public.zones set visible_from = v_now,
      visible_to = case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end
    where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1,
      state_json = state_json || jsonb_build_object('exit_taskforce_at', case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig')
        when 'verzoegert' then to_jsonb(v_now + interval '15 minutes') else null end)
    where id = g.id returning * into g;
    perform public.notify(g.id, case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end,
      null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
    if public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') <> 'gleichzeitig' then
      perform public.notify(g.id, 'gm', null, 'exit_reveal', 'Fluchtpunkt an Spieler bekanntgegeben', '', '{}', 'normal');
    end if;
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
  end if;
  if g.state_json ? 'exit_taskforce_at' and jsonb_typeof(g.state_json -> 'exit_taskforce_at') = 'string'
     and (g.state_json ->> 'exit_taskforce_at')::timestamptz <= v_now then
    update public.zones set visible_to = 'alle' where id = g.exit_zone_id;
    update public.games set state_json = state_json - 'exit_taskforce_at', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Fluchtpunkt bekannt', 'Siehe Karte.', '{}', 'kritisch');
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

-- start_game (zuletzt in 0008_zonen_phasen.sql)
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
  select count(*) filter (where role = 'spieler'), count(*) filter (where role in ('hunter', 'zentrale')), count(*) filter (where role = 'offen')
    into v_players, v_hunters, v_open from public.participants where game_id = p_game_id;
  if v_open > 0 then raise exception 'Noch % Person(en) ohne Rolle.', v_open using errcode = 'P0001'; end if;
  if v_players < 1 then raise exception 'Mindestens 1 Spieler nötig.' using errcode = 'P0001'; end if;
  if v_hunters < 1 then raise exception 'Mindestens 1 Hunter nötig.' using errcode = 'P0001'; end if;
  if v_players > public.cfg_int(v_cfg, 'roles', 'players_max', 9) then raise exception 'Zu viele Spieler für die Regeln.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind in ('spielfeld', 'sektion')) then
    raise exception 'Zeichne zuerst ein Spielfeld auf der Karte.' using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
     and not exists (select 1 from public.zones where game_id = p_game_id and kind = 'exit') then
    raise exception 'Setze mindestens einen Fluchtpunkt-Kandidaten auf der Karte (oder schalte den Fluchtpunkt aus).' using errcode = 'P0001';
  end if;

  -- Kartenprüfungen (22.4)
  if exists (
    select 1 from public.zones t
    where t.game_id = p_game_id and t.kind = 'treffpunkt'
      and public.spielfeld_day(p_game_id, 1) is not null
      and not ST_DWithin(public.spielfeld_day(p_game_id, 1)::geography, t.geom::geography, 25)
  ) then
    raise exception 'Der Treffpunkt liegt ausserhalb des Spielfelds.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.zones p join public.zones s on s.game_id = p.game_id and s.kind = 'sperrzone'
    where p.game_id = p_game_id and p.kind in ('treffpunkt', 'exit', 'hq') and ST_Intersects(s.geom, p.geom)
  ) then
    raise exception 'Treffpunkt, HQ oder ein Fluchtpunkt liegt in einer Sperrzone.' using errcode = 'P0001';
  end if;

  -- Fluchtpunkt auswählen (zufällig oder der erste Kandidat)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    select id into v_exit from public.zones where game_id = p_game_id and kind = 'exit'
    order by case when public.cfg_bool(v_cfg, 'exit', 'random_from_candidates', true) then random() else 0 end, created_at limit 1;
    -- Nicht gewählte Kandidaten bleiben für immer verborgen.
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit' and id <> v_exit;
    update public.zones set visible_to = 'gm' where id = v_exit;
  end if;

  -- Automatische Verkleinerung: Spielfeld je Tag um x % (Fläche) um den Exit bzw. Mittelpunkt (7.1).
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
      + case when v_exit is not null then public.cfg_int(v_cfg, 'exit', 'arrival_deadline_offset_minutes', 15) else 0 end),
    exit_reveal_at = case when v_exit is not null then g.hunt_start_at
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
    'Bleibt im HQ. Die Jagd beginnt um ' || to_char(g.hunt_start_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'game_started', jsonb_build_object('test', p_test));
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;

-- advance_time (zuletzt in 0005_aktionen.sql)
create or replace function public.advance_time(p_game_id uuid, p_minutes int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_step int;
  v_left int := p_minutes;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if not g.is_test then raise exception 'Vorspulen geht nur im Probelauf.' using errcode = 'P0001'; end if;
  if p_minutes < 1 or p_minutes > 1440 then raise exception 'Zwischen 1 und 1440 Minuten.' using errcode = 'P0001'; end if;
  -- In Schritten ticken, damit Timer in der richtigen Reihenfolge feuern.
  while v_left > 0 loop
    v_step := least(v_left, 5);
    update public.games set clock_offset = clock_offset + make_interval(mins => v_step) where id = p_game_id;
    -- Geräte gelten im Probelauf als durchgehend gemeldet: letzte Positionen mitverschieben.
    update public.positions set at = at + make_interval(mins => v_step) where game_id = p_game_id;
    update public.participants set last_seen_at = last_seen_at + make_interval(mins => v_step) where game_id = p_game_id;
    perform public.tick_game(p_game_id);
    v_left := v_left - v_step;
  end loop;
  return public.engine_now(p_game_id);
end; $$;

-- speedhunt_start (zuletzt in 0005_aktionen.sql)
create or replace function public.speedhunt_start(p_game_id uuid, p_target uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_t public.participants;
  v_sh public.speedhunts;
  v_free int;
  v_min_after int;
  v_mode text;
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(p_game_id);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  v_mode := public.cfg_text(v_cfg, 'speedhunt', 'trigger_mode', 'taskforce');
  if not public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then raise exception 'Blitzjagden sind ausgeschaltet.' using errcode = 'P0001'; end if;
  if v_mode = 'random' then raise exception 'Blitzjagden starten in diesem Spiel zufällig.' using errcode = 'P0001'; end if;
  if v_mode = 'gm' and v_me.role <> 'gm' then raise exception 'Blitzjagden starten in diesem Spiel zufällig.' using errcode = '42501'; end if;
  if public.in_quiet_hours(g, v_now) then raise exception 'Jagdfreie Zeit.' using errcode = 'P0001'; end if;
  if g.speedhunts_left <= 0 then raise exception 'Keine Blitzjagd mehr übrig.' using errcode = 'P0001'; end if;
  if (select count(*) from public.speedhunts where game_id = p_game_id and status = 'laeuft' and not is_penalty)
     >= public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) then
    raise exception 'Schon % Blitzjagden gleichzeitig.', public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) using errcode = 'P0001';
  end if;
  select * into v_t from public.participants where id = p_target and game_id = p_game_id;
  if v_t.id is null or v_t.role <> 'spieler' or v_t.state not in ('aktiv', 'ausserhalb') then
    raise exception 'Dieses Ziel kann nicht gejagt werden.' using errcode = 'P0001';
  end if;
  if (public.running_speedhunt_on(p_target)).id is not null then raise exception 'Auf dieses Ziel läuft schon eine Blitzjagd.' using errcode = 'P0001'; end if;
  -- Regenerations-Joker und Hotel schützen vor neuen Speedhunts (7.11, 7.12).
  if public.has_effect(p_target, 'regeneration', v_now) then raise exception 'Ziel ist durch einen Joker geschützt.' using errcode = 'P0001'; end if;
  if public.has_effect(p_target, 'hotel', v_now) then raise exception 'Ziel ist im Hotel geschützt.' using errcode = 'P0001'; end if;
  v_free := public.free_players(p_game_id);
  if public.cfg_bool(v_cfg, 'speedhunt', 'no_consecutive_same_target', true) and g.last_speedhunt_target = p_target
     and v_free > public.cfg_int(v_cfg, 'speedhunt', 'consecutive_allowed_when_players_left_le', 2) then
    raise exception 'Nicht zweimal hintereinander dasselbe Ziel.' using errcode = 'P0001';
  end if;
  if public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) > 0
     and (select count(*) from public.speedhunts where target_id = p_target and day_index = g.current_day and not is_penalty and started_at is not null)
       >= public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) then
    raise exception 'Dieses Ziel hatte schon genug Blitzjagden.' using errcode = 'P0001';
  end if;
  v_min_after := public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0);
  if v_min_after > 0 and public.cfg_text(v_cfg, 'speedhunt', 'early_start_policy', 'silent_zaehlt_als_abfrage') = 'verbieten'
     and v_t.last_silent_ping_at > v_now - make_interval(mins => v_min_after) then
    raise exception 'Erst % min nach dem letzten Ping möglich.', v_min_after using errcode = 'P0001';
  end if;

  update public.games set speedhunts_left = speedhunts_left - 1 where id = p_game_id;
  if public.cfg_bool(v_cfg, 'speedhunt', 'gm_approval', false) and v_me.role <> 'gm' then
    v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now, 'wartet_auf_freigabe');
    perform public.notify(p_game_id, 'gm', null, 'speedhunt_approval', 'Blitzjagd freigeben?', public.pname(p_target), jsonb_build_object('speedhunt_id', v_sh.id), 'hoch');
  else
    v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now);
  end if;
  perform public.log_game_event(p_game_id, 'speedhunt_start', jsonb_build_object('target', p_target, 'by', v_me.id));
  perform public.bump(p_game_id);
  return v_sh.id;
end; $$;

-- speedhunt_query (zuletzt in 0005_aktionen.sql)
create or replace function public.speedhunt_query(p_speedhunt_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_sh public.speedhunts;
  g public.games;
  v_now timestamptz;
  v_gap int;
  v_id uuid;
begin
  select * into v_sh from public.speedhunts where id = p_speedhunt_id for update;
  if v_sh.id is null then raise exception 'Blitzjagd nicht gefunden.' using errcode = 'P0001'; end if;
  perform public.require_participant(v_sh.game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(v_sh.game_id);
  v_now := public.engine_now(g.id);
  if v_sh.status <> 'laeuft' then raise exception 'Die Blitzjagd läuft nicht.' using errcode = 'P0001'; end if;
  v_gap := public.cfg_int(g.config_json, 'speedhunt', 'query_min_gap_minutes', 0);
  if v_gap > 0 and v_sh.last_query_at > v_now - make_interval(mins => v_gap) then
    raise exception 'Nächste Abfrage erst um %.', to_char((v_sh.last_query_at + make_interval(mins => v_gap)) at time zone g.timezone, 'HH24:MI') using errcode = 'P0001';
  end if;
  v_id := public.speedhunt_query_internal(g, v_sh, v_now);
  perform public.bump(g.id);
  return v_id;
end; $$;

-- catch_blocked_reason (zuletzt in 0005_aktionen.sql)
create or replace function public.catch_blocked_reason(g public.games, p_runner public.participants, p_now timestamptz)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare v_pos public.positions;
begin
  if g.status = 'vorsprung' then return 'Während des Vorsprungs darf nicht gefangen werden.'; end if;
  if p_runner.state not in ('aktiv', 'ausserhalb') then return 'Diese Person ist nicht mehr im Spiel.'; end if;
  if public.in_quiet_hours(g, p_now) then return 'Jagdfreie Zeit.'; end if;
  if public.has_effect(p_runner.id, 'catch_free', p_now) then return 'Schutzschild aktiv: kein Fang möglich.'; end if;
  if public.has_effect(p_runner.id, 'hotel', p_now) then return 'Spieler ist im Hotel geschützt.'; end if;
  select * into v_pos from public.positions where participant_id = p_runner.id;
  if v_pos.participant_id is not null and exists (select 1 from public.zones where game_id = g.id and kind = 'sicher' and ST_Covers(geom, v_pos.geom)) then
    return 'Spieler ist in einer sicheren Zone.';
  end if;
  return null;
end; $$;

-- catch_respond (zuletzt in 0005_aktionen.sql)
create or replace function public.catch_respond(p_catch_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.catches;
  v_me public.participants;
  g public.games;
begin
  select * into v_c from public.catches where id = p_catch_id;
  v_me := public.require_participant(v_c.game_id);
  g := public.require_running(v_c.game_id, true);
  if v_c.status <> 'wartet_auf_bestaetigung' then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  if v_me.id = v_c.runner_id then
    if p_accept then perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
    else
      update public.catches set expires_at = null where id = v_c.id;
      perform public.notify(g.id, 'gm', null, 'catch_disputed', 'Fang bestritten', public.pname(v_c.runner_id) || ' bestreitet den Fang durch ' || public.pname(v_c.hunter_id) || '.', jsonb_build_object('catch_id', v_c.id), 'hoch');
      perform public.notify(g.id, null, v_c.hunter_id, 'catch_disputed', 'Fang bestritten', 'Die App entscheidet.', '{}', 'hoch');
      if public.cfg_text(g.config_json, 'roles', 'gm_mode', 'auto') = 'auto' then
        -- Der GPS-Abstand entscheidet sofort.
        update public.catches set expires_at = public.engine_now(g.id) where id = v_c.id;
        perform public.tick_game(g.id);
      end if;
    end if;
  elsif v_me.role = 'gm' then
    if p_accept then perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
    else update public.catches set status = 'abgelehnt', reason = 'Spielleitung' where id = v_c.id; end if;
  else
    raise exception 'Nur die gefangene Person.' using errcode = '42501';
  end if;
  perform public.bump(g.id);
end; $$;

-- confirm_exit (zuletzt in 0005_aktionen.sql)
create or replace function public.confirm_exit(p_game_id uuid, p_participant uuid default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.participants;
  g public.games;
  v_exit public.zones;
  v_pos public.positions;
begin
  v_me := public.require_participant(p_game_id);
  g := public.require_running(p_game_id);
  if not g.exit_revealed then raise exception 'Der Fluchtpunkt ist noch nicht bekannt.' using errcode = 'P0001'; end if;
  if v_me.role = 'gm' and p_participant is not null then
    perform public.reach_exit(g, p_participant, public.engine_now(p_game_id));
  elsif v_me.role = 'spieler' then
    select * into v_exit from public.zones where id = g.exit_zone_id;
    select * into v_pos from public.positions where participant_id = v_me.id;
    if v_pos.participant_id is null or public.dist_m(v_exit.geom, v_pos.geom) > coalesce(v_exit.radius_m, 30) + coalesce(v_pos.accuracy_m, 0) + 20 then
      raise exception 'Du bist noch nicht am Fluchtpunkt.' using errcode = 'P0001';
    end if;
    perform public.reach_exit(g, v_me.id, public.engine_now(p_game_id));
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
  perform public.bump(p_game_id);
end; $$;

-- use_item (zuletzt in 0005_aktionen.sql)
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
      where p.game_id = g.id and p.role in ('hunter', 'zentrale');
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
      values (g.id, v_me.id, 'hunter_snapshot', v_now, v_now + interval '5 minutes', jsonb_build_object('hunters', v_snapshot), v_i.id);
      perform public.notify(g.id, null, v_me.id, 'joker', 'Hunter-Standorte', 'Auf der Karte 5 min sichtbar.', jsonb_build_object('hunters', v_snapshot), 'hoch');
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

-- emergency_start (zuletzt in 0009_notfall_joker_chat.sql)
create or replace function public.emergency_start(p_game_id uuid, p_lat double precision default null, p_lng double precision default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_id uuid;
  v_now timestamptz;
  v_pos public.positions;
begin
  v_me := public.require_participant(p_game_id);
  select * into g from public.games where id = p_game_id;
  v_now := public.engine_now(p_game_id);
  select * into v_pos from public.positions where participant_id = v_me.id;
  insert into public.emergencies (game_id, participant_id, at, lat, lng) values (p_game_id, v_me.id, v_now, coalesce(p_lat, v_pos.lat), coalesce(p_lng, v_pos.lng))
  returning id into v_id;
  if v_me.state in ('aktiv', 'ausserhalb') then
    update public.participants set state_before = state, state = 'notfall' where id = v_me.id;
  end if;
  perform public.open_live_window(p_game_id, v_me.id, 'notfall', v_now, null);
  perform public.notify(p_game_id, 'gm', null, 'emergency', 'NOTFALL: ' || public.pname(v_me.id), 'Standort auf der Karte. Notfallkontakt in der Teilnehmerliste.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  perform public.notify(p_game_id, 'taskforce', null, 'emergency', 'NOTFALL: ' || public.pname(v_me.id), 'Jagd auf diese Person ist ausgesetzt. Standort und Notfallkontakt in der App. Bitte helft sofort, wenn ihr in der Nähe seid.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  if public.cfg_text(g.config_json, 'safety', 'emergency_pauses', 'person') = 'alle' and g.status in ('vorsprung', 'laeuft', 'finale') then
    perform public.pause_internal(p_game_id, 'Notfall: ' || public.pname(v_me.id));
  end if;
  perform public.notify(p_game_id, null, v_me.id, 'emergency_self', 'Notfall gemeldet',
    'Alle Hunter' || case when exists (select 1 from public.participants where game_id = p_game_id and role = 'gm') then '' else '' end
    || ' sind alarmiert. Bei Gefahr: Polizei 117, Sanität 144, Notruf 112.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  perform public.log_game_event(p_game_id, 'emergency', jsonb_build_object('participant', v_me.id));
  perform public.bump(p_game_id);
  return v_id;
end; $$;

-- emergency_resolve (zuletzt in 0009_notfall_joker_chat.sql)
create or replace function public.emergency_resolve(p_emergency_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_e public.emergencies;
  v_me public.participants;
  v_p public.participants;
  g public.games;
  v_now timestamptz;
begin
  select * into v_e from public.emergencies where id = p_emergency_id;
  v_me := public.require_participant(v_e.game_id);
  select * into g from public.games where id = v_e.game_id;
  if not (v_me.role = 'gm' or public.is_game_host(g.id)
          or v_me.id = v_e.participant_id) then
    raise exception 'Nur die Person selbst oder wer das Spiel erstellt hat, kann den Notfall beenden.' using errcode = '42501';
  end if;
  v_now := public.engine_now(g.id);
  update public.emergencies set status = 'erledigt', resolved_by = auth.uid(), resolved_at = v_now where id = v_e.id;
  select * into v_p from public.participants where id = v_e.participant_id;
  if v_p.state = 'notfall' then
    update public.participants set state = coalesce(state_before, 'aktiv'), state_before = null where id = v_p.id;
  end if;
  perform public.close_live_windows(v_p.id, 'notfall', v_now);
  perform public.notify(g.id, 'alle', null, 'emergency_end',
    case when v_me.id = v_e.participant_id then 'Notfall abgebrochen' else 'Notfall erledigt' end,
    public.pname(v_p.id) || case when v_me.id = v_e.participant_id then ': alles in Ordnung (Fehlalarm oder erledigt).' else '' end, '{}', 'hoch');
  perform public.bump(g.id);
end; $$;

-- emergency_contact (zuletzt in 0009_notfall_joker_chat.sql)
create or replace function public.emergency_contact(p_game_id uuid, p_participant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  -- Nur bei einem offenen Notfall dieser Person: alle Hunter und wer das Spiel erstellt hat.
  if not ((public.is_game_host(p_game_id)
           or exists (select 1 from public.participants where game_id = p_game_id and user_id = auth.uid() and role in ('hunter', 'zentrale')))
          and exists (select 1 from public.emergencies where game_id = p_game_id and participant_id = p_participant and status = 'offen')) then
    raise exception 'Nur Hunter bei einem offenen Notfall.' using errcode = '42501';
  end if;
  select jsonb_build_object('name', pp.emergency_contact_name, 'phone', pp.emergency_contact_phone) into v
  from public.participants p join public.profile_private pp on pp.user_id = p.user_id where p.id = p_participant and p.game_id = p_game_id;
  perform public.log_game_event(p_game_id, 'emergency_contact_viewed', jsonb_build_object('participant', p_participant));
  return v;
end; $$;

-- gm_end_game (zuletzt in 0005_aktionen.sql)
create or replace function public.gm_end_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.status in ('entwurf', 'geplant', 'lobby') then
    update public.games set status = 'beendet', ended_at = now(), result_json = '{"reason": "abgebrochen", "winners": []}' where id = p_game_id;
  else
    perform public.finish_game(g, public.engine_now(p_game_id), 'abgebrochen');
  end if;
  perform public.bump(p_game_id);
end; $$;

