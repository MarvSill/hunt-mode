-- Nur noch ein Spielfeld: keine Kern-, Aussen-, Center-, Sektions-, Start- oder Schutzzonen mehr.
-- Gefahrenzonen (Sperrzonen), Treffpunkt, HQ und Fluchtpunkt bleiben, ebenso die Verkleinerung des Spielfelds.

-- Weitere Gebiete entfernen (in allen Spielen, sie haben keine Wirkung mehr).
delete from public.zones where kind not in ('spielfeld', 'sperrzone', 'exit', 'hq', 'treffpunkt');

-- Noch nicht gestartete Spiele: keine Einstellungen für weitere Gebiete.
update public.games set config_json = config_json
  || jsonb_build_object('ping', coalesce(config_json -> 'ping', '{}'::jsonb) - 'zone_overrides')
  || jsonb_build_object('zone', coalesce(config_json -> 'zone', '{}'::jsonb) || '{"sections_per_player": false, "release_on_catch": false}'::jsonb)
  || jsonb_build_object('transport', coalesce(config_json -> 'transport', '{}'::jsonb) || '{"forbidden_in_zone_types": []}'::jsonb)
where status in ('entwurf', 'geplant', 'lobby');

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
           where value #>> '{properties,kind}' in ('spielfeld', 'sperrzone', 'exit', 'hq', 'treffpunkt') loop
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
