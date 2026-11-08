-- Konto löschen (Pflicht für den Play Store): löscht das eigene Konto mit allen Daten.
-- Eigene Spiele werden mitgelöscht, Gruppen gehen an ein anderes Mitglied über.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
  g record;
  v_next uuid;
begin
  if v_uid is null then
    raise exception 'Nicht angemeldet.';
  end if;

  if exists (
    select 1 from public.participants p join public.games ga on ga.id = p.game_id
    where p.user_id = v_uid and ga.status in ('vorsprung', 'laeuft', 'finale')
  ) or exists (
    select 1 from public.games ga where ga.host_id = v_uid and ga.status in ('vorsprung', 'laeuft', 'finale')
  ) then
    raise exception 'Du bist in einem laufenden Spiel. Warte bis es vorbei ist, dann kannst du dein Konto löschen.';
  end if;

  -- Verweise in fremden Spielen lösen (Fänge, Speedhunts, Protokoll).
  update public.catches set hunter_id = null
    where hunter_id in (select id from public.participants where user_id = v_uid);
  update public.speedhunts set triggered_by = null
    where triggered_by in (select id from public.participants where user_id = v_uid);
  update public.game_events set actor_id = null where actor_id = v_uid;
  update public.game_config_changes set changed_by = null where changed_by = v_uid;

  -- Eigene Spiele mit allem, was dazugehört.
  delete from public.games where host_id = v_uid;

  -- Eigene Gruppen: an das älteste andere Mitglied übergeben, sonst löschen.
  for g in select id from public.groups where owner_id = v_uid loop
    select user_id into v_next from public.group_members
      where group_id = g.id and user_id <> v_uid order by joined_at limit 1;
    if v_next is null then
      delete from public.groups where id = g.id;
    else
      update public.groups set owner_id = v_next where id = g.id;
      update public.group_members set role = 'besitzer' where group_id = g.id and user_id = v_next;
    end if;
  end loop;

  -- Profil, Notfallkontakt, Teilnahmen, Positionen usw. hängen per CASCADE am Konto.
  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
