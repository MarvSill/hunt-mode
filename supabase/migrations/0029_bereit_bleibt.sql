-- Runde 19: "Bereit" bleibt gesetzt, auch wenn der Host danach Rollen verteilt oder mischt.
-- Vorher musste man nach jeder Änderung des Hosts wieder "Ich bin bereit" drücken.

-- set_participant_role (zuletzt in 0016_ein_startpunkt_ohne_zentrale.sql)
create or replace function public.set_participant_role(p_participant_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game_id uuid;
begin
  select game_id into v_game_id from public.participants where id = p_participant_id;
  if v_game_id is null or not public.is_game_host(v_game_id) then
    raise exception 'Nur der Host kann Rollen vergeben.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = v_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Rollen können nur vor dem Start geändert werden.' using errcode = 'P0001';
  end if;
  if p_role not in ('offen', 'spieler', 'hunter', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;

  -- "Bereit" bleibt, wie die Person es gesetzt hat (früher wurde es bei jeder Rollenänderung zurückgesetzt).
  update public.participants set role = p_role where id = p_participant_id;
  perform public.log_game_event(v_game_id, 'role_assigned', jsonb_build_object('participant_id', p_participant_id, 'role', p_role));
end;
$$;
