-- Ein Startpunkt für alle, keine Zentrale, keine Ping-Ungenauigkeit.
-- * Spieler und Hunter starten am selben Punkt (Zone `treffpunkt`). Den Wartebereich der Hunter (Zone `hq`)
--   legt die Datenbank selbst an diesen Punkt; die Hunter warten dort während des Vorsprungs.
-- * Die Rolle "Zentrale" gibt es nicht mehr: alle Hunter jagen gemeinsam unterwegs.
-- * Pings zeigen immer den genauen Ort (keine Ungenauigkeit).

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

