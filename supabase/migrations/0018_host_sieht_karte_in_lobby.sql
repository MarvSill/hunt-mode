-- Vor dem Start sieht der Host alle Zonen seiner Karte, auch die Fluchtpunkt-Kandidaten.
-- Früher war der Host automatisch Spielleitung und sah dadurch alles. Seit es keine Spielleitung mehr gibt,
-- hat er eine normale Rolle; ohne diese Ausnahme fehlten ihm im Karten-Editor die eigenen Kandidaten
-- (und ein erneutes Speichern hätte sie gelöscht). Ab Spielstart gelten für ihn die normalen Regeln.
create or replace function public.can_see_zone(z public.zones)
returns boolean language plpgsql security definer set search_path = public stable as $$
declare
  v_role text := public.my_role(z.game_id);
  v_status text;
  v_now timestamptz;
begin
  if v_role is null then return false; end if;
  select status into v_status from public.games where id = z.game_id;
  if v_status in ('beendet', 'archiviert') then return true; end if;
  if v_status in ('entwurf', 'geplant', 'lobby') and public.is_game_host(z.game_id) then return true; end if;
  if z.visible_to = 'gm' then return false; end if;
  if z.visible_to = 'spieler' and v_role not in ('spieler', 'zuschauer') then return false; end if;
  if z.kind = 'exit' and z.visible_from is null then return false; end if;
  v_now := public.engine_now(z.game_id);
  return z.visible_from is null or z.visible_from <= v_now;
end; $$;
