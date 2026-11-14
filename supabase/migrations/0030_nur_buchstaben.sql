-- Runde 19: Im Spiel sieht niemand die Namen der anderen, nur ihre Buchstaben (Spieler A, B …, Hunter H1, H2 …).
-- Gilt überall ab dem Start: Spielstand, Meldungen, Chat, Blitzjagd, Fangen, Hunter-Standorte (Joker).
-- In der Lobby (vor dem Start, noch ohne Buchstaben) stehen weiterhin die Namen, damit der Host Rollen verteilen kann.

-- Name einer Person in Meldungen und im Chat: ab dem Start ihr Buchstabe (zuletzt in 0003_engine_tabellen.sql).
create or replace function public.pname(p_participant_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when p.tag is not null and g.status not in ('entwurf', 'geplant', 'lobby') then p.tag else pr.display_name end
  from public.participants p
  join public.games g on g.id = p.game_id
  join public.profiles pr on pr.user_id = p.user_id
  where p.id = p_participant_id;
$$;

-- Spielstand: die anderen Teilnehmenden nur mit Buchstaben (zuletzt in 0024_spieler_pings_naehe_radar.sql).
alter function public.game_state(uuid) rename to game_state_namen;
revoke execute on function public.game_state_namen(uuid) from public, anon, authenticated;

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v jsonb;
  v_status text;
  v_me uuid;
begin
  v := public.game_state_namen(p_game_id);
  select status into v_status from public.games where id = p_game_id;
  if v is null or v_status in ('entwurf', 'geplant', 'lobby') or jsonb_typeof(v -> 'participants') <> 'array' then
    return v;
  end if;
  select id into v_me from public.participants where game_id = p_game_id and user_id = auth.uid();
  return jsonb_set(v, '{participants}', coalesce((
    select jsonb_agg(case when e ->> 'tag' is not null and (e ->> 'id') is distinct from v_me::text
      then e || jsonb_build_object('name', e ->> 'tag', 'username', '') else e end)
    from jsonb_array_elements(v -> 'participants') e), '[]'::jsonb));
end; $$;
revoke execute on function public.game_state(uuid) from public, anon;
grant execute on function public.game_state(uuid) to authenticated;
