-- Hunt Mode: komplette Datenbank (erzeugt mit "npm run sql", nicht von Hand ändern).
-- In einem leeren Supabase-Projekt im SQL Editor einfügen und ausführen.

-- ===== 0001_fundament.sql =====

-- Schritt 1: Fundament
-- Konten/Profile (Kapitel 20), Spiele, Teilnehmende und Lobby (Kapitel 6, 13, 21.5).
-- Im Supabase-Dashboard unter "SQL Editor" komplett einfügen und ausführen.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Profile
-- ---------------------------------------------------------------------------

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 40),
  age_confirmed boolean not null default false,
  is_adult boolean not null default false,
  locale text not null default 'de',
  username_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- Notfallkontakt getrennt, damit ihn niemand ausser der Person selbst liest.
-- (Spielleitung im Notfall: ab Schritt 3 über eine eigene Funktion.)
create table public.profile_private (
  user_id uuid primary key references auth.users (id) on delete cascade,
  emergency_contact_name text not null check (char_length(emergency_contact_name) between 1 and 80),
  emergency_contact_phone text not null check (char_length(emergency_contact_phone) between 5 and 30),
  updated_at timestamptz not null default now()
);

create table public.consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('agb', 'datenschutz', 'standort')),
  version text not null,
  accepted_at timestamptz not null default now(),
  unique (user_id, kind, version)
);

-- ---------------------------------------------------------------------------
-- Spiele und Teilnehmende
-- ---------------------------------------------------------------------------

create table public.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{6}$'),
  host_id uuid not null references auth.users (id),
  name text not null check (char_length(name) between 1 and 60),
  preset_id text,
  status text not null default 'lobby' check (
    status in ('entwurf', 'geplant', 'lobby', 'vorsprung', 'laeuft', 'pausiert', 'finale', 'beendet', 'archiviert')
  ),
  config_json jsonb not null default '{}'::jsonb,
  config_version int not null default 1,
  start_at timestamptz,
  ends_at timestamptz,
  current_day int not null default 0,
  timezone text not null default 'Europe/Zurich',
  meeting_point text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.participants (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'offen' check (role in ('offen', 'spieler', 'hunter', 'zentrale', 'gm', 'zuschauer')),
  wished_role text check (wished_role in ('spieler', 'hunter', 'zentrale', 'zuschauer')),
  state text not null default 'aktiv',
  effects_json jsonb not null default '[]'::jsonb,
  color text,
  ready boolean not null default false,
  rules_accepted_at timestamptz,
  joined_at timestamptz not null default now(),
  unique (game_id, user_id)
);

create index participants_user_idx on public.participants (user_id);

-- Jede Regeländerung wird protokolliert (Kapitel 8).
create table public.game_config_changes (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  changed_by uuid references auth.users (id),
  path text not null,
  old_value jsonb,
  new_value jsonb,
  at timestamptz not null default now()
);

-- Unveränderliches Ereignisprotokoll (Kapitel 12, Event Sourcing light).
create table public.game_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games (id) on delete cascade,
  at timestamptz not null default now(),
  type text not null,
  actor_id uuid references auth.users (id),
  payload_json jsonb not null default '{}'::jsonb
);

create index game_events_game_idx on public.game_events (game_id, at);

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

create or replace function public.is_game_member(p_game_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.participants where game_id = p_game_id and user_id = auth.uid()
  );
$$;

create or replace function public.is_game_host(p_game_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.games where id = p_game_id and host_id = auth.uid());
$$;

create or replace function public.log_game_event(p_game_id uuid, p_type text, p_payload jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.game_events (game_id, type, actor_id, payload_json)
  values (p_game_id, p_type, auth.uid(), coalesce(p_payload, '{}'::jsonb));
$$;

revoke execute on function public.log_game_event(uuid, text, jsonb) from public, anon, authenticated;

-- Prüft die Voraussetzungen aus Kapitel 20, bevor jemand einem Spiel beitritt.
create or replace function public.assert_can_play()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet.' using errcode = '28000';
  end if;
  if not exists (select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null) then
    raise exception 'Bitte bestätige zuerst deine E-Mail-Adresse.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where user_id = auth.uid() and age_confirmed) then
    raise exception 'Bitte vervollständige zuerst dein Profil.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profile_private where user_id = auth.uid()) then
    raise exception 'Bitte erfasse zuerst einen Notfallkontakt.' using errcode = 'P0001';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Aktionen (RPC)
-- ---------------------------------------------------------------------------

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

  -- Der Host ist automatisch Spielleitung (Kapitel 5.1).
  insert into public.participants (game_id, user_id, role, ready)
  values (v_game.id, auth.uid(), 'gm', true);

  perform public.log_game_event(v_game.id, 'game_created', jsonb_build_object('preset', p_preset_id));
  return v_game;
end;
$$;

create or replace function public.join_game(p_code text)
returns public.games
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
begin
  perform public.assert_can_play();

  select * into v_game from public.games
  where code = trim(p_code) and status not in ('beendet', 'archiviert')
  order by created_at desc
  limit 1;

  if v_game.id is null then
    raise exception 'Kein offenes Spiel mit diesem Code gefunden.' using errcode = 'P0002';
  end if;

  if exists (select 1 from public.participants where game_id = v_game.id and user_id = auth.uid()) then
    return v_game;
  end if;

  if v_game.status not in ('entwurf', 'geplant', 'lobby') then
    raise exception 'Dieses Spiel läuft bereits. Beitreten ist nur in der Lobby möglich.' using errcode = 'P0001';
  end if;

  insert into public.participants (game_id, user_id) values (v_game.id, auth.uid());
  perform public.log_game_event(v_game.id, 'participant_joined');
  return v_game;
end;
$$;

-- Host vergibt Rollen (Kapitel 21.5, Schritt 5).
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
  if p_role not in ('offen', 'spieler', 'hunter', 'zentrale', 'gm', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;

  update public.participants set role = p_role, ready = false where id = p_participant_id;
  perform public.log_game_event(v_game_id, 'role_assigned', jsonb_build_object('participant_id', p_participant_id, 'role', p_role));
end;
$$;

-- Host entfernt eine Person aus der Lobby oder eine Person verlässt das Spiel.
create or replace function public.remove_participant(p_participant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p public.participants;
  v_game public.games;
begin
  select * into v_p from public.participants where id = p_participant_id;
  if v_p.id is null then
    return;
  end if;
  select * into v_game from public.games where id = v_p.game_id;
  if v_p.user_id <> auth.uid() and v_game.host_id <> auth.uid() then
    raise exception 'Keine Berechtigung.' using errcode = '42501';
  end if;
  if v_p.user_id = v_game.host_id then
    raise exception 'Der Host kann das Spiel nicht verlassen.' using errcode = 'P0001';
  end if;
  if v_game.status not in ('entwurf', 'geplant', 'lobby') then
    raise exception 'Während des Spiels: bitte "Aufgeben" verwenden (kommt in Schritt 3).' using errcode = 'P0001';
  end if;

  delete from public.participants where id = p_participant_id;
  perform public.log_game_event(v_p.game_id, 'participant_left', jsonb_build_object('user_id', v_p.user_id));
end;
$$;

-- Teilnehmende melden sich bereit: Wunschrolle und Regeln akzeptiert.
create or replace function public.set_ready(p_game_id uuid, p_ready boolean, p_wished_role text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_wished_role is not null and p_wished_role not in ('spieler', 'hunter', 'zentrale', 'zuschauer') then
    raise exception 'Unbekannte Rolle.' using errcode = '22023';
  end if;
  update public.participants
  set ready = p_ready,
      wished_role = coalesce(p_wished_role, wished_role),
      rules_accepted_at = case when p_ready then coalesce(rules_accepted_at, now()) else rules_accepted_at end
  where game_id = p_game_id and user_id = auth.uid();
end;
$$;

-- Regeländerung durch den Host, jede geänderte Einstellung wird protokolliert.
create or replace function public.update_game_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_change jsonb;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Regeln ändern.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = p_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Live-Änderungen während des Spiels kommen in Schritt 7.' using errcode = 'P0001';
  end if;

  update public.games
  set config_json = p_config,
      timezone = coalesce(p_config #>> '{game,timezone}', timezone),
      updated_at = now()
  where id = p_game_id;

  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value)
    values (p_game_id, auth.uid(), v_change ->> 'path', v_change -> 'old', v_change -> 'new');
  end loop;

  perform public.log_game_event(p_game_id, 'config_changed', jsonb_build_object('changes', jsonb_array_length(coalesce(p_changes, '[]'::jsonb))));
end;
$$;

create or replace function public.update_game_details(p_game_id uuid, p_name text, p_start_at timestamptz, p_meeting_point text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann das Spiel bearbeiten.' using errcode = '42501';
  end if;
  update public.games
  set name = p_name, start_at = p_start_at, meeting_point = p_meeting_point, updated_at = now()
  where id = p_game_id;
end;
$$;

-- Profil-Namen der Mitspielenden (nur Anzeigename und Benutzername).
create or replace function public.game_roster(p_game_id uuid)
returns table (
  participant_id uuid,
  user_id uuid,
  username text,
  display_name text,
  role text,
  wished_role text,
  ready boolean,
  is_adult boolean,
  joined_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.user_id, pr.username, pr.display_name, p.role, p.wished_role, p.ready, pr.is_adult, p.joined_at
  from public.participants p
  join public.profiles pr on pr.user_id = p.user_id
  where p.game_id = p_game_id and public.is_game_member(p_game_id)
  order by p.joined_at;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security: Lesen über Policies, Schreiben nur über die Funktionen oben
-- (ausser dem eigenen Profil).
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.profile_private enable row level security;
alter table public.consents enable row level security;
alter table public.games enable row level security;
alter table public.participants enable row level security;
alter table public.game_config_changes enable row level security;
alter table public.game_events enable row level security;

create policy "Profil: eigenes lesen" on public.profiles
  for select to authenticated using (user_id = auth.uid());
create policy "Profil: eigenes anlegen" on public.profiles
  for insert to authenticated with check (user_id = auth.uid());
create policy "Profil: eigenes ändern" on public.profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Notfallkontakt: nur selbst" on public.profile_private
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Einwilligungen: eigene lesen" on public.consents
  for select to authenticated using (user_id = auth.uid());
create policy "Einwilligungen: eigene anlegen" on public.consents
  for insert to authenticated with check (user_id = auth.uid());

create policy "Spiele: Teilnehmende lesen" on public.games
  for select to authenticated using (public.is_game_member(id));

create policy "Teilnehmende: Mitspielende lesen" on public.participants
  for select to authenticated using (public.is_game_member(game_id));

create policy "Regeländerungen: Teilnehmende lesen" on public.game_config_changes
  for select to authenticated using (public.is_game_member(game_id));

create policy "Ereignisse: Host liest" on public.game_events
  for select to authenticated using (public.is_game_host(game_id));

-- Nur angemeldete Personen dürfen die Funktionen aufrufen.
revoke execute on function public.create_game(text, text, jsonb, timestamptz) from public, anon;
revoke execute on function public.join_game(text) from public, anon;
revoke execute on function public.set_participant_role(uuid, text) from public, anon;
revoke execute on function public.remove_participant(uuid) from public, anon;
revoke execute on function public.set_ready(uuid, boolean, text) from public, anon;
revoke execute on function public.update_game_config(uuid, jsonb, jsonb) from public, anon;
revoke execute on function public.update_game_details(uuid, text, timestamptz, text) from public, anon;
revoke execute on function public.game_roster(uuid) from public, anon;
revoke execute on function public.assert_can_play() from public, anon;
grant execute on function public.create_game(text, text, jsonb, timestamptz) to authenticated;
grant execute on function public.join_game(text) to authenticated;
grant execute on function public.set_participant_role(uuid, text) to authenticated;
grant execute on function public.remove_participant(uuid) to authenticated;
grant execute on function public.set_ready(uuid, boolean, text) to authenticated;
grant execute on function public.update_game_config(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.update_game_details(uuid, text, timestamptz, text) to authenticated;
grant execute on function public.game_roster(uuid) to authenticated;
grant execute on function public.assert_can_play() to authenticated;

-- Live-Updates für die Lobby (Realtime beachtet RLS).
alter publication supabase_realtime add table public.participants;
alter publication supabase_realtime add table public.games;

-- Tabellenrechte ausdrücklich setzen (neuere Supabase-Projekte geben neue
-- Tabellen nicht mehr automatisch für die Data API frei). RLS gilt zusätzlich.
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.profile_private to authenticated;
grant select, insert on public.consents to authenticated;
grant select on public.games, public.participants, public.game_config_changes, public.game_events to authenticated;

-- ===== 0002_karte_gruppen.sql =====

-- Schritt 2: Karte und Zonen (Kapitel 7.2, 22), Gruppen und Einladungen (Kapitel 21)

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Gruppen (Crews)
-- ---------------------------------------------------------------------------

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 3 and 40),
  description text,
  invite_code text not null unique default lpad((floor(random() * 100000000))::int::text, 8, '0'),
  owner_id uuid not null references auth.users (id),
  members_can_create_games boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'mitglied' check (role in ('besitzer', 'admin', 'mitglied')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

alter table public.games add column group_id uuid references public.groups (id) on delete set null;

create or replace function public.is_group_member(p_group_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id = p_group_id and user_id = auth.uid());
$$;

create or replace function public.create_group(p_name text, p_description text default null)
returns public.groups language plpgsql security definer set search_path = public as $$
declare v public.groups;
begin
  perform public.assert_can_play();
  insert into public.groups (name, description, owner_id) values (trim(p_name), p_description, auth.uid()) returning * into v;
  insert into public.group_members (group_id, user_id, role) values (v.id, auth.uid(), 'besitzer');
  return v;
end; $$;

create or replace function public.join_group(p_code text)
returns public.groups language plpgsql security definer set search_path = public as $$
declare v public.groups;
begin
  perform public.assert_can_play();
  select * into v from public.groups where invite_code = trim(p_code);
  if v.id is null then raise exception 'Keine Gruppe mit diesem Code gefunden.' using errcode = 'P0002'; end if;
  insert into public.group_members (group_id, user_id) values (v.id, auth.uid()) on conflict do nothing;
  return v;
end; $$;

create or replace function public.leave_group(p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.groups where id = p_group_id and owner_id = auth.uid()) then
    raise exception 'Als Besitzer kannst du die Gruppe nicht verlassen. Übertrage zuerst den Besitz oder lösche die Gruppe.' using errcode = 'P0001';
  end if;
  delete from public.group_members where group_id = p_group_id and user_id = auth.uid();
end; $$;

create or replace function public.set_group_member_role(p_group_id uuid, p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.groups where id = p_group_id and owner_id = auth.uid()) then
    raise exception 'Nur der Besitzer kann Rollen ändern.' using errcode = '42501';
  end if;
  if p_role = 'besitzer' then
    update public.group_members set role = 'admin' where group_id = p_group_id and user_id = auth.uid();
    update public.groups set owner_id = p_user_id where id = p_group_id;
  end if;
  update public.group_members set role = p_role where group_id = p_group_id and user_id = p_user_id;
end; $$;

create or replace function public.remove_group_member(p_group_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.group_members where group_id = p_group_id and user_id = auth.uid() and role in ('besitzer', 'admin')) then
    raise exception 'Nur Admins können Mitglieder entfernen.' using errcode = '42501';
  end if;
  if exists (select 1 from public.groups where id = p_group_id and owner_id = p_user_id) then
    raise exception 'Der Besitzer kann nicht entfernt werden.' using errcode = 'P0001';
  end if;
  delete from public.group_members where group_id = p_group_id and user_id = p_user_id;
end; $$;

create or replace function public.delete_group(p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.groups where id = p_group_id and owner_id = auth.uid()) then
    raise exception 'Nur der Besitzer kann die Gruppe löschen.' using errcode = '42501';
  end if;
  delete from public.groups where id = p_group_id;
end; $$;

create or replace function public.group_roster(p_group_id uuid)
returns table (user_id uuid, username text, display_name text, role text, joined_at timestamptz)
language sql security definer set search_path = public stable as $$
  select m.user_id, p.username, p.display_name, m.role, m.joined_at
  from public.group_members m join public.profiles p on p.user_id = m.user_id
  where m.group_id = p_group_id and public.is_group_member(p_group_id)
  order by m.joined_at;
$$;

-- Spiel einer Gruppe zuordnen (Admins, oder Mitglieder falls erlaubt).
create or replace function public.set_game_group(p_game_id uuid, p_group_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur der Host.' using errcode = '42501'; end if;
  if p_group_id is not null and not exists (
    select 1 from public.group_members m join public.groups g on g.id = m.group_id
    where m.group_id = p_group_id and m.user_id = auth.uid() and (m.role in ('besitzer', 'admin') or g.members_can_create_games)
  ) then
    raise exception 'In dieser Gruppe darfst du keine Spiele erstellen.' using errcode = '42501';
  end if;
  update public.games set group_id = p_group_id where id = p_game_id;
end; $$;

-- Gruppen-Admins/Mitglieder sehen die Spiele ihrer Gruppe (Name, Status, Code), um beizutreten.
create or replace function public.group_games(p_group_id uuid)
returns table (id uuid, name text, code text, status text, start_at timestamptz, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select g.id, g.name, g.code, g.status, g.start_at, g.created_at from public.games g
  where g.group_id = p_group_id and public.is_group_member(p_group_id)
  order by g.created_at desc;
$$;

alter table public.groups enable row level security;
alter table public.group_members enable row level security;
create policy "Gruppen: Mitglieder lesen" on public.groups for select to authenticated using (public.is_group_member(id));
create policy "Gruppen: Besitzer ändert" on public.groups for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "Mitglieder: Gruppe liest" on public.group_members for select to authenticated using (public.is_group_member(group_id));
grant select, update on public.groups to authenticated;
grant select on public.group_members to authenticated;

-- ---------------------------------------------------------------------------
-- Zonen
-- ---------------------------------------------------------------------------

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  kind text not null check (kind in (
    'spielfeld', 'sektion', 'startzone', 'center', 'kern', 'aussen', 'sperrzone', 'sicher',
    'exit', 'hq', 'treffpunkt'
  )),
  name text not null default '',
  color text,
  geom extensions.geometry(Geometry, 4326) not null,
  -- Punkt-Zonen (HQ, Exit, Treffpunkt): Radius in Metern.
  radius_m int,
  -- Spielfeld pro Spieltag (null = alle Tage).
  day_index int,
  -- Spielfeld-Tag vergrössert sich bewusst (22.2).
  grows boolean not null default false,
  ping_interval_override int,
  -- Sperrzone: Überqueren erlaubt, Aufenthalt nicht.
  crossing_allowed boolean not null default false,
  restricted_type text,
  owner_participant_id uuid references public.participants (id) on delete set null,
  released boolean not null default false,
  -- Sichtbarkeit im Spiel (22.7): ab wann und für wen.
  visible_from timestamptz,
  visible_to text not null default 'alle' check (visible_to in ('alle', 'spieler', 'gm')),
  version int not null default 1,
  created_at timestamptz not null default now()
);

create index zones_game_idx on public.zones (game_id);
create index zones_geom_idx on public.zones using gist (geom);

-- Rolle der aktuellen Person in einem Spiel.
create or replace function public.my_role(p_game_id uuid)
returns text language sql security definer set search_path = public stable as $$
  select role from public.participants where game_id = p_game_id and user_id = auth.uid();
$$;

create or replace function public.is_game_gm(p_game_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select coalesce(public.my_role(p_game_id) = 'gm', false);
$$;

-- Wer darf eine Zone sehen? Vor dem Start: alle Teilnehmenden ausser Exit-Kandidaten
-- (die sieht nur die Spielleitung). Im Spiel gilt visible_from/visible_to.
create or replace function public.can_see_zone(z public.zones)
returns boolean language plpgsql security definer set search_path = public stable as $$
declare
  v_role text := public.my_role(z.game_id);
  v_status text;
  v_now timestamptz;
begin
  if v_role is null then return false; end if;
  if v_role = 'gm' then return true; end if;
  select status into v_status from public.games where id = z.game_id;
  if v_status in ('beendet', 'archiviert') then return true; end if;
  if z.visible_to = 'gm' then return false; end if;
  if z.visible_to = 'spieler' and v_role not in ('spieler', 'zuschauer') then return false; end if;
  if z.kind = 'exit' and z.visible_from is null then return false; end if;
  v_now := public.engine_now(z.game_id);
  return z.visible_from is null or z.visible_from <= v_now;
end; $$;

alter table public.zones enable row level security;
create policy "Zonen: nach Sichtbarkeit" on public.zones for select to authenticated using (public.can_see_zone(zones));
grant select on public.zones to authenticated;

-- Karte speichern: ersetzt alle Zonen eines Spiels (nur vor dem Start).
-- p_features: GeoJSON-FeatureCollection.features; properties: kind, name, color, radius_m,
-- day_index, grows, ping_interval_override, crossing_allowed, restricted_type, owner_participant_id.
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
    raise exception 'Die Karte ist ab Spielstart gesperrt (nur die Spielleitung kann Sperrzonen ergänzen).' using errcode = 'P0001';
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

-- Karte als GeoJSON lesen (nur sichtbare Zonen).
create or replace function public.game_map(p_game_id uuid)
returns jsonb language sql security definer set search_path = public, extensions stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', 'Feature',
    'id', z.id,
    'geometry', ST_AsGeoJSON(z.geom)::jsonb,
    'properties', jsonb_build_object(
      'id', z.id, 'kind', z.kind, 'name', z.name, 'color', z.color, 'radius_m', z.radius_m,
      'day_index', z.day_index, 'grows', z.grows, 'ping_interval_override', z.ping_interval_override,
      'crossing_allowed', z.crossing_allowed, 'restricted_type', z.restricted_type,
      'owner_participant_id', z.owner_participant_id, 'released', z.released,
      'visible_from', z.visible_from
    )
  ) order by z.created_at), '[]'::jsonb)
  from public.zones z
  where z.game_id = p_game_id and public.can_see_zone(z);
$$;

revoke execute on function public.save_map(uuid, jsonb) from public, anon;
revoke execute on function public.game_map(uuid) from public, anon;
grant execute on function public.save_map(uuid, jsonb), public.game_map(uuid) to authenticated;
grant execute on function public.create_group(text, text), public.join_group(text), public.leave_group(uuid),
  public.set_group_member_role(uuid, uuid, text), public.remove_group_member(uuid, uuid), public.delete_group(uuid),
  public.group_roster(uuid), public.set_game_group(uuid, uuid), public.group_games(uuid) to authenticated;
revoke execute on function public.create_group(text, text), public.join_group(text), public.leave_group(uuid),
  public.set_group_member_role(uuid, uuid, text), public.remove_group_member(uuid, uuid), public.delete_group(uuid),
  public.group_roster(uuid), public.set_game_group(uuid, uuid), public.group_games(uuid) from anon;

-- ===== 0003_engine_tabellen.sql =====

-- Schritt 3: Tabellen der Spiel-Engine (Kapitel 13).
-- Gelesen wird fast alles über game_state() (0006), damit die Sichtbarkeit
-- (Kapitel 5.2) an einer Stelle serverseitig entschieden wird.

-- ---------------------------------------------------------------------------
-- Spiel- und Teilnehmerzustand
-- ---------------------------------------------------------------------------

alter table public.games
  add column hunt_start_at timestamptz,
  add column deadline_at timestamptz,
  add column next_day_at timestamptz,
  add column paused_at timestamptz,
  add column pause_reason text,
  add column clock_offset interval not null default interval '0',
  add column is_test boolean not null default false,
  add column exit_zone_id uuid references public.zones (id) on delete set null,
  add column exit_reveal_at timestamptz,
  add column exit_revealed boolean not null default false,
  add column last_tick_at timestamptz,
  add column speedhunts_left int not null default 0,
  add column last_speedhunt_target uuid,
  add column state_json jsonb not null default '{}'::jsonb,
  add column result_json jsonb,
  add column ended_at timestamptz,
  add column map_version int not null default 1;

alter table public.participants
  add column catch_secret text not null default encode(gen_random_bytes(12), 'hex'),
  add column next_ping_at timestamptz,
  add column ping_pending_until timestamptz,
  add column location_request_at timestamptz,
  add column last_silent_ping_at timestamptz,
  add column out_pending_since timestamptz,
  add column out_accum_s int not null default 0,
  add column grace_until timestamptz,
  add column restricted_zone_id uuid,
  add column restricted_since timestamptz,
  add column restricted_violated boolean not null default false,
  add column speeding_since timestamptz,
  add column transport_prompted_at timestamptz,
  add column forbidden_since timestamptz,
  add column forbidden_last_violation_at timestamptz,
  add column stationary_center extensions.geometry(Point, 4326),
  add column stationary_since timestamptz,
  add column hideout_prompted_at timestamptz,
  add column rides_today int not null default 0,
  add column ferry_stops_today int not null default 0,
  add column budget_balance numeric(10, 2) not null default 0,
  add column bounty int not null default 0,
  add column state_before text,
  add column caught_at timestamptz,
  add column finished_at timestamptz,
  add column last_seen_at timestamptz,
  add column battery int,
  add column signal_warned_at timestamptz,
  add column battery_warned int,
  add column device_check jsonb not null default '{}'::jsonb,
  add column in_hq boolean not null default false,
  add column on_break boolean not null default false,
  add column briefing_done_day int;

-- Aktuelle Position je Teilnehmer (letzter gültiger Punkt).
create table public.positions (
  participant_id uuid primary key references public.participants (id) on delete cascade,
  game_id uuid not null references public.games (id) on delete cascade,
  geom extensions.geometry(Point, 4326) not null,
  lat double precision not null,
  lng double precision not null,
  accuracy_m real,
  speed_mps real,
  heading real,
  at timestamptz not null,
  received_at timestamptz not null default now()
);

create table public.location_samples (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  at timestamptz not null,
  geom extensions.geometry(Point, 4326) not null,
  accuracy_m real,
  speed_mps real,
  heading real,
  battery int,
  is_mock boolean not null default false,
  received_at timestamptz not null default now()
);
create index location_samples_p_idx on public.location_samples (participant_id, at desc);
create index location_samples_g_idx on public.location_samples (game_id, at);

create table public.pings (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  at timestamptz not null,
  visible_at timestamptz not null,
  lat double precision,
  lng double precision,
  accuracy_m real,
  source text not null check (source in (
    'silent', 'speedhunt', 'purchase', 'transit', 'proximity', 'fake', 'hotel_end', 'out_of_bounds',
    'penalty', 'gm', 'kein_signal', 'challenge', 'device_switch'
  )),
  n int,
  speedhunt_id uuid,
  zone_kind text,
  label text,
  stale_seconds int,
  is_fake boolean not null default false
);
create index pings_game_idx on public.pings (game_id, at);

-- Echte Position gefälschter Pings: nur Spielleitung (Kapitel 16).
create table public.ping_truth (
  ping_id uuid primary key references public.pings (id) on delete cascade,
  lat double precision not null,
  lng double precision not null
);

create table public.live_windows (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  reason text not null,
  starts_at timestamptz not null,
  ends_at timestamptz
);
create index live_windows_p_idx on public.live_windows (participant_id);

create table public.active_effects (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  type text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  payload jsonb not null default '{}'::jsonb,
  source_item_id uuid
);
create index active_effects_p_idx on public.active_effects (participant_id);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  kind text not null check (kind in ('joker', 'bonus')),
  type text not null,
  minutes int,
  granted_day int,
  granted_at timestamptz not null,
  expires_at timestamptz,
  used_at timestamptz,
  expired boolean not null default false,
  source text
);

create table public.speedhunts (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  target_id uuid not null references public.participants (id) on delete cascade,
  day_index int not null,
  triggered_by uuid references public.participants (id),
  is_penalty boolean not null default false,
  status text not null default 'laeuft' check (status in ('wartet_auf_freigabe', 'aufgeschoben', 'laeuft', 'beendet')),
  queries_total int not null,
  queries_used int not null default 0,
  created_at timestamptz not null,
  started_at timestamptz,
  deadline_at timestamptz,
  last_query_at timestamptz,
  ended_at timestamptz,
  end_reason text
);
create index speedhunts_game_idx on public.speedhunts (game_id, status);

create table public.catches (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  runner_id uuid not null references public.participants (id) on delete cascade,
  hunter_id uuid references public.participants (id),
  at timestamptz not null,
  lat double precision,
  lng double precision,
  method text not null,
  distance_m real,
  media_path text,
  status text not null default 'gueltig' check (status in ('wartet_auf_bestaetigung', 'wartet_auf_beweis', 'gueltig', 'abgelehnt', 'annulliert')),
  expires_at timestamptz,
  reason text
);

create table public.violations (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  type text not null,
  detected_by text not null default 'auto' check (detected_by in ('auto', 'gm', 'meldung')),
  at timestamptz not null,
  evidence jsonb not null default '{}'::jsonb,
  proposed_penalty text not null,
  decided_penalty text,
  status text not null default 'offen' check (status in ('offen', 'verhaengt', 'verworfen')),
  auto_apply_at timestamptz,
  explanation text,
  decided_at timestamptz
);

create table public.hideouts (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  center extensions.geometry(Point, 4326) not null,
  first_entered_at timestamptz not null,
  entered_at timestamptz not null,
  accum_s int not null default 0,
  inside boolean not null default true,
  status text not null default 'aktiv' check (status in ('aktiv', 'verlassen', 'abgelaufen')),
  detection text not null,
  warned int not null default 0,
  left_at timestamptz
);

create table public.transit_sessions (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  mode text not null,
  line text,
  from_station text,
  to_station text,
  stops int,
  started_at timestamptz not null,
  ended_at timestamptz,
  live_after_minutes int
);

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  amount numeric(10, 2) not null check (amount > 0),
  category text not null,
  note text,
  at timestamptz not null,
  lat double precision,
  lng double precision,
  receipt_path text
);

create table public.challenges (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  template text not null default 'eigene',
  title text not null,
  description text not null default '',
  lat double precision,
  lng double precision,
  radius_m int,
  announce_at timestamptz,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  proof_type text not null default 'geofence' check (proof_type in ('geofence', 'code', 'foto', 'spielleitung')),
  secret_code text,
  reward_type text not null default 'bonus_fake_ping',
  reward_value int,
  reveal_location_to_taskforce boolean not null default true,
  max_participants int,
  status text not null default 'geplant' check (status in ('geplant', 'angekuendigt', 'laeuft', 'beendet', 'abgesagt')),
  created_at timestamptz not null default now()
);

create table public.challenge_entries (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  joined_at timestamptz not null,
  proof_path text,
  proof_text text,
  result text not null default 'offen' check (result in ('offen', 'eingereicht', 'erfolgreich', 'gescheitert')),
  decided_at timestamptz,
  unique (challenge_id, participant_id)
);

create table public.emergencies (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  participant_id uuid not null references public.participants (id) on delete cascade,
  at timestamptz not null,
  lat double precision,
  lng double precision,
  status text not null default 'offen' check (status in ('offen', 'erledigt')),
  resolved_by uuid,
  resolved_at timestamptz
);

create table public.proximity_pairs (
  game_id uuid not null references public.games (id) on delete cascade,
  a uuid not null references public.participants (id) on delete cascade,
  b uuid not null references public.participants (id) on delete cascade,
  alerted boolean not null default false,
  last_alert_at timestamptz,
  primary key (a, b)
);

-- Mitteilungen (Kapitel 11). audience: alle, spieler, taskforce, gm; oder recipient = eine Person.
create table public.notifications (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games (id) on delete cascade,
  audience text check (audience in ('alle', 'spieler', 'taskforce', 'gm')),
  recipient_id uuid references public.participants (id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  payload jsonb not null default '{}'::jsonb,
  priority text not null default 'normal' check (priority in ('normal', 'hoch', 'kritisch')),
  at timestamptz not null,
  created_at timestamptz not null default now()
);
create index notifications_game_idx on public.notifications (game_id, id);

-- Chat (Kapitel 7.20). channel: ankuendigung, taskforce, spieler, gm:<participant_id>, gruppe
create table public.messages (
  id bigint generated always as identity primary key,
  game_id uuid references public.games (id) on delete cascade,
  group_id uuid references public.groups (id) on delete cascade,
  channel text not null,
  sender_id uuid references auth.users (id) on delete set null,
  sender_name text,
  body text not null check (char_length(body) between 1 and 2000),
  at timestamptz not null default now(),
  check (game_id is not null or group_id is not null)
);
create index messages_game_idx on public.messages (game_id, channel, id);
create index messages_group_idx on public.messages (group_id, id);

-- Änderungszähler pro Spiel: Clients abonnieren ihn und laden dann game_state() neu.
create table public.game_ticks (
  game_id uuid primary key references public.games (id) on delete cascade,
  version bigint not null default 0,
  map_version int not null default 1,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

-- Spielzeit: echte Zeit plus Vorlauf im Probelauf (22.6).
create or replace function public.engine_now(p_game_id uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select now() + coalesce((select clock_offset from public.games where id = p_game_id), interval '0');
$$;

create or replace function public.cfg_int(p_cfg jsonb, p_section text, p_key text, p_default int)
returns int language sql immutable as $$
  select coalesce((p_cfg -> p_section ->> p_key)::int, p_default);
$$;

create or replace function public.cfg_bool(p_cfg jsonb, p_section text, p_key text, p_default boolean)
returns boolean language sql immutable as $$
  select coalesce((p_cfg -> p_section ->> p_key)::boolean, p_default);
$$;

create or replace function public.cfg_text(p_cfg jsonb, p_section text, p_key text, p_default text)
returns text language sql immutable as $$
  select coalesce(p_cfg -> p_section ->> p_key, p_default);
$$;

create or replace function public.bump(p_game_id uuid)
returns void language sql security definer set search_path = public as $$
  insert into public.game_ticks (game_id, version) values (p_game_id, 1)
  on conflict (game_id) do update set version = game_ticks.version + 1, updated_at = now();
$$;

create or replace function public.notify(
  p_game_id uuid, p_audience text, p_recipient uuid, p_kind text, p_title text,
  p_body text default '', p_payload jsonb default '{}'::jsonb, p_priority text default 'normal'
) returns void language sql security definer set search_path = public as $$
  insert into public.notifications (game_id, audience, recipient_id, kind, title, body, payload, priority, at)
  values (p_game_id, p_audience, p_recipient, p_kind, p_title, coalesce(p_body, ''), coalesce(p_payload, '{}'::jsonb),
          p_priority, public.engine_now(p_game_id));
$$;

create or replace function public.pname(p_participant_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select pr.display_name from public.participants p join public.profiles pr on pr.user_id = p.user_id
  where p.id = p_participant_id;
$$;

create or replace function public.my_participant(p_game_id uuid)
returns public.participants language sql stable security definer set search_path = public as $$
  select * from public.participants where game_id = p_game_id and user_id = auth.uid();
$$;

create or replace function public.has_effect(p_participant_id uuid, p_type text, p_now timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.active_effects
    where participant_id = p_participant_id and type = p_type and starts_at <= p_now
      and (ends_at is null or ends_at > p_now)
  );
$$;

create or replace function public.has_live_window(p_participant_id uuid, p_now timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.live_windows
    where participant_id = p_participant_id and starts_at <= p_now and (ends_at is null or ends_at > p_now)
  );
$$;

create or replace function public.open_live_window(p_game_id uuid, p_participant_id uuid, p_reason text, p_starts timestamptz, p_ends timestamptz)
returns void language sql security definer set search_path = public as $$
  insert into public.live_windows (game_id, participant_id, reason, starts_at, ends_at)
  values (p_game_id, p_participant_id, p_reason, p_starts, p_ends);
$$;

create or replace function public.close_live_windows(p_participant_id uuid, p_reason text, p_at timestamptz)
returns void language sql security definer set search_path = public as $$
  update public.live_windows set ends_at = p_at
  where participant_id = p_participant_id and reason = p_reason and (ends_at is null or ends_at > p_at);
$$;

-- RLS: Direkte Tabellenzugriffe sind gesperrt, ausser Mitteilungen, Chat und Änderungszähler
-- (für Realtime). Alles andere liest game_state().
alter table public.positions enable row level security;
alter table public.location_samples enable row level security;
alter table public.pings enable row level security;
alter table public.ping_truth enable row level security;
alter table public.live_windows enable row level security;
alter table public.active_effects enable row level security;
alter table public.inventory_items enable row level security;
alter table public.speedhunts enable row level security;
alter table public.catches enable row level security;
alter table public.violations enable row level security;
alter table public.hideouts enable row level security;
alter table public.transit_sessions enable row level security;
alter table public.purchases enable row level security;
alter table public.challenges enable row level security;
alter table public.challenge_entries enable row level security;
alter table public.emergencies enable row level security;
alter table public.proximity_pairs enable row level security;
alter table public.notifications enable row level security;
alter table public.messages enable row level security;
alter table public.game_ticks enable row level security;

create or replace function public.can_see_notification(n public.notifications)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.participants := public.my_participant(n.game_id);
begin
  if v_p.id is null then return false; end if;
  if n.recipient_id is not null then return n.recipient_id = v_p.id; end if;
  return case n.audience
    when 'alle' then true
    when 'spieler' then v_p.role in ('spieler', 'zuschauer', 'gm')
    when 'taskforce' then v_p.role in ('hunter', 'zentrale', 'gm')
    when 'gm' then v_p.role = 'gm'
    else false
  end;
end; $$;

create or replace function public.can_see_message(m public.messages)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.participants;
begin
  if m.group_id is not null then return public.is_group_member(m.group_id); end if;
  v_p := public.my_participant(m.game_id);
  if v_p.id is null then return false; end if;
  if v_p.role = 'gm' then return true; end if;
  if m.channel = 'ankuendigung' then return true; end if;
  if m.channel = 'taskforce' then return v_p.role in ('hunter', 'zentrale'); end if;
  if m.channel = 'spieler' then return v_p.role = 'spieler'; end if;
  if m.channel = 'gm:' || v_p.id::text then return true; end if;
  return false;
end; $$;

create policy "Mitteilungen: Empfänger" on public.notifications for select to authenticated using (public.can_see_notification(notifications));
create policy "Chat: Kanal-Mitglieder" on public.messages for select to authenticated using (public.can_see_message(messages));
create policy "Ticks: Teilnehmende" on public.game_ticks for select to authenticated using (public.is_game_member(game_id));
grant select on public.notifications, public.messages, public.game_ticks to authenticated;

alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.game_ticks;

-- Speicher für Beweisfotos (Fang, Beleg, Challenge).
insert into storage.buckets (id, name, public) values ('beweise', 'beweise', false) on conflict (id) do nothing;

create policy "Beweise: eigene hochladen" on storage.objects for insert to authenticated
  with check (bucket_id = 'beweise' and (storage.foldername(name))[2] = auth.uid()::text);
create policy "Beweise: Teilnehmende lesen" on storage.objects for select to authenticated
  using (bucket_id = 'beweise' and public.is_game_member(((storage.foldername(name))[1])::uuid));

-- ===== 0004_engine_logik.sql =====

-- Schritt 3 bis 6: Spiel-Engine (Kapitel 6, 7, 14, 23).
-- Server-autoritativ: alle Regelentscheidungen fallen hier. Die Engine wird
-- von engine_tick_all() (pg_cron, alle 15 s) und bei jedem Standort-Update
-- (report_location) für das betroffene Spiel aufgerufen.

-- ---------------------------------------------------------------------------
-- Geometrie
-- ---------------------------------------------------------------------------

create or replace function public.pt(p_lat double precision, p_lng double precision)
returns extensions.geometry language sql immutable set search_path = public, extensions as $$
  select ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326);
$$;

create or replace function public.dist_m(a extensions.geometry, b extensions.geometry)
returns double precision language sql immutable set search_path = public, extensions as $$
  select ST_Distance(a::geography, b::geography);
$$;

-- Spielfeld eines Spieltags: Zonen mit dem höchsten day_index <= Tag, sonst die ohne Tag.
create or replace function public.spielfeld_day(p_game_id uuid, p_day int)
returns extensions.geometry language sql stable security definer set search_path = public, extensions as $$
  with best as (
    select max(day_index) d from public.zones
    where game_id = p_game_id and kind = 'spielfeld' and day_index is not null and day_index <= greatest(p_day, 1)
  )
  select ST_Union(z.geom) from public.zones z, best
  where z.game_id = p_game_id and z.kind = 'spielfeld'
    and ((best.d is not null and z.day_index = best.d) or (best.d is null and z.day_index is null));
$$;

-- Erlaubter Bereich eines Spielers (7.2). Sperrzonen werden separat geprüft.
create or replace function public.allowed_area(p_game_id uuid, p_participant_id uuid, p_day int, p_sections boolean)
returns extensions.geometry language plpgsql stable security definer set search_path = public, extensions as $$
declare v extensions.geometry;
begin
  if p_sections then
    select ST_Union(geom) into v from public.zones
    where game_id = p_game_id and (
      (kind = 'sektion' and (owner_participant_id = p_participant_id or released))
      or kind in ('startzone', 'center')
    );
    return v;
  end if;
  v := public.spielfeld_day(p_game_id, p_day);
  if v is null then
    select ST_Union(geom) into v from public.zones where game_id = p_game_id and kind in ('sektion', 'startzone', 'center');
  end if;
  return v;
end; $$;

-- Zonentyp mit eigenem Ping-Intervall an einem Punkt (center > kern > aussen).
create or replace function public.zone_kind_at(p_game_id uuid, p_point extensions.geometry)
returns text language sql stable security definer set search_path = public, extensions as $$
  select kind from public.zones
  where game_id = p_game_id and kind in ('center', 'kern', 'aussen') and ST_Covers(geom, p_point)
  order by case kind when 'center' then 1 when 'kern' then 2 else 3 end
  limit 1;
$$;

create or replace function public.ping_interval_at(p_game public.games, p_point extensions.geometry)
returns int language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_zone public.zones;
  v_override int;
begin
  if p_point is not null then
    select * into v_zone from public.zones
    where game_id = p_game.id and kind in ('center', 'kern', 'aussen') and ST_Covers(geom, p_point)
    order by case kind when 'center' then 1 when 'kern' then 2 else 3 end limit 1;
    if v_zone.id is not null then
      if v_zone.ping_interval_override is not null then return v_zone.ping_interval_override; end if;
      v_override := (v_cfg #>> array['ping', 'zone_overrides', v_zone.kind])::int;
      if v_override is not null then return v_override; end if;
    end if;
  end if;
  return public.cfg_int(v_cfg, 'ping', 'interval_minutes', 120);
end; $$;

-- ---------------------------------------------------------------------------
-- Zeitraster
-- ---------------------------------------------------------------------------

-- Nächster Ping-Zeitpunkt strikt nach p_from (7.3, 14.4).
create or replace function public.next_ping_time(p_game public.games, p_from timestamptz, p_interval int)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_offset int := public.cfg_int(v_cfg, 'ping', 'offset_minutes', 0);
  v_jitter int := public.cfg_int(v_cfg, 'ping', 'jitter_minutes', 0);
  v_base timestamptz;
  v_local timestamp;
  v_midnight timestamp;
  v_min double precision;
  v_k bigint;
  v_t timestamptz;
begin
  if public.cfg_bool(v_cfg, 'time', 'align_to_full_hour', true) then
    v_local := p_from at time zone p_game.timezone;
    v_midnight := date_trunc('day', v_local);
    v_min := extract(epoch from (v_local - v_midnight)) / 60.0;
    v_k := floor((v_min - v_offset) / p_interval) + 1;
    v_t := (v_midnight + make_interval(mins => (v_offset + v_k * p_interval)::int)) at time zone p_game.timezone;
  else
    v_base := p_game.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'ping', 'first_ping_delay_minutes', 0));
    v_k := greatest(1, floor(extract(epoch from (p_from - v_base)) / 60.0 / p_interval) + 1);
    v_t := v_base + make_interval(mins => (v_k * p_interval)::int);
  end if;
  if v_t <= p_from then v_t := v_t + make_interval(mins => p_interval); end if;
  if v_jitter > 0 then v_t := v_t + make_interval(secs => floor(random() * v_jitter * 60)); end if;
  return v_t;
end; $$;

-- Beginn von Spieltag d (6.4, 7.1).
create or replace function public.day_start(p_game public.games, p_day int)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_len int := public.cfg_int(v_cfg, 'game', 'day_length_minutes', 1440);
  v_reset text := public.cfg_text(v_cfg, 'game', 'day_reset_time', '06:00');
  v_local timestamp;
  v_first timestamptz;
begin
  if p_day <= 1 then return p_game.hunt_start_at; end if;
  if v_len = 1440 and public.cfg_bool(v_cfg, 'time', 'align_to_full_hour', true) then
    v_local := date_trunc('day', p_game.hunt_start_at at time zone p_game.timezone) + v_reset::time;
    v_first := v_local at time zone p_game.timezone;
    if v_first <= p_game.hunt_start_at then v_first := v_first + interval '1 day'; end if;
    return v_first + make_interval(days => p_day - 2);
  end if;
  return p_game.hunt_start_at + make_interval(mins => (p_day - 1) * v_len);
end; $$;

-- Jagdfreie Zeiten (game.quiet_hours, lokale Zeit; über Mitternacht erlaubt).
create or replace function public.in_quiet_hours(p_game public.games, p_now timestamptz)
returns boolean language plpgsql stable set search_path = public as $$
declare
  v_t time := (p_now at time zone p_game.timezone)::time;
  q jsonb;
  v_from time;
  v_to time;
begin
  for q in select * from jsonb_array_elements(coalesce(p_game.config_json -> 'game' -> 'quiet_hours', '[]')) loop
    v_from := (q ->> 'from')::time;
    v_to := (q ->> 'to')::time;
    if (v_from <= v_to and v_t >= v_from and v_t < v_to) or (v_from > v_to and (v_t >= v_from or v_t < v_to)) then
      return true;
    end if;
  end loop;
  return false;
end; $$;

create or replace function public.speedhunt_quota(p_cfg jsonb, p_day int)
returns int language sql immutable as $$
  select coalesce((p_cfg -> 'speedhunt' -> 'quota_per_day' ->> (p_day - 1))::int,
                  public.cfg_int(p_cfg, 'speedhunt', 'quota_default', 2));
$$;

-- ---------------------------------------------------------------------------
-- Position und Pings
-- ---------------------------------------------------------------------------

-- Beste Position: Median der Punkte der letzten 30 s mit Genauigkeit < 100 m, sonst letzter Punkt (23.4).
create or replace function public.best_position(p_participant_id uuid, p_now timestamptz,
  out lat double precision, out lng double precision, out accuracy_m real, out age_s int)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_n int;
  v_last timestamptz;
begin
  select count(*), percentile_cont(0.5) within group (order by ST_Y(geom)),
         percentile_cont(0.5) within group (order by ST_X(geom)),
         percentile_cont(0.5) within group (order by s.accuracy_m), max(at)
    into v_n, lat, lng, accuracy_m, v_last
  from public.location_samples s
  where participant_id = p_participant_id and at > p_now - interval '30 seconds' and at <= p_now
    and coalesce(s.accuracy_m, 0) < 100 and not is_mock;
  if v_n > 0 then
    age_s := greatest(0, extract(epoch from (p_now - v_last))::int);
    return;
  end if;
  select p.lat, p.lng, p.accuracy_m, greatest(0, extract(epoch from (p_now - p.at))::int)
    into lat, lng, accuracy_m, age_s
  from public.positions p where participant_id = p_participant_id;
end; $$;

-- Ping erzeugen. Ein scharfer Fake-Ping ersetzt genau den nächsten Ping der passenden Art (14.3, Regel 6).
create or replace function public.create_ping(
  p_game public.games, p_participant_id uuid, p_source text, p_lat double precision, p_lng double precision,
  p_accuracy real, p_stale int, p_n int, p_speedhunt_id uuid, p_label text, p_delay_min int, p_now timestamptz
) returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_fake public.active_effects;
  v_id uuid;
  v_blur int := public.cfg_int(p_game.config_json, 'ping', 'precision_blur_m', 0);
  v_lat double precision := p_lat;
  v_lng double precision := p_lng;
  v_is_fake boolean := false;
  v_zone text;
begin
  if p_source in ('silent', 'speedhunt') and p_lat is not null then
    select * into v_fake from public.active_effects
    where participant_id = p_participant_id and type = 'fake_ping' and (ends_at is null or ends_at > p_now)
      and (payload ->> 'applies' in ('beide', p_source))
    order by starts_at limit 1;
    if v_fake.id is not null then
      v_lat := (v_fake.payload ->> 'lat')::double precision;
      v_lng := (v_fake.payload ->> 'lng')::double precision;
      v_is_fake := true;
      update public.active_effects set ends_at = p_now, payload = payload || '{"done": true}' where id = v_fake.id;
    end if;
  end if;
  if v_blur > 0 and v_lat is not null and not v_is_fake then
    v_lat := v_lat + (random() - 0.5) * 2 * v_blur / 111320.0;
    v_lng := v_lng + (random() - 0.5) * 2 * v_blur / (111320.0 * cos(radians(v_lat)));
  end if;
  if v_lat is not null then v_zone := public.zone_kind_at(p_game.id, public.pt(v_lat, v_lng)); end if;

  insert into public.pings (game_id, participant_id, at, visible_at, lat, lng, accuracy_m, source, n, speedhunt_id,
                            zone_kind, label, stale_seconds, is_fake)
  values (p_game.id, p_participant_id, p_now, p_now + make_interval(mins => coalesce(p_delay_min, 0)), v_lat, v_lng,
          p_accuracy, p_source, p_n, p_speedhunt_id, v_zone, p_label, p_stale, v_is_fake)
  returning id into v_id;
  if v_is_fake then
    insert into public.ping_truth (ping_id, lat, lng) values (v_id, p_lat, p_lng);
  end if;
  return v_id;
end; $$;

create or replace function public.schedule_next_ping(p_game public.games, p_participant_id uuid, p_from timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_pos public.positions;
  v_interval int;
begin
  select * into v_pos from public.positions where participant_id = p_participant_id;
  v_interval := public.ping_interval_at(p_game, v_pos.geom);
  update public.participants
  set next_ping_at = public.next_ping_time(p_game, p_from, v_interval), ping_pending_until = null
  where id = p_participant_id;
end; $$;

create or replace function public.running_speedhunt_on(p_participant_id uuid)
returns public.speedhunts language sql stable security definer set search_path = public as $$
  select * from public.speedhunts where target_id = p_participant_id and status = 'laeuft' limit 1;
$$;

-- Fälliger Silent-Ping (14.4 mit Frische-Regel aus 23.4).
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
  if public.cfg_bool(v_cfg, 'ping', 'notify_player', false) then
    perform public.notify(p_game.id, null, p_p.id, 'ping_self', 'Du wurdest gepingt', '', '{}', 'normal');
  end if;
end; $$;

-- ---------------------------------------------------------------------------
-- Verstösse und Strafen (7.17)
-- ---------------------------------------------------------------------------

create or replace function public.default_penalty(p_cfg jsonb, p_type text)
returns text language sql immutable as $$
  select case p_type
    when 'ausserhalb_limit' then 'straf_speedhunt'
    when 'sperrzone' then 'verwarnung'
    when 'verschanzen_limit' then 'straf_speedhunt'
    when 'versteck_gesperrt' then 'straf_speedhunt'
    when 'oev_nicht_angemeldet' then 'straf_speedhunt'
    when 'fahrzeug_verbotene_zone' then 'straf_speedhunt'
    when 'faehren_limit' then 'verwarnung'
    when 'signalverlust' then 'straf_speedhunt'
    when 'hunter_hq' then 'verwarnung'
    else 'verwarnung'
  end;
$$;

create or replace function public.create_violation(p_game public.games, p_participant_id uuid, p_type text,
  p_evidence jsonb, p_now timestamptz, p_penalty text default null, p_detected_by text default 'auto')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_penalty text := coalesce(p_penalty, public.default_penalty(v_cfg, p_type));
  v_esc jsonb := coalesce(v_cfg -> 'penalty' -> 'escalation', '["verwarnung","straf_speedhunt","disqualifikation"]');
  v_prior int;
  v_idx int;
  v_mode text := public.cfg_text(v_cfg, 'roles', 'gm_mode', 'auto');
  v_id uuid;
begin
  -- Eskalation bei Wiederholung desselben Verstosses (penalty.escalation).
  if p_penalty is null and p_type not in ('fahrzeug_verbotene_zone') then
    select count(*) into v_prior from public.violations
    where participant_id = p_participant_id and type = p_type and status = 'verhaengt';
    select (ord - 1) into v_idx from jsonb_array_elements_text(v_esc) with ordinality e(val, ord) where val = v_penalty;
    if v_idx is not null and v_prior > 0 then
      v_penalty := v_esc ->> least(v_idx + v_prior, jsonb_array_length(v_esc) - 1);
    end if;
  end if;
  insert into public.violations (game_id, participant_id, type, detected_by, at, evidence, proposed_penalty, auto_apply_at)
  values (p_game.id, p_participant_id, p_type, p_detected_by, p_now, coalesce(p_evidence, '{}'), v_penalty,
          case when v_mode in ('auto', 'beides')
               then p_now + make_interval(secs => public.cfg_int(v_cfg, 'penalty', 'auto_apply_delay_seconds', 60)) end)
  returning id into v_id;
  perform public.notify(p_game.id, null, p_participant_id, 'violation', 'Regelverstoss: ' || replace(p_type, '_', ' '),
    'Vorgeschlagene Strafe: ' || replace(v_penalty, '_', ' ') || '. Du kannst eine Erklärung abgeben.',
    jsonb_build_object('violation_id', v_id), 'hoch');
  perform public.notify(p_game.id, 'gm', null, 'violation', 'Verstoss: ' || public.pname(p_participant_id),
    replace(p_type, '_', ' ') || ' · Vorschlag: ' || replace(v_penalty, '_', ' '), jsonb_build_object('violation_id', v_id), 'hoch');
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Speedhunt (7.4, 7.5)
-- ---------------------------------------------------------------------------

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
  v_text text := public.cfg_text(v_cfg, 'speedhunt', 'announce_text', 'Speedhunt gestartet!');
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
      case when p_is_penalty then 'Straf-Speedhunt: ' else 'Speedhunt: ' end || public.pname(p_target),
      v_queries - v_used || ' Abfragen, max. ' || public.cfg_int(v_cfg, 'speedhunt', 'max_duration_minutes', 90) || ' min',
      jsonb_build_object('speedhunt_id', v_sh.id), 'kritisch');
    if public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false) then
      perform public.notify(p_game.id, null, p_target, 'speedhunt_target', 'Du bist das Ziel!', '', '{}', 'kritisch');
    end if;
    if v_used = 1 then
      perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_info', 'Silent-Ping zählt als Abfrage 1',
        'Der letzte Silent-Ping liegt weniger als ' || v_min_after || ' min zurück.', '{}', 'normal');
    end if;
  end if;
  return v_sh;
end; $$;

create or replace function public.end_speedhunt(p_game public.games, p_sh public.speedhunts, p_reason text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_leo_end timestamptz;
begin
  update public.speedhunts set status = 'beendet', ended_at = p_now, end_reason = p_reason where id = p_sh.id;
  if p_sh.status <> 'laeuft' then return; end if;
  perform public.notify(p_game.id, 'alle', null, 'speedhunt_end', 'Speedhunt beendet', '',
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

create or replace function public.speedhunt_query_internal(p_game public.games, p_sh public.speedhunts, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_pos record;
  v_n int := p_sh.queries_used + 1;
  v_ping uuid;
  v_live int := public.cfg_int(v_cfg, 'speedhunt', 'vehicle_live_seconds', 60);
  v_speed real;
  v_in_vehicle boolean;
begin
  select * into v_pos from public.best_position(p_sh.target_id, p_now);
  v_ping := public.create_ping(p_game, p_sh.target_id, 'speedhunt', v_pos.lat, v_pos.lng, v_pos.accuracy_m,
    case when v_pos.age_s > public.cfg_int(v_cfg, 'ping', 'max_age_seconds', 60) then v_pos.age_s end,
    v_n, p_sh.id, null, 0, p_now);
  update public.speedhunts set queries_used = v_n, last_query_at = p_now where id = p_sh.id;
  update public.participants set location_request_at = p_now where id = p_sh.target_id;

  select speed_mps into v_speed from public.positions where participant_id = p_sh.target_id;
  v_in_vehicle := exists (select 1 from public.transit_sessions where participant_id = p_sh.target_id and ended_at is null)
    or coalesce(v_speed, 0) * 3.6 > public.cfg_int(v_cfg, 'transport', 'speed_threshold_kmh', 8);
  if v_in_vehicle and v_live > 0 then
    perform public.open_live_window(p_game.id, p_sh.target_id, 'fahrzeug', p_now, p_now + make_interval(secs => v_live));
  end if;

  if public.cfg_bool(v_cfg, 'speedhunt', 'notify_each_query_to_players', true) then
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_query', 'SPEEDHUNT: Abfrage ' || v_n || ' von ' || p_sh.queries_total,
      '', jsonb_build_object('speedhunt_id', p_sh.id), 'hoch');
  end if;
  perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_query',
    'Abfrage ' || v_n || '/' || p_sh.queries_total || ': ' || public.pname(p_sh.target_id),
    case when v_in_vehicle and v_live > 0 then 'Ziel ist unterwegs: ' || v_live || ' s live.' else '' end,
    jsonb_build_object('speedhunt_id', p_sh.id, 'ping_id', v_ping), 'hoch');

  if v_n >= p_sh.queries_total then
    select * into p_sh from public.speedhunts where id = p_sh.id;
    perform public.end_speedhunt(p_game, p_sh, 'abfragen_aufgebraucht', p_now);
  end if;
  return v_ping;
end; $$;

-- ---------------------------------------------------------------------------
-- Fang (7.6) und Spielende (7.19)
-- ---------------------------------------------------------------------------

create or replace function public.free_players(p_game_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.participants
  where game_id = p_game_id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall');
$$;

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
    case when v_names is null then 'Keine Sieger: die Taskforce hat gewonnen.' else 'Sieger: ' || v_names end,
    jsonb_build_object('reason', p_reason), 'hoch');
  perform public.log_game_event(p_game.id, 'game_ended', jsonb_build_object('reason', p_reason));
end; $$;

-- Gültiger Fang mit allen Folgen (7.6).
create or replace function public.apply_catch(p_game public.games, p_catch_id uuid, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_c public.catches;
  v_sh public.speedhunts;
  v_free int;
begin
  select * into v_c from public.catches where id = p_catch_id;
  update public.catches set status = 'gueltig' where id = v_c.id;
  update public.participants set state = 'gefangen', caught_at = p_now, next_ping_at = null where id = v_c.runner_id;
  for v_sh in select * from public.speedhunts where target_id = v_c.runner_id and status in ('laeuft', 'aufgeschoben', 'wartet_auf_freigabe') loop
    perform public.end_speedhunt(p_game, v_sh, 'gefangen', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where participant_id = v_c.runner_id and (ends_at is null or ends_at > p_now);
  update public.active_effects set ends_at = p_now where participant_id = v_c.runner_id and (ends_at is null or ends_at > p_now);
  update public.hideouts set status = 'verlassen', inside = false, left_at = p_now where participant_id = v_c.runner_id and status = 'aktiv';
  update public.transit_sessions set ended_at = p_now where participant_id = v_c.runner_id and ended_at is null;
  if public.cfg_bool(v_cfg, 'zone', 'release_on_catch', false) then
    update public.zones set released = true where game_id = p_game.id and kind = 'sektion' and owner_participant_id = v_c.runner_id;
  end if;
  if v_c.hunter_id is not null then
    update public.participants set bounty = bounty + public.cfg_int(v_cfg, 'taskforce', 'bounty_per_catch', 1000) where id = v_c.hunter_id;
  end if;
  if public.cfg_bool(v_cfg, 'speedhunt', 'catch_removes_one', true) then
    update public.games set speedhunts_left = greatest(0, speedhunts_left - 1) where id = p_game.id;
  end if;
  if public.cfg_text(v_cfg, 'catch', 'caught_player_becomes', 'zuschauer') = 'hunter_helfer' then
    update public.participants set role = 'hunter', state = 'aktiv' where id = v_c.runner_id;
  end if;
  v_free := public.free_players(p_game.id);
  if public.cfg_bool(v_cfg, 'catch', 'announce_to_players', true) then
    perform public.notify(p_game.id, 'alle', null, 'catch', public.pname(v_c.runner_id) || ' wurde gefangen',
      'Noch ' || v_free || ' Spieler frei.', jsonb_build_object('catch_id', v_c.id), 'hoch');
  else
    perform public.notify(p_game.id, 'taskforce', null, 'catch', public.pname(v_c.runner_id) || ' wurde gefangen',
      'Noch ' || v_free || ' Spieler frei.', jsonb_build_object('catch_id', v_c.id), 'hoch');
    perform public.notify(p_game.id, null, v_c.runner_id, 'catch', 'Du wurdest gefangen', '', '{}', 'hoch');
  end if;
  perform public.log_game_event(p_game.id, 'catch', jsonb_build_object('runner', v_c.runner_id, 'hunter', v_c.hunter_id));
  if v_free = 0 or (public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') = 'letzter_ueberlebender' and v_free <= 1) then
    select * into p_game from public.games where id = p_game.id;
    perform public.finish_game(p_game, p_now, case when v_free = 0 then 'alle_gefangen' else 'letzter_ueberlebender' end);
  end if;
end; $$;

create or replace function public.auto_catch(p_game public.games, p_runner uuid, p_reason text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.catches (game_id, runner_id, at, method, status, reason)
  values (p_game.id, p_runner, p_now, 'auto', 'gueltig', p_reason) returning id into v_id;
  perform public.apply_catch(p_game, v_id, p_now);
end; $$;

create or replace function public.disqualify(p_game public.games, p_participant uuid, p_reason text, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare v_sh public.speedhunts;
begin
  update public.participants set state = 'disqualifiziert', next_ping_at = null where id = p_participant;
  for v_sh in select * from public.speedhunts where target_id = p_participant and status in ('laeuft', 'aufgeschoben', 'wartet_auf_freigabe') loop
    perform public.end_speedhunt(p_game, v_sh, 'disqualifiziert', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where participant_id = p_participant and (ends_at is null or ends_at > p_now);
  perform public.notify(p_game.id, 'alle', null, 'disqualified', public.pname(p_participant) || ' ist disqualifiziert', p_reason, '{}', 'hoch');
  if public.free_players(p_game.id) = 0 then
    select * into p_game from public.games where id = p_game.id;
    perform public.finish_game(p_game, p_now, 'alle_ausgeschieden');
  end if;
end; $$;

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
        -- Straf-Speedhunts werden bis zum Ende des Regenerations-Jokers aufgeschoben (14.3, Regel 3).
        perform public.start_speedhunt_internal(p_game, v.participant_id, null, true, p_now, 'aufgeschoben');
      else
        perform public.start_speedhunt_internal(p_game, v.participant_id, null, true, p_now);
      end if;
      perform public.notify(p_game.id, 'gm', null, 'penalty', 'Straf-Speedhunt: ' || public.pname(v.participant_id), replace(v.type, '_', ' '), '{}', 'normal');
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

-- ---------------------------------------------------------------------------
-- Spieltag (6.4) und Jagdbeginn
-- ---------------------------------------------------------------------------

create or replace function public.grant_jokers(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_types jsonb := coalesce(v_cfg -> 'joker' -> 'types', '[]');
  v_n int := jsonb_array_length(v_types);
  v_per int := public.cfg_int(v_cfg, 'joker', 'per_day', 1);
  v_sel text := public.cfg_text(v_cfg, 'joker', 'selection', 'zufall');
  v_carry text := public.cfg_text(v_cfg, 'joker', 'carry_over', 'einen_tag');
  v_max int := public.cfg_int(v_cfg, 'joker', 'max_inventory', 2);
  v_p public.participants;
  v_t jsonb;
  v_have int;
  i int;
begin
  if not public.cfg_bool(v_cfg, 'joker', 'enabled', false) or v_n = 0 or v_per = 0 then return; end if;
  -- Aufheben: nie = alte verfallen, einen_tag = älter als gestern verfällt.
  if v_carry = 'nie' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired;
  elsif v_carry = 'einen_tag' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired
      and granted_day < p_game.current_day - 1;
  end if;
  for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall') loop
    for i in 1..v_per loop
      select count(*) into v_have from public.inventory_items where participant_id = v_p.id and kind = 'joker' and used_at is null and not expired;
      exit when v_have >= v_max;
      v_t := case v_sel
        when 'fest_pro_tag' then v_types -> ((p_game.current_day - 1) % v_n)
        when 'spieler_waehlt' then jsonb_build_object('type', 'wahl')
        else v_types -> floor(random() * v_n)::int
      end;
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
      values (p_game.id, v_p.id, 'joker', v_t ->> 'type', (v_t ->> 'minutes')::int, p_game.current_day, p_now, 'tag');
      perform public.notify(p_game.id, null, v_p.id, 'joker', 'Neuer Joker: ' || replace(v_t ->> 'type', '_', ' '),
        case when v_t ? 'minutes' then (v_t ->> 'minutes') || ' min' else '' end, '{}', 'normal');
    end loop;
  end loop;
end; $$;

create or replace function public.schedule_random_speedhunts(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_until timestamptz := coalesce(p_game.next_day_at, p_game.ends_at);
  v_times jsonb := '[]';
  i int;
begin
  if public.cfg_text(p_game.config_json, 'speedhunt', 'trigger_mode', 'taskforce') <> 'random'
     or not public.cfg_bool(p_game.config_json, 'speedhunt', 'enabled', true) then return; end if;
  for i in 1..p_game.speedhunts_left loop
    v_times := v_times || to_jsonb(p_now + (v_until - p_now) * random());
  end loop;
  update public.games set state_json = state_json || jsonb_build_object('random_speedhunts', v_times) where id = p_game.id;
end; $$;

-- Zonenprüfung für alle Spieler nach Spielfeldwechsel.
create or replace function public.recheck_zones(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_pos public.positions;
  v_p public.participants;
begin
  for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb') loop
    select * into v_pos from public.positions where participant_id = v_p.id;
    if v_pos.participant_id is not null then
      perform public.check_player_zone(p_game, v_p, v_pos.geom, p_now);
    end if;
  end loop;
end; $$;

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
  -- 1. Spieltag-Zähler
  v_next := case when v_day < v_days then public.day_start(p_game, v_day + 1) end;
  if v_next is not null and v_next >= p_game.ends_at then v_next := null; end if;
  v_left := public.speedhunt_quota(v_cfg, v_day)
    + case when public.cfg_bool(v_cfg, 'speedhunt', 'carry_over', false) then p_game.speedhunts_left else 0 end;
  update public.games set current_day = v_day, next_day_at = v_next, speedhunts_left = v_left where id = p_game.id
  returning * into p_game;

  -- 2. Neues Spielfeld
  v_changed := exists (select 1 from public.zones where game_id = p_game.id and kind = 'spielfeld' and day_index = v_day);
  if v_changed then
    if v_grace > 0 then
      update public.participants set grace_until = p_now + make_interval(mins => v_grace) where game_id = p_game.id and role = 'spieler';
    end if;
    perform public.recheck_zones(p_game, p_now);
    perform public.notify(p_game.id, 'alle', null, 'zone_active', 'Das Spielfeld hat sich geändert', 'Spieltag ' || v_day || ': neue Grenzen gelten jetzt.', '{}', 'hoch');
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
    perform public.notify(p_game.id, 'alle', null, 'day_reset', 'Neuer Spieltag: ' || v_day || ' von ' || v_days,
      case when public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then 'Speedhunts heute: ' || v_left else '' end, '{}', 'hoch');
  end if;
  if public.cfg_bool(v_cfg, 'taskforce', 'daily_briefing', false) then
    perform public.notify(p_game.id, 'taskforce', null, 'briefing', 'Einsatzbesprechung', 'Bitte trefft euch und bestätigt das Briefing.', '{}', 'normal');
  end if;
  perform public.log_game_event(p_game.id, 'day_reset', jsonb_build_object('day', v_day));
  return p_game;
end; $$;

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
  perform public.notify(p_game.id, 'alle', null, 'hunt_begin', 'Die Jagd beginnt!', 'Die Taskforce ist unterwegs.', '{}', 'hoch');
  perform public.log_game_event(p_game.id, 'hunt_begin');
  return p_game;
end; $$;

-- ---------------------------------------------------------------------------
-- Standortverarbeitung (14.2)
-- ---------------------------------------------------------------------------

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
    if public.cfg_bool(v_cfg, 'out_of_bounds', 'live_visible', true) then
      perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
    end if;
    perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb!',
      greatest(0, v_max - p_p.out_accum_s / 60) || ' min bis ' ||
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'disqualify')
        when 'catch' then 'zum Fang' when 'disqualify' then 'zur Disqualifikation' else 'zur Strafe' end || '. Die Taskforce sieht dich live.',
      '{}', 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
    perform public.notify(p_game.id, 'gm', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', '', '{}', 'normal');
  end if;
end; $$;

create or replace function public.check_transport(p_game public.games, p_p public.participants, p_point extensions.geometry, p_speed real, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_threshold int := public.cfg_int(v_cfg, 'transport', 'speed_threshold_kmh', 8);
  v_detect int := public.cfg_int(v_cfg, 'transport', 'detect_seconds', 90);
  v_in_transit boolean := exists (select 1 from public.transit_sessions where participant_id = p_p.id and ended_at is null);
  v_fast boolean := coalesce(p_speed, 0) * 3.6 > v_threshold;
  v_forbidden jsonb := coalesce(v_cfg -> 'transport' -> 'forbidden_in_zone_types', '[]');
  v_kind text;
  v_repeat int := public.cfg_int(v_cfg, 'transport', 'violation_repeat_minutes', 10);
begin
  -- Fahrzeug in verbotener Zone (z. B. center) – alle violation_repeat_minutes ein neuer Verstoss.
  if (v_in_transit or v_fast) and jsonb_array_length(v_forbidden) > 0 then
    select kind into v_kind from public.zones where game_id = p_game.id and v_forbidden ? kind and ST_Covers(geom, p_point) limit 1;
  end if;
  if v_kind is not null then
    if p_p.forbidden_since is null then
      update public.participants set forbidden_since = p_now, forbidden_last_violation_at = p_now where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'fahrzeug_verbotene_zone', jsonb_build_object('zone', v_kind), p_now);
    elsif p_now - p_p.forbidden_last_violation_at >= make_interval(mins => v_repeat) then
      update public.participants set forbidden_last_violation_at = forbidden_last_violation_at + make_interval(mins => v_repeat) where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'fahrzeug_verbotene_zone', jsonb_build_object('zone', v_kind, 'wiederholt', true), p_now);
    end if;
  elsif p_p.forbidden_since is not null then
    update public.participants set forbidden_since = null, forbidden_last_violation_at = null where id = p_p.id;
  end if;

  -- Unangemeldete Fahrt erkennen (7.9)
  if v_in_transit or not v_fast then
    if p_p.speeding_since is not null then
      update public.participants set speeding_since = null, transport_prompted_at = null where id = p_p.id;
    end if;
    return;
  end if;
  if not public.cfg_bool(v_cfg, 'transport', 'checkin_required', true) then return; end if;
  if p_p.speeding_since is null then
    update public.participants set speeding_since = p_now where id = p_p.id;
  elsif p_p.transport_prompted_at is null and p_now - p_p.speeding_since >= make_interval(secs => v_detect) then
    update public.participants set transport_prompted_at = p_now where id = p_p.id;
    perform public.notify(p_game.id, null, p_p.id, 'transport_prompt', 'Fährst du?', 'Du bist schnell unterwegs. Jetzt Transport anmelden!', '{}', 'hoch');
    perform public.notify(p_game.id, 'gm', null, 'transport_prompt', 'Transport-Verdacht: ' || public.pname(p_p.id), '', '{}', 'normal');
  elsif p_p.transport_prompted_at is not null and p_now - p_p.transport_prompted_at >= interval '2 minutes' then
    update public.participants set speeding_since = null, transport_prompted_at = null where id = p_p.id;
    perform public.create_violation(p_game, p_p.id, 'oev_nicht_angemeldet',
      jsonb_build_object('speed_kmh', round((p_speed * 3.6)::numeric, 1), 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
  end if;
end; $$;

create or replace function public.check_hideout(p_game public.games, p_p public.participants, p_point extensions.geometry, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_h public.hideouts;
  v_radius int := public.cfg_int(v_cfg, 'hideout', 'stationary_radius_m', 40);
  v_minutes int := public.cfg_int(v_cfg, 'hideout', 'stationary_minutes', 20);
  v_leave int := public.cfg_int(v_cfg, 'hideout', 'min_leave_distance_m', 200);
  v_detection text := public.cfg_text(v_cfg, 'hideout', 'detection', 'beides');
begin
  if not public.cfg_bool(v_cfg, 'hideout', 'enabled', true) then return; end if;
  select * into v_h from public.hideouts where participant_id = p_p.id and status = 'aktiv' limit 1;
  if v_h.id is not null then
    -- Versteck gilt erst als verlassen, wenn der Mindestabstand erreicht ist (7.8).
    if public.dist_m(v_h.center, p_point) > v_leave then
      update public.hideouts set status = 'verlassen', inside = false, left_at = p_now where id = v_h.id;
      perform public.notify(p_game.id, null, p_p.id, 'hideout_left', 'Versteck verlassen', 'Mindestabstand erreicht.', '{}', 'normal');
    elsif v_h.inside and public.dist_m(v_h.center, p_point) > greatest(v_radius * 2, 60) then
      update public.hideouts set inside = false where id = v_h.id;
    end if;
    return;
  end if;
  if v_detection = 'selbstmeldung' then return; end if;
  -- Automatische Erkennung: Stillstand innerhalb des Radius (7.8)
  if p_p.stationary_center is null or public.dist_m(p_p.stationary_center, p_point) > v_radius then
    update public.participants set stationary_center = p_point, stationary_since = p_now, hideout_prompted_at = null where id = p_p.id;
  elsif p_p.hideout_prompted_at is null and p_now - p_p.stationary_since >= make_interval(mins => v_minutes) then
    update public.participants set hideout_prompted_at = p_now where id = p_p.id;
    perform public.notify(p_game.id, null, p_p.id, 'hideout_prompt', 'Bist du verschanzt?',
      'Du bist seit ' || v_minutes || ' min am selben Ort. Bist du in einem nicht öffentlichen Ort (Wohnung, Haus)?',
      jsonb_build_object('since', p_p.stationary_since), 'hoch');
  end if;
end; $$;

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
          'Die Taskforce wurde alarmiert.', jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'name', public.pname(v_pair.b_id)), 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Teambildung: ' || public.pname(v_pair.a_id) || ' ist in der Nähe',
          'Die Taskforce wurde alarmiert.', jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'name', public.pname(v_pair.a_id)), 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.alerted then
      update public.proximity_pairs set alerted = false where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;

create or replace function public.process_location(p_game public.games, p_p public.participants, p_point extensions.geometry, p_speed real, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_hq public.zones;
  v_exit public.zones;
begin
  if p_game.status = 'vorsprung' and p_p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'start', 'hunters_must_stay_in_hq', true) then
    select * into v_hq from public.zones where game_id = p_game.id and kind = 'hq' limit 1;
    if v_hq.id is not null and public.dist_m(v_hq.geom, p_point) > coalesce(v_hq.radius_m, public.cfg_int(v_cfg, 'start', 'hq_radius_m', 100)) + public.cfg_int(v_cfg, 'zone', 'edge_tolerance_m', 25)
       and not exists (select 1 from public.violations where participant_id = p_p.id and type = 'hunter_hq') then
      perform public.create_violation(p_game, p_p.id, 'hunter_hq', jsonb_build_object('lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
    return;
  end if;

  if p_p.role <> 'spieler' or p_game.status not in ('laeuft', 'finale') then return; end if;
  if p_p.state not in ('aktiv', 'ausserhalb') then return; end if;

  perform public.check_player_zone(p_game, p_p, p_point, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_transport(p_game, p_p, p_point, p_speed, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_hideout(p_game, p_p, p_point, p_now);

  -- Exitpoint (7.19)
  if p_game.exit_revealed and p_game.exit_zone_id is not null and public.cfg_text(v_cfg, 'exit', 'confirm', 'geofence') = 'geofence'
     and p_now <= p_game.deadline_at then
    select * into v_exit from public.zones where id = p_game.exit_zone_id;
    if public.dist_m(v_exit.geom, p_point) <= coalesce(v_exit.radius_m, public.cfg_int(v_cfg, 'exit', 'radius_m', 30)) then
      perform public.reach_exit(p_game, p_p.id, p_now);
    end if;
  end if;
end; $$;

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
  perform public.notify(p_game.id, null, p_participant, 'exit_reached', 'Geschafft!', 'Du bist am Exitpoint und in Sicherheit.', '{}', 'hoch');
  perform public.notify(p_game.id, 'alle', null, 'exit_reached', public.pname(p_participant) || ' hat den Exitpoint erreicht', '', '{}', 'normal');
  if public.free_players(p_game.id) = 0 then
    select * into p_game from public.games where id = p_game.id;
    perform public.finish_game(p_game, p_now, 'alle_im_ziel_oder_gefangen');
  end if;
end; $$;

-- ---------------------------------------------------------------------------
-- Tick: alle Timer eines Spiels (14.1). Reihenfolge nach 14.3, Regel 9.
-- ---------------------------------------------------------------------------

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

  -- Ankündigung der Spielfeldänderung
  v_announce := public.cfg_int(v_cfg, 'zone', 'shrink_announce_minutes', 180);
  if g.next_day_at is not null and g.next_day_at - make_interval(mins => v_announce) <= v_now
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
        'Die Taskforce kennt deinen Ort. Verlass ihn sofort.', '{}', 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'hotel_end', 'Hotel-Ping: ' || public.pname(v_e.participant_id), '', '{}', 'hoch');
    elsif v_e.type in ('regeneration', 'catch_free', 'leo') then
      perform public.notify(g.id, null, v_e.participant_id, 'effect_end',
        case v_e.type when 'regeneration' then 'Regeneration vorbei' when 'catch_free' then 'Catch-Free vorbei' else 'LEO vorbei' end,
        '', '{}', 'normal');
    end if;
  end loop;
  -- Aufgeschobene Straf-Speedhunts starten, sobald keine Regeneration mehr läuft.
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
      -- Auto-Spielleitung: gültig, wenn der GPS-Abstand passt (7.6).
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

  -- Exitpoint bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now and g.exit_zone_id is not null then
    update public.zones set visible_from = v_now,
      visible_to = case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end
    where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1,
      state_json = state_json || jsonb_build_object('exit_taskforce_at', case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig')
        when 'verzoegert' then to_jsonb(v_now + interval '15 minutes') else null end)
    where id = g.id returning * into g;
    perform public.notify(g.id, case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end,
      null, 'exit_reveal', 'Exitpoint bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
    if public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') <> 'gleichzeitig' then
      perform public.notify(g.id, 'gm', null, 'exit_reveal', 'Exitpoint an Spieler bekanntgegeben', '', '{}', 'normal');
    end if;
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
  end if;
  if g.state_json ? 'exit_taskforce_at' and jsonb_typeof(g.state_json -> 'exit_taskforce_at') = 'string'
     and (g.state_json ->> 'exit_taskforce_at')::timestamptz <= v_now then
    update public.zones set visible_to = 'alle' where id = g.exit_zone_id;
    update public.games set state_json = state_json - 'exit_taskforce_at', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Exitpoint bekannt', 'Siehe Karte.', '{}', 'kritisch');
  end if;

  -- Spielende
  if v_now >= g.ends_at and not coalesce((g.state_json ->> 'end_notified')::boolean, false) and public.cfg_bool(v_cfg, 'exit', 'enabled', true)
     and g.deadline_at > g.ends_at then
    update public.games set state_json = state_json || '{"end_notified": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'alle', null, 'time_up', 'Spielzeit vorbei', 'Ankunft am Exitpoint noch bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
  end if;
  if v_now >= g.deadline_at then
    perform public.finish_game(g, v_now, 'zeit_abgelaufen');
  end if;

  update public.games set last_tick_at = v_now where id = g.id;
  perform public.bump(g.id);
end; $$;

create or replace function public.recheck_exit(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_exit public.zones;
  v_p record;
begin
  if public.cfg_text(p_game.config_json, 'exit', 'confirm', 'geofence') <> 'geofence' then return; end if;
  select * into v_exit from public.zones where id = p_game.exit_zone_id;
  for v_p in select p.id from public.participants p join public.positions pos on pos.participant_id = p.id
             where p.game_id = p_game.id and p.role = 'spieler' and p.state in ('aktiv', 'ausserhalb')
               and public.dist_m(v_exit.geom, pos.geom) <= coalesce(v_exit.radius_m, 30) loop
    perform public.reach_exit(p_game, v_p.id, p_now);
  end loop;
end; $$;

create or replace function public.engine_tick_all()
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  for v_id in select id from public.games where status in ('vorsprung', 'laeuft', 'finale') and paused_at is null loop
    begin
      perform public.tick_game(v_id);
    exception when others then
      perform public.log_game_event(v_id, 'tick_error', jsonb_build_object('error', sqlerrm));
    end;
  end loop;
end; $$;

-- Interne Funktionen nicht über die API aufrufbar machen.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'pt', 'dist_m', 'spielfeld_day', 'allowed_area', 'zone_kind_at', 'ping_interval_at', 'next_ping_time', 'day_start',
      'speedhunt_quota', 'in_quiet_hours', 'best_position', 'create_ping', 'schedule_next_ping', 'running_speedhunt_on', 'process_ping_due',
      'default_penalty', 'create_violation', 'start_speedhunt_internal', 'end_speedhunt', 'speedhunt_query_internal',
      'free_players', 'finish_game', 'apply_catch', 'auto_catch', 'disqualify', 'apply_penalty', 'grant_jokers',
      'schedule_random_speedhunts', 'recheck_zones', 'day_reset', 'hunt_begin', 'check_player_zone', 'check_transport',
      'check_hideout', 'check_proximity', 'process_location', 'reach_exit', 'tick_game', 'recheck_exit', 'engine_tick_all',
      'bump', 'notify', 'open_live_window', 'close_live_windows', 'has_effect', 'has_live_window', 'cfg_int', 'cfg_bool', 'cfg_text'
    )
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- ===== 0005_aktionen.sql =====

-- Schritt 3 bis 8: Aktionen der Teilnehmenden (Kapitel 7, 9, 10).
-- Jede Aktion prüft Rolle, Spielstatus und Regeln serverseitig.

-- ---------------------------------------------------------------------------
-- Hilfen
-- ---------------------------------------------------------------------------

create or replace function public.require_participant(p_game_id uuid, p_roles text[] default null)
returns public.participants language plpgsql stable security definer set search_path = public as $$
declare v public.participants;
begin
  select * into v from public.participants where game_id = p_game_id and user_id = auth.uid();
  if v.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if p_roles is not null and not (v.role = any (p_roles)) then
    raise exception 'Das darf deine Rolle nicht.' using errcode = '42501';
  end if;
  return v;
end; $$;

create or replace function public.require_running(p_game_id uuid, p_allow_vorsprung boolean default false)
returns public.games language plpgsql stable security definer set search_path = public as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if g.status = 'beendet' then raise exception 'Das Spiel ist beendet.' using errcode = 'P0001'; end if;
  if g.paused_at is not null then raise exception 'Das Spiel ist pausiert.' using errcode = 'P0001'; end if;
  if g.status not in ('laeuft', 'finale') and not (p_allow_vorsprung and g.status = 'vorsprung') then
    raise exception 'Das Spiel läuft noch nicht.' using errcode = 'P0001';
  end if;
  return g;
end; $$;

create or replace function public.is_game_leader(p_game_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_game_host(p_game_id) or public.is_game_gm(p_game_id);
$$;

-- ---------------------------------------------------------------------------
-- Spielstart (6.3)
-- ---------------------------------------------------------------------------

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
    raise exception 'Setze mindestens einen Exitpoint-Kandidaten auf der Karte (oder schalte den Exitpoint aus).' using errcode = 'P0001';
  end if;

  -- Exitpoint auswählen (zufällig oder der erste Kandidat)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    select id into v_exit from public.zones where game_id = p_game_id and kind = 'exit'
    order by case when public.cfg_bool(v_cfg, 'exit', 'random_from_candidates', true) then random() else 0 end, created_at limit 1;
    -- Nicht gewählte Kandidaten bleiben für immer verborgen.
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit' and id <> v_exit;
    update public.zones set visible_to = 'gm' where id = v_exit;
  end if;

  -- Automatische Verkleinerung: Spielfeld je Tag um x % (Fläche) um den Exit bzw. Mittelpunkt (7.1).
  v_days := public.cfg_int(v_cfg, 'game', 'days', 4);
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
        values (p_game_id, 'spielfeld', 'Spielfeld Tag ' || v_d,
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
  -- Zukünftige Spielfelder werden zur Ankündigungszeit sichtbar
  for v_z in select * from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index > 1 loop
    update public.zones set visible_from = public.day_start(g, v_z.day_index) - make_interval(mins => public.cfg_int(v_cfg, 'zone', 'shrink_announce_minutes', 180))
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

-- Probelauf: Spielzeit vorspulen (22.6). Nur in Testspielen.
create or replace function public.advance_time(p_game_id uuid, p_minutes int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_step int;
  v_left int := p_minutes;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
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

-- Client-Tick: hält das Spiel in Bewegung, auch wenn pg_cron fehlt.
create or replace function public.game_tick(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_game_member(p_game_id) then return; end if;
  perform public.tick_game(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Standort (14.2)
-- p_samples: [{lat, lng, acc, speed, heading, age_s, battery, mock}]
-- ---------------------------------------------------------------------------

create or replace function public.report_location(p_game_id uuid, p_samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_p public.participants;
  g public.games;
  v_now timestamptz;
  s jsonb;
  v_last jsonb;
  v_at timestamptz;
  v_last_at timestamptz;
  v_geom extensions.geometry;
  v_battery int;
  v_warn int;
begin
  v_p := public.require_participant(p_game_id);
  select * into g from public.games where id = p_game_id;
  if g.status in ('beendet', 'archiviert') then return jsonb_build_object('stop', true); end if;
  if v_p.role in ('zuschauer') or (v_p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren')
     and not public.cfg_bool(g.config_json, 'catch', 'track_after_catch', false) and v_p.role = 'spieler') then
    return jsonb_build_object('stop', true);
  end if;
  v_now := public.engine_now(p_game_id);
  for s in select * from jsonb_array_elements(coalesce(p_samples, '[]')) order by coalesce((value ->> 'age_s')::int, 0) desc loop
    if (s ->> 'lat') is null or (s ->> 'lng') is null then continue; end if;
    v_at := v_now - make_interval(secs => least(greatest(coalesce((s ->> 'age_s')::int, 0), 0), 3600));
    v_geom := public.pt((s ->> 'lat')::double precision, (s ->> 'lng')::double precision);
    insert into public.location_samples (game_id, participant_id, at, geom, accuracy_m, speed_mps, heading, battery, is_mock)
    values (p_game_id, v_p.id, v_at, v_geom, (s ->> 'acc')::real, (s ->> 'speed')::real, (s ->> 'heading')::real,
            (s ->> 'battery')::int, coalesce((s ->> 'mock')::boolean, false));
    if v_last_at is null or v_at >= v_last_at then v_last := s; v_last_at := v_at; end if;
  end loop;
  if v_last is null then return jsonb_build_object('ok', false); end if;
  if coalesce((v_last ->> 'mock')::boolean, false) then
    perform public.notify(p_game_id, 'gm', null, 'mock_location', 'Verdacht Standort-Fälschung: ' || public.pname(v_p.id), '', '{}', 'hoch');
  end if;

  v_geom := public.pt((v_last ->> 'lat')::double precision, (v_last ->> 'lng')::double precision);
  insert into public.positions (participant_id, game_id, geom, lat, lng, accuracy_m, speed_mps, heading, at)
  values (v_p.id, p_game_id, v_geom, (v_last ->> 'lat')::double precision, (v_last ->> 'lng')::double precision,
          (v_last ->> 'acc')::real, (v_last ->> 'speed')::real, (v_last ->> 'heading')::real, v_last_at)
  on conflict (participant_id) do update set geom = excluded.geom, lat = excluded.lat, lng = excluded.lng,
    accuracy_m = excluded.accuracy_m, speed_mps = excluded.speed_mps, heading = excluded.heading, at = excluded.at, received_at = now()
  where positions.at <= excluded.at;

  v_battery := (v_last ->> 'battery')::int;
  v_warn := public.cfg_int(g.config_json, 'safety', 'battery_warn_percent', 25);
  update public.participants set last_seen_at = v_now, battery = coalesce(v_battery, battery),
    location_request_at = case when location_request_at is not null and location_request_at <= v_last_at then null else location_request_at end
  where id = v_p.id returning * into v_p;
  if v_battery is not null and v_battery <= v_warn and coalesce(v_p.battery_warned, 100) > v_warn and g.status in ('vorsprung', 'laeuft', 'finale') then
    update public.participants set battery_warned = v_battery where id = v_p.id;
    perform public.notify(p_game_id, null, v_p.id, 'battery', 'Akku niedrig (' || v_battery || ' %)', 'Powerbank anschliessen!', '{}', 'hoch');
    perform public.notify(p_game_id, 'gm', null, 'battery', 'Akku niedrig: ' || public.pname(v_p.id), v_battery || ' %', '{}', 'normal');
  elsif v_battery is not null and v_battery > v_warn + 5 then
    update public.participants set battery_warned = null where id = v_p.id;
  end if;

  if g.status in ('vorsprung', 'laeuft', 'finale') and g.paused_at is null then
    perform public.process_location(g, v_p, v_geom, (v_last ->> 'speed')::real, v_now);
    perform public.tick_game(p_game_id);
  end if;
  select * into v_p from public.participants where id = v_p.id;
  return jsonb_build_object('ok', true, 'request_now', v_p.location_request_at is not null,
    'interval_s', case when public.has_live_window(v_p.id, v_now) or v_p.location_request_at is not null then 5
                       else public.cfg_int(g.config_json, 'tracking', 'sample_interval_seconds', 15) end);
end; $$;

-- Gerätecheck in der Lobby (6.2)
create or replace function public.set_device_check(p_game_id uuid, p_checks jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.participants;
begin
  v_p := public.require_participant(p_game_id);
  update public.participants set device_check = coalesce(p_checks, '{}') || jsonb_build_object('at', now()),
    battery = coalesce((p_checks ->> 'battery')::int, battery)
  where id = v_p.id;
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Speedhunt (7.4)
-- ---------------------------------------------------------------------------

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
  if not public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then raise exception 'Speedhunts sind ausgeschaltet.' using errcode = 'P0001'; end if;
  if v_mode = 'random' then raise exception 'Speedhunts starten in diesem Spiel zufällig.' using errcode = 'P0001'; end if;
  if v_mode = 'gm' and v_me.role <> 'gm' then raise exception 'Nur die Spielleitung startet Speedhunts.' using errcode = '42501'; end if;
  if public.in_quiet_hours(g, v_now) then raise exception 'Jagdfreie Zeit.' using errcode = 'P0001'; end if;
  if g.speedhunts_left <= 0 then raise exception 'Kein Speedhunt mehr übrig heute.' using errcode = 'P0001'; end if;
  if (select count(*) from public.speedhunts where game_id = p_game_id and status = 'laeuft' and not is_penalty)
     >= public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) then
    raise exception 'Schon % Speedhunts gleichzeitig.', public.cfg_int(v_cfg, 'speedhunt', 'max_parallel', 2) using errcode = 'P0001';
  end if;
  select * into v_t from public.participants where id = p_target and game_id = p_game_id;
  if v_t.id is null or v_t.role <> 'spieler' or v_t.state not in ('aktiv', 'ausserhalb') then
    raise exception 'Dieses Ziel kann nicht gejagt werden.' using errcode = 'P0001';
  end if;
  if (public.running_speedhunt_on(p_target)).id is not null then raise exception 'Auf dieses Ziel läuft schon ein Speedhunt.' using errcode = 'P0001'; end if;
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
    raise exception 'Dieses Ziel hatte heute schon genug Speedhunts.' using errcode = 'P0001';
  end if;
  v_min_after := public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0);
  if v_min_after > 0 and public.cfg_text(v_cfg, 'speedhunt', 'early_start_policy', 'silent_zaehlt_als_abfrage') = 'verbieten'
     and v_t.last_silent_ping_at > v_now - make_interval(mins => v_min_after) then
    raise exception 'Erst % min nach dem letzten Silent-Ping möglich.', v_min_after using errcode = 'P0001';
  end if;

  update public.games set speedhunts_left = speedhunts_left - 1 where id = p_game_id;
  if public.cfg_bool(v_cfg, 'speedhunt', 'gm_approval', false) and v_me.role <> 'gm' then
    v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now, 'wartet_auf_freigabe');
    perform public.notify(p_game_id, 'gm', null, 'speedhunt_approval', 'Speedhunt freigeben?', public.pname(p_target), jsonb_build_object('speedhunt_id', v_sh.id), 'hoch');
  else
    v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now);
  end if;
  perform public.log_game_event(p_game_id, 'speedhunt_start', jsonb_build_object('target', p_target, 'by', v_me.id));
  perform public.bump(p_game_id);
  return v_sh.id;
end; $$;

create or replace function public.speedhunt_approve(p_speedhunt_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_sh public.speedhunts;
  g public.games;
  v_now timestamptz;
begin
  select * into v_sh from public.speedhunts where id = p_speedhunt_id;
  perform public.require_participant(v_sh.game_id, array['gm']);
  if v_sh.status <> 'wartet_auf_freigabe' then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  g := public.require_running(v_sh.game_id);
  v_now := public.engine_now(g.id);
  update public.speedhunts set status = 'beendet', ended_at = v_now, end_reason = case when p_approve then 'freigegeben' else 'abgelehnt' end where id = v_sh.id;
  if p_approve then
    perform public.start_speedhunt_internal(g, v_sh.target_id, v_sh.triggered_by, false, v_now);
  else
    update public.games set speedhunts_left = speedhunts_left + 1 where id = g.id;
    perform public.notify(g.id, 'taskforce', null, 'speedhunt_rejected', 'Speedhunt abgelehnt', 'Die Spielleitung hat nicht freigegeben.', '{}', 'normal');
  end if;
  perform public.bump(g.id);
end; $$;

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
  if v_sh.id is null then raise exception 'Speedhunt nicht gefunden.' using errcode = 'P0001'; end if;
  perform public.require_participant(v_sh.game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(v_sh.game_id);
  v_now := public.engine_now(g.id);
  if v_sh.status <> 'laeuft' then raise exception 'Der Speedhunt läuft nicht.' using errcode = 'P0001'; end if;
  v_gap := public.cfg_int(g.config_json, 'speedhunt', 'query_min_gap_minutes', 0);
  if v_gap > 0 and v_sh.last_query_at > v_now - make_interval(mins => v_gap) then
    raise exception 'Nächste Abfrage erst um %.', to_char((v_sh.last_query_at + make_interval(mins => v_gap)) at time zone g.timezone, 'HH24:MI') using errcode = 'P0001';
  end if;
  v_id := public.speedhunt_query_internal(g, v_sh, v_now);
  perform public.bump(g.id);
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Fang (7.6)
-- ---------------------------------------------------------------------------

create or replace function public.catch_code_at(p_secret text, p_window bigint)
returns text language sql immutable as $$
  select lpad((abs(hashtextextended(p_secret || ':' || p_window, 7)) % 1000000)::text, 6, '0');
$$;

create or replace function public.my_catch_code(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_p public.participants;
  v_epoch bigint := floor(extract(epoch from now()));
begin
  v_p := public.require_participant(p_game_id, array['spieler']);
  return jsonb_build_object('code', public.catch_code_at(v_p.catch_secret, v_epoch / 30),
    'valid_s', 30 - (v_epoch % 30), 'qr', 'HM:' || public.catch_code_at(v_p.catch_secret, v_epoch / 30));
end; $$;

create or replace function public.catch_blocked_reason(g public.games, p_runner public.participants, p_now timestamptz)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare v_pos public.positions;
begin
  if g.status = 'vorsprung' then return 'Während des Vorsprungs darf nicht gefangen werden.'; end if;
  if p_runner.state not in ('aktiv', 'ausserhalb') then return 'Diese Person ist nicht mehr im Spiel.'; end if;
  if public.in_quiet_hours(g, p_now) then return 'Jagdfreie Zeit.'; end if;
  if public.has_effect(p_runner.id, 'catch_free', p_now) then return 'Catch-Free-Joker aktiv: kein Fang möglich.'; end if;
  if public.has_effect(p_runner.id, 'hotel', p_now) then return 'Spieler ist im Hotel geschützt.'; end if;
  select * into v_pos from public.positions where participant_id = p_runner.id;
  if v_pos.participant_id is not null and exists (select 1 from public.zones where game_id = g.id and kind = 'sicher' and ST_Covers(geom, v_pos.geom)) then
    return 'Spieler ist in einer sicheren Zone.';
  end if;
  return null;
end; $$;

create or replace function public.register_catch(g public.games, p_hunter public.participants, p_runner public.participants,
  p_method text, p_lat double precision, p_lng double precision, p_now timestamptz)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := g.config_json;
  v_block text;
  v_rpos public.positions;
  v_dist double precision;
  v_id uuid;
begin
  v_block := public.catch_blocked_reason(g, p_runner, p_now);
  if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
  select * into v_rpos from public.positions where participant_id = p_runner.id;
  if p_lat is not null and v_rpos.participant_id is not null then
    v_dist := public.dist_m(public.pt(p_lat, p_lng), v_rpos.geom);
    if v_dist > public.cfg_int(v_cfg, 'catch', 'max_distance_m', 30) + coalesce(v_rpos.accuracy_m, 0) + 30 and p_method <> 'gm' then
      raise exception 'GPS-Abstand zu gross (% m). Geh näher ran.', round(v_dist) using errcode = 'P0001';
    end if;
  end if;
  insert into public.catches (game_id, runner_id, hunter_id, at, lat, lng, method, distance_m, status, expires_at)
  values (g.id, p_runner.id, p_hunter.id, p_now, p_lat, p_lng, p_method, v_dist,
    case when public.cfg_bool(v_cfg, 'catch', 'require_media', false) and p_method <> 'gm' then 'wartet_auf_beweis'
         when p_method = 'touch_confirm' then 'wartet_auf_bestaetigung' else 'gueltig' end,
    case when public.cfg_bool(v_cfg, 'catch', 'require_media', false) and p_method <> 'gm' then p_now + interval '2 minutes'
         when p_method = 'touch_confirm' then p_now + make_interval(secs => public.cfg_int(v_cfg, 'catch', 'confirm_seconds', 60)) end)
  returning id into v_id;
  if public.cfg_bool(v_cfg, 'catch', 'require_media', false) and p_method <> 'gm' then
    perform public.notify(g.id, null, p_hunter.id, 'catch_proof', 'Beweis hochladen', 'Foto oder Video innerhalb von 2 min.', jsonb_build_object('catch_id', v_id), 'hoch');
    perform public.notify(g.id, null, p_runner.id, 'catch_pending', 'Fang wird geprüft', public.pname(p_hunter.id) || ' meldet deinen Fang.', jsonb_build_object('catch_id', v_id), 'kritisch');
  elsif p_method = 'touch_confirm' then
    perform public.notify(g.id, null, p_runner.id, 'catch_confirm', 'Wurdest du gefangen?', public.pname(p_hunter.id) || ' meldet einen Fang. Bitte bestätigen.',
      jsonb_build_object('catch_id', v_id), 'kritisch');
  else
    perform public.apply_catch(g, v_id, p_now);
  end if;
  perform public.bump(g.id);
  return jsonb_build_object('catch_id', v_id, 'status', (select status from public.catches where id = v_id), 'runner', public.pname(p_runner.id));
end; $$;

create or replace function public.catch_by_code(p_game_id uuid, p_code text, p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_r public.participants;
  v_code text := regexp_replace(coalesce(p_code, ''), '^HM:', '');
  v_w bigint := floor(extract(epoch from now()) / 30);
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale']);
  g := public.require_running(p_game_id, true);
  select * into v_r from public.participants
  where game_id = p_game_id and role = 'spieler'
    and (public.catch_code_at(catch_secret, v_w) = v_code or public.catch_code_at(catch_secret, v_w - 1) = v_code)
  limit 1;
  if v_r.id is null then raise exception 'Code ungültig oder abgelaufen.' using errcode = 'P0001'; end if;
  return public.register_catch(g, v_me, v_r, 'qr', p_lat, p_lng, public.engine_now(p_game_id));
end; $$;

create or replace function public.catch_claim(p_game_id uuid, p_runner uuid, p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_r public.participants;
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(p_game_id, true);
  select * into v_r from public.participants where id = p_runner and game_id = p_game_id and role = 'spieler';
  if v_r.id is null then raise exception 'Spieler nicht gefunden.' using errcode = 'P0001'; end if;
  return public.register_catch(g, v_me, v_r, case when v_me.role = 'gm' then 'gm' else 'touch_confirm' end, p_lat, p_lng, public.engine_now(p_game_id));
end; $$;

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
      perform public.notify(g.id, null, v_c.hunter_id, 'catch_disputed', 'Fang bestritten', 'Die Spielleitung entscheidet.', '{}', 'hoch');
      if public.cfg_text(g.config_json, 'roles', 'gm_mode', 'auto') = 'auto' then
        -- Ohne menschliche Spielleitung entscheidet der GPS-Abstand sofort.
        update public.catches set expires_at = public.engine_now(g.id) where id = v_c.id;
        perform public.tick_game(g.id);
      end if;
    end if;
  elsif v_me.role = 'gm' then
    if p_accept then perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
    else update public.catches set status = 'abgelehnt', reason = 'Spielleitung' where id = v_c.id; end if;
  else
    raise exception 'Nur die gefangene Person oder die Spielleitung.' using errcode = '42501';
  end if;
  perform public.bump(g.id);
end; $$;

create or replace function public.catch_attach_media(p_catch_id uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.catches;
  v_me public.participants;
  g public.games;
begin
  select * into v_c from public.catches where id = p_catch_id;
  v_me := public.require_participant(v_c.game_id);
  if v_me.id <> v_c.hunter_id then raise exception 'Nur wer gefangen hat.' using errcode = '42501'; end if;
  if v_c.status <> 'wartet_auf_beweis' then raise exception 'Kein Beweis nötig.' using errcode = 'P0001'; end if;
  select * into g from public.games where id = v_c.game_id;
  update public.catches set media_path = p_path where id = v_c.id;
  perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
  perform public.bump(g.id);
end; $$;

create or replace function public.gm_catch_decide(p_catch_id uuid, p_valid boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.catches;
  g public.games;
begin
  select * into v_c from public.catches where id = p_catch_id;
  perform public.require_participant(v_c.game_id, array['gm']);
  select * into g from public.games where id = v_c.game_id;
  if p_valid and v_c.status <> 'gueltig' then
    perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
  elsif not p_valid and v_c.status = 'gueltig' then
    -- Fang annullieren: Person kommt zurück ins Spiel.
    update public.catches set status = 'annulliert' where id = v_c.id;
    update public.participants set state = 'aktiv', caught_at = null, role = 'spieler' where id = v_c.runner_id;
    perform public.schedule_next_ping(g, v_c.runner_id, public.engine_now(g.id));
    if v_c.hunter_id is not null then
      update public.participants set bounty = greatest(0, bounty - public.cfg_int(g.config_json, 'taskforce', 'bounty_per_catch', 1000)) where id = v_c.hunter_id;
    end if;
    perform public.notify(g.id, 'alle', null, 'catch_annulled', 'Fang annulliert', public.pname(v_c.runner_id) || ' ist wieder im Spiel.', '{}', 'hoch');
  elsif not p_valid then
    update public.catches set status = 'abgelehnt', reason = 'Spielleitung' where id = v_c.id;
  end if;
  perform public.bump(g.id);
end; $$;

-- ---------------------------------------------------------------------------
-- Exit per QR oder Spielleitung, Aufgeben
-- ---------------------------------------------------------------------------

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
  if not g.exit_revealed then raise exception 'Der Exitpoint ist noch nicht bekannt.' using errcode = 'P0001'; end if;
  if v_me.role = 'gm' and p_participant is not null then
    perform public.reach_exit(g, p_participant, public.engine_now(p_game_id));
  elsif v_me.role = 'spieler' then
    select * into v_exit from public.zones where id = g.exit_zone_id;
    select * into v_pos from public.positions where participant_id = v_me.id;
    if v_pos.participant_id is null or public.dist_m(v_exit.geom, v_pos.geom) > coalesce(v_exit.radius_m, 30) + coalesce(v_pos.accuracy_m, 0) + 20 then
      raise exception 'Du bist noch nicht am Exitpoint.' using errcode = 'P0001';
    end if;
    perform public.reach_exit(g, v_me.id, public.engine_now(p_game_id));
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
  perform public.bump(p_game_id);
end; $$;

create or replace function public.give_up(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id, array['spieler']);
  g := public.require_running(p_game_id, true);
  update public.participants set state = 'aufgegeben', next_ping_at = null where id = v_me.id and state in ('aktiv', 'ausserhalb', 'notfall');
  perform public.close_live_windows(v_me.id, 'ausserhalb', public.engine_now(p_game_id));
  perform public.notify(p_game_id, 'alle', null, 'give_up', public.pname(v_me.id) || ' hat aufgegeben', '', '{}', 'hoch');
  if public.free_players(p_game_id) = 0 then
    perform public.finish_game(g, public.engine_now(p_game_id), 'alle_ausgeschieden');
  end if;
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Verschanzen (7.8)
-- ---------------------------------------------------------------------------

create or replace function public.hideout_report(p_game_id uuid, p_inside boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_pos public.positions;
  v_h public.hideouts;
  v_prev public.hideouts;
  v_lock int;
  v_first timestamptz;
begin
  v_me := public.require_participant(p_game_id, array['spieler']);
  g := public.require_running(p_game_id);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  if not public.cfg_bool(v_cfg, 'hideout', 'enabled', true) then raise exception 'Verschanzen-Regel ist aus.' using errcode = 'P0001'; end if;
  select * into v_pos from public.positions where participant_id = v_me.id;
  select * into v_h from public.hideouts where participant_id = v_me.id and status = 'aktiv';
  if not p_inside then
    if v_h.id is not null then update public.hideouts set inside = false where id = v_h.id; end if;
    update public.participants set hideout_prompted_at = v_now, stationary_since = v_now where id = v_me.id;
    perform public.bump(p_game_id);
    return jsonb_build_object('inside', false);
  end if;
  if v_pos.participant_id is null then raise exception 'Noch kein Standort.' using errcode = 'P0001'; end if;
  if v_h.id is not null then
    update public.hideouts set inside = true where id = v_h.id;
  else
    -- Sperre: derselbe Ort darf nach lockout_after_first_entry_minutes nicht mehr genutzt werden.
    v_lock := public.cfg_int(v_cfg, 'hideout', 'lockout_after_first_entry_minutes', 480);
    select * into v_prev from public.hideouts where participant_id = v_me.id
      and public.dist_m(center, v_pos.geom) <= public.cfg_int(v_cfg, 'hideout', 'min_leave_distance_m', 200)
    order by first_entered_at limit 1;
    v_first := coalesce(v_prev.first_entered_at, case when v_me.stationary_since is not null and v_me.stationary_center is not null
      and public.dist_m(v_me.stationary_center, v_pos.geom) <= public.cfg_int(v_cfg, 'hideout', 'stationary_radius_m', 40) then v_me.stationary_since end, v_now);
    insert into public.hideouts (game_id, participant_id, center, first_entered_at, entered_at, accum_s, detection)
    values (p_game_id, v_me.id, v_pos.geom, v_first, v_now,
            coalesce(v_prev.accum_s, 0) + case when v_prev.id is null and v_first < v_now then extract(epoch from (v_now - v_first))::int else 0 end,
            case when v_me.hideout_prompted_at is not null then 'automatisch' else 'selbstmeldung' end)
    returning * into v_h;
    if v_lock > 0 and v_prev.id is not null and v_now - v_prev.first_entered_at > make_interval(mins => v_lock) then
      perform public.create_violation(g, v_me.id, 'versteck_gesperrt', jsonb_build_object('erstmals', v_prev.first_entered_at), v_now);
    end if;
  end if;
  update public.participants set hideout_prompted_at = null where id = v_me.id;
  perform public.bump(p_game_id);
  return jsonb_build_object('inside', true, 'remaining_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60 - v_h.accum_s);
end; $$;

-- ---------------------------------------------------------------------------
-- ÖV (7.9)
-- ---------------------------------------------------------------------------

create or replace function public.transit_checkin(p_game_id uuid, p_mode text, p_line text default null, p_from text default null, p_to text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_id uuid;
  v_pos public.positions;
begin
  v_me := public.require_participant(p_game_id, array['spieler']);
  g := public.require_running(p_game_id, true);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  if not (coalesce(v_cfg -> 'transport' -> 'allowed_modes', '[]') ? p_mode) then
    raise exception 'Diese Fortbewegung ist nicht erlaubt.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.transit_sessions where participant_id = v_me.id and ended_at is null) then
    raise exception 'Du bist schon angemeldet.' using errcode = 'P0001';
  end if;
  insert into public.transit_sessions (game_id, participant_id, mode, line, from_station, to_station, started_at)
  values (p_game_id, v_me.id, p_mode, nullif(p_line, ''), nullif(p_from, ''), nullif(p_to, ''), v_now) returning id into v_id;
  update public.participants set rides_today = rides_today + 1, speeding_since = null, transport_prompted_at = null where id = v_me.id;
  if g.status <> 'vorsprung' and public.cfg_bool(v_cfg, 'transport', 'live_during', true) then
    perform public.open_live_window(p_game_id, v_me.id, 'oev', v_now, null);
  end if;
  select * into v_pos from public.positions where participant_id = v_me.id;
  if g.status <> 'vorsprung' then
    perform public.create_ping(g, v_me.id, 'transit', v_pos.lat, v_pos.lng, v_pos.accuracy_m, null, null, null,
      replace(p_mode, '_', ' ') || coalesce(' ' || nullif(p_line, ''), ''), 0, v_now);
    perform public.notify(p_game_id, 'taskforce', null, 'transit', public.pname(v_me.id) || ' fährt ' || case p_mode when 'oev_bus' then 'Bus' when 'oev_bahn' then 'Bahn' when 'oev_tram' then 'Tram'
      when 'faehre' then 'Fähre' when 'taxi' then 'Taxi' when 'fahrrad' then 'Velo' when 'scooter' then 'Scooter' else replace(p_mode, '_', ' ') end || coalesce(' ' || nullif(p_line, ''), ''),
      case when nullif(p_from, '') is not null or nullif(p_to, '') is not null
        then coalesce(nullif(p_from, ''), '?') || ' → ' || coalesce(nullif(p_to, ''), '?') || '. ' else '' end || 'Live-Standort sichtbar.', jsonb_build_object('participant_id', v_me.id), 'hoch');
  end if;
  perform public.bump(p_game_id);
  return v_id;
end; $$;

create or replace function public.transit_checkout(p_game_id uuid, p_stops int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_t public.transit_sessions;
  v_after int;
begin
  v_me := public.require_participant(p_game_id, array['spieler']);
  g := public.require_running(p_game_id, true);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  select * into v_t from public.transit_sessions where participant_id = v_me.id and ended_at is null;
  if v_t.id is null then raise exception 'Keine laufende Fahrt.' using errcode = 'P0001'; end if;
  -- Nachlauf wächst mit jeder Fahrt.
  v_after := public.cfg_int(v_cfg, 'transport', 'live_after_base_minutes', 10)
    + public.cfg_int(v_cfg, 'transport', 'live_after_increment_minutes', 5) * greatest(v_me.rides_today - 1, 0);
  update public.transit_sessions set ended_at = v_now, stops = p_stops, live_after_minutes = v_after where id = v_t.id;
  perform public.close_live_windows(v_me.id, 'oev', v_now);
  if g.status <> 'vorsprung' and v_after > 0 then
    perform public.open_live_window(p_game_id, v_me.id, 'oev_nachlauf', v_now, v_now + make_interval(mins => v_after));
  end if;
  if v_t.mode = 'faehre' and p_stops is not null then
    update public.participants set ferry_stops_today = ferry_stops_today + p_stops where id = v_me.id returning * into v_me;
    if v_me.ferry_stops_today > public.cfg_int(v_cfg, 'transport', 'ferry_max_stops_per_day', 10) then
      perform public.create_violation(g, v_me.id, 'faehren_limit', jsonb_build_object('stops', v_me.ferry_stops_today), v_now);
    end if;
  end if;
  if g.status <> 'vorsprung' then
    perform public.notify(p_game_id, 'taskforce', null, 'transit_end', public.pname(v_me.id) || ' ist ausgestiegen',
      case when v_after > 0 then 'Noch ' || v_after || ' min live.' else '' end, jsonb_build_object('participant_id', v_me.id), 'normal');
  end if;
  perform public.bump(p_game_id);
  return jsonb_build_object('live_after_minutes', v_after);
end; $$;

-- ---------------------------------------------------------------------------
-- Budget (7.10)
-- ---------------------------------------------------------------------------

create or replace function public.make_purchase(p_game_id uuid, p_amount numeric, p_category text, p_note text default null, p_receipt text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_pos public.positions;
begin
  v_me := public.require_participant(p_game_id, array['spieler']);
  g := public.require_running(p_game_id, true);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  if not public.cfg_bool(v_cfg, 'budget', 'enabled', false) then raise exception 'Budget ist aus.' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Betrag fehlt.' using errcode = 'P0001'; end if;
  if p_amount > v_me.budget_balance then
    raise exception 'Nicht genug Budget (noch % %).', v_me.budget_balance, public.cfg_text(v_cfg, 'budget', 'currency', 'USD') using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'budget', 'receipt_photo_required', false) and nullif(p_receipt, '') is null then
    raise exception 'Belegfoto ist Pflicht.' using errcode = 'P0001';
  end if;
  select * into v_pos from public.positions where participant_id = v_me.id;
  insert into public.purchases (game_id, participant_id, amount, category, note, at, lat, lng, receipt_path)
  values (p_game_id, v_me.id, p_amount, coalesce(nullif(p_category, ''), 'sonstiges'), p_note, v_now, v_pos.lat, v_pos.lng, nullif(p_receipt, ''));
  update public.participants set budget_balance = budget_balance - p_amount where id = v_me.id returning * into v_me;
  if g.status <> 'vorsprung' then
    perform public.create_ping(g, v_me.id, 'purchase', v_pos.lat, v_pos.lng, v_pos.accuracy_m, null, null, null,
      case when public.cfg_bool(v_cfg, 'budget', 'reveal_amount', false) then p_amount || ' ' || public.cfg_text(v_cfg, 'budget', 'currency', 'USD') else 'Kauf' end,
      public.cfg_int(v_cfg, 'budget', 'ping_delay_minutes', 0), v_now);
  end if;
  perform public.bump(p_game_id);
  return jsonb_build_object('balance', v_me.budget_balance);
end; $$;

-- ---------------------------------------------------------------------------
-- Joker und Boni (7.11, 7.12)
-- ---------------------------------------------------------------------------

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
        raise exception 'Während eines Speedhunts nicht möglich.' using errcode = 'P0001';
      end if;
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, source_item_id)
      values (g.id, v_me.id, 'regeneration', v_now, v_now + make_interval(mins => coalesce(v_minutes, 240)), v_i.id);
      perform public.notify(g.id, 'taskforce', null, 'joker', 'Joker: Regeneration', 'Ein Spieler ist für ' || coalesce(v_minutes, 240) || ' min nicht ortbar.', '{}', 'normal');
    when 'catch_free' then
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, source_item_id)
      values (g.id, v_me.id, 'catch_free', v_now, v_now + make_interval(mins => coalesce(v_minutes, 180)), v_i.id);
      perform public.notify(g.id, 'taskforce', null, 'joker', 'Joker: Catch-Free', public.pname(v_me.id) || ' kann ' || coalesce(v_minutes, 180) || ' min nicht gefangen werden.', '{}', 'hoch');
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

create or replace function public.gm_grant_item(p_game_id uuid, p_participant uuid, p_kind text, p_type text, p_minutes int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_id uuid;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
  values (p_game_id, p_participant, p_kind, p_type, p_minutes, g.current_day, public.engine_now(p_game_id), 'spielleitung') returning id into v_id;
  perform public.notify(p_game_id, null, p_participant, p_kind, case p_kind when 'joker' then 'Neuer Joker: ' else 'Neuer Bonus: ' end || replace(p_type, '_', ' '), '', '{}', 'normal');
  perform public.bump(p_game_id);
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Challenges (7.13)
-- ---------------------------------------------------------------------------

create or replace function public.challenge_create(p_game_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_now timestamptz := public.engine_now(p_game_id);
  v_start timestamptz;
  v_cfg jsonb;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select config_json into v_cfg from public.games where id = p_game_id;
  v_start := coalesce((p_data ->> 'starts_at')::timestamptz, v_now + make_interval(mins => coalesce((p_data ->> 'starts_in_minutes')::int, 30)));
  insert into public.challenges (game_id, template, title, description, lat, lng, radius_m, announce_at, starts_at, ends_at,
    proof_type, secret_code, reward_type, reward_value, reveal_location_to_taskforce, max_participants)
  values (p_game_id, coalesce(p_data ->> 'template', 'eigene'), coalesce(nullif(p_data ->> 'title', ''), 'Challenge'), coalesce(p_data ->> 'description', ''),
    (p_data ->> 'lat')::double precision, (p_data ->> 'lng')::double precision, coalesce((p_data ->> 'radius_m')::int, 50),
    v_start - make_interval(mins => public.cfg_int(v_cfg, 'challenge', 'announce_before_minutes', 60)),
    v_start, v_start + make_interval(mins => coalesce((p_data ->> 'duration_minutes')::int, 30)),
    coalesce(p_data ->> 'proof_type', 'geofence'), nullif(p_data ->> 'secret_code', ''),
    coalesce(p_data ->> 'reward_type', 'bonus_fake_ping'), (p_data ->> 'reward_value')::int,
    coalesce((p_data ->> 'reveal_location_to_taskforce')::boolean, true), (p_data ->> 'max_participants')::int)
  returning id into v_id;
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return v_id;
end; $$;

create or replace function public.challenge_cancel(p_challenge_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_c public.challenges;
begin
  select * into v_c from public.challenges where id = p_challenge_id;
  if not public.is_game_leader(v_c.game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  update public.challenges set status = 'abgesagt' where id = v_c.id;
  perform public.notify(v_c.game_id, 'spieler', null, 'challenge_cancel', 'Challenge abgesagt: ' || v_c.title, '', '{}', 'normal');
  perform public.bump(v_c.game_id);
end; $$;

create or replace function public.challenge_reward(g public.games, p_c public.challenges, p_participant uuid, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  case p_c.reward_type
    when 'bonus_fake_ping' then
      insert into public.inventory_items (game_id, participant_id, kind, type, granted_day, granted_at, source)
      values (g.id, p_participant, 'bonus', 'fake_ping', g.current_day, p_now, 'challenge');
    when 'bonus_hotel' then
      insert into public.inventory_items (game_id, participant_id, kind, type, granted_day, granted_at, source)
      values (g.id, p_participant, 'bonus', 'hotel', g.current_day, p_now, 'challenge');
    when 'budget' then
      update public.participants set budget_balance = budget_balance + coalesce(p_c.reward_value, 10) where id = p_participant;
    when 'joker' then
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
      values (g.id, p_participant, 'joker', 'catch_free', coalesce(p_c.reward_value, 60), g.current_day, p_now, 'challenge');
    else null;
  end case;
  perform public.notify(g.id, null, p_participant, 'challenge_won', 'Challenge geschafft!', 'Belohnung: ' || replace(p_c.reward_type, '_', ' '), '{}', 'hoch');
end; $$;

create or replace function public.challenge_join(p_challenge_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.challenges;
  v_me public.participants;
begin
  select * into v_c from public.challenges where id = p_challenge_id;
  v_me := public.require_participant(v_c.game_id, array['spieler']);
  if v_c.status not in ('angekuendigt', 'laeuft') then raise exception 'Anmeldung nicht möglich.' using errcode = 'P0001'; end if;
  if v_c.max_participants is not null and (select count(*) from public.challenge_entries where challenge_id = v_c.id) >= v_c.max_participants then
    raise exception 'Challenge ist voll.' using errcode = 'P0001';
  end if;
  insert into public.challenge_entries (challenge_id, participant_id, joined_at) values (v_c.id, v_me.id, public.engine_now(v_c.game_id))
  on conflict do nothing;
  perform public.bump(v_c.game_id);
end; $$;

create or replace function public.challenge_submit(p_challenge_id uuid, p_code text default null, p_proof_path text default null)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_c public.challenges;
  v_me public.participants;
  g public.games;
  v_e public.challenge_entries;
  v_pos public.positions;
  v_now timestamptz;
  v_ok boolean := false;
begin
  select * into v_c from public.challenges where id = p_challenge_id;
  v_me := public.require_participant(v_c.game_id, array['spieler']);
  g := public.require_running(v_c.game_id);
  v_now := public.engine_now(g.id);
  if v_c.status <> 'laeuft' then raise exception 'Die Challenge läuft gerade nicht.' using errcode = 'P0001'; end if;
  insert into public.challenge_entries (challenge_id, participant_id, joined_at) values (v_c.id, v_me.id, v_now) on conflict do nothing;
  select * into v_e from public.challenge_entries where challenge_id = v_c.id and participant_id = v_me.id;
  if v_e.result in ('erfolgreich', 'gescheitert') then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  case v_c.proof_type
    when 'geofence' then
      select * into v_pos from public.positions where participant_id = v_me.id;
      v_ok := v_pos.participant_id is not null and v_c.lat is not null
        and public.dist_m(v_pos.geom, public.pt(v_c.lat, v_c.lng)) <= coalesce(v_c.radius_m, 50) + coalesce(v_pos.accuracy_m, 0);
      if not v_ok then raise exception 'Du bist noch nicht am Ort der Challenge.' using errcode = 'P0001'; end if;
    when 'code' then
      v_ok := lower(trim(coalesce(p_code, ''))) = lower(trim(coalesce(v_c.secret_code, '')));
      if not v_ok then raise exception 'Code falsch.' using errcode = 'P0001'; end if;
    else
      update public.challenge_entries set result = 'eingereicht', proof_path = p_proof_path, proof_text = p_code where id = v_e.id;
      if public.cfg_text(g.config_json, 'roles', 'gm_mode', 'auto') = 'auto' then
        -- Ohne menschliche Spielleitung zählt eine Einreichung (im Zweifel für die Spieler).
        v_ok := true;
      else
        perform public.notify(g.id, 'gm', null, 'challenge_review', 'Challenge prüfen: ' || public.pname(v_me.id), v_c.title, jsonb_build_object('entry_id', v_e.id), 'hoch');
        perform public.bump(g.id);
        return 'eingereicht';
      end if;
  end case;
  update public.challenge_entries set result = 'erfolgreich', decided_at = v_now, proof_path = p_proof_path where id = v_e.id;
  perform public.challenge_reward(g, v_c, v_me.id, v_now);
  perform public.bump(g.id);
  return 'erfolgreich';
end; $$;

create or replace function public.challenge_decide(p_entry_id uuid, p_success boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_e public.challenge_entries;
  v_c public.challenges;
  g public.games;
begin
  select * into v_e from public.challenge_entries where id = p_entry_id;
  select * into v_c from public.challenges where id = v_e.challenge_id;
  if not public.is_game_leader(v_c.game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = v_c.game_id;
  if v_e.result = 'erfolgreich' then return; end if;
  update public.challenge_entries set result = case when p_success then 'erfolgreich' else 'gescheitert' end, decided_at = public.engine_now(g.id) where id = v_e.id;
  if p_success then perform public.challenge_reward(g, v_c, v_e.participant_id, public.engine_now(g.id)); end if;
  perform public.bump(g.id);
end; $$;

-- ---------------------------------------------------------------------------
-- Notfall und Pause (7.15, 7.16)
-- ---------------------------------------------------------------------------

create or replace function public.pause_game(p_game_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is not null or g.status not in ('vorsprung', 'laeuft', 'finale') then return; end if;
  perform public.tick_game(p_game_id);
  update public.games set paused_at = public.engine_now(p_game_id), pause_reason = coalesce(nullif(p_reason, ''), 'Pause') where id = p_game_id;
  perform public.notify(p_game_id, 'alle', null, 'pause', 'Spiel pausiert', coalesce(nullif(p_reason, ''), ''), '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'paused', jsonb_build_object('reason', p_reason));
  perform public.bump(p_game_id);
end; $$;

create or replace function public.pause_internal(p_game_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.games set paused_at = public.engine_now(p_game_id), pause_reason = p_reason where id = p_game_id and paused_at is null;
  perform public.notify(p_game_id, 'alle', null, 'pause', 'Spiel pausiert', p_reason, '{}', 'kritisch');
end; $$;

-- Fortsetzen: alle laufenden Fristen um die Pausendauer verschieben (14.3, Regel 8).
create or replace function public.resume_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_now timestamptz;
  d interval;
  v_ext boolean;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id for update;
  if g.paused_at is null then return; end if;
  v_now := public.engine_now(p_game_id);
  d := v_now - g.paused_at;
  v_ext := public.cfg_bool(g.config_json, 'game', 'pause_extends_game', true);
  update public.games set paused_at = null, pause_reason = null, last_tick_at = v_now,
    hunt_start_at = case when status = 'vorsprung' then hunt_start_at + d else hunt_start_at end,
    ends_at = case when v_ext then ends_at + d else ends_at end,
    deadline_at = case when v_ext then deadline_at + d else deadline_at end,
    exit_reveal_at = case when v_ext then exit_reveal_at + d else exit_reveal_at end,
    next_day_at = case when v_ext then next_day_at + d else next_day_at end
  where id = p_game_id;
  update public.participants set next_ping_at = next_ping_at + d, ping_pending_until = ping_pending_until + d,
    grace_until = grace_until + d, out_pending_since = out_pending_since + d, stationary_since = stationary_since + d,
    speeding_since = speeding_since + d, transport_prompted_at = transport_prompted_at + d
  where game_id = p_game_id;
  update public.speedhunts set deadline_at = deadline_at + d where game_id = p_game_id and status = 'laeuft';
  update public.active_effects set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.live_windows set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.violations set auto_apply_at = auto_apply_at + d where game_id = p_game_id and status = 'offen';
  update public.catches set expires_at = expires_at + d where game_id = p_game_id and expires_at > g.paused_at;
  update public.challenges set starts_at = starts_at + d, ends_at = ends_at + d, announce_at = announce_at + d
    where game_id = p_game_id and status in ('geplant', 'angekuendigt', 'laeuft');
  update public.zones set visible_from = visible_from + d where game_id = p_game_id and visible_from > g.paused_at and visible_from <> 'infinity' and v_ext;
  perform public.notify(p_game_id, 'alle', null, 'resume', 'Weiter geht''s!', 'Das Spiel läuft wieder.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'resumed', jsonb_build_object('seconds', extract(epoch from d)::int));
  perform public.bump(p_game_id);
end; $$;

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
  perform public.notify(p_game_id, 'taskforce', null, 'emergency', 'NOTFALL: ' || public.pname(v_me.id), 'Jagd auf diese Person ist ausgesetzt. Helft, wenn ihr in der Nähe seid.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  if public.cfg_text(g.config_json, 'safety', 'emergency_pauses', 'person') = 'alle' and g.status in ('vorsprung', 'laeuft', 'finale') then
    perform public.pause_internal(p_game_id, 'Notfall: ' || public.pname(v_me.id));
  end if;
  perform public.log_game_event(p_game_id, 'emergency', jsonb_build_object('participant', v_me.id));
  perform public.bump(p_game_id);
  return v_id;
end; $$;

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
          or (v_me.id = v_e.participant_id and public.cfg_text(g.config_json, 'roles', 'gm_mode', 'auto') = 'auto')) then
    raise exception 'Nur die Spielleitung kann den Notfall beenden.' using errcode = '42501';
  end if;
  v_now := public.engine_now(g.id);
  update public.emergencies set status = 'erledigt', resolved_by = auth.uid(), resolved_at = v_now where id = v_e.id;
  select * into v_p from public.participants where id = v_e.participant_id;
  if v_p.state = 'notfall' then
    update public.participants set state = coalesce(state_before, 'aktiv'), state_before = null where id = v_p.id;
  end if;
  perform public.close_live_windows(v_p.id, 'notfall', v_now);
  perform public.notify(g.id, 'alle', null, 'emergency_end', 'Notfall erledigt', public.pname(v_p.id), '{}', 'hoch');
  perform public.bump(g.id);
end; $$;

-- Notfallkontakt: nur Spielleitung bzw. Host (Kapitel 15).
create or replace function public.emergency_contact(p_game_id uuid, p_participant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select jsonb_build_object('name', pp.emergency_contact_name, 'phone', pp.emergency_contact_phone) into v
  from public.participants p join public.profile_private pp on pp.user_id = p.user_id where p.id = p_participant and p.game_id = p_game_id;
  perform public.log_game_event(p_game_id, 'emergency_contact_viewed', jsonb_build_object('participant', p_participant));
  return v;
end; $$;

-- ---------------------------------------------------------------------------
-- Verstösse (7.17)
-- ---------------------------------------------------------------------------

create or replace function public.violation_explain(p_violation_id uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.violations;
  v_me public.participants;
begin
  select * into v from public.violations where id = p_violation_id;
  v_me := public.require_participant(v.game_id);
  if v_me.id <> v.participant_id then raise exception 'Nicht dein Verstoss.' using errcode = '42501'; end if;
  update public.violations set explanation = left(p_text, 500) where id = v.id;
  -- Mit menschlicher Spielleitung wartet die Strafe auf die Entscheidung.
  if public.cfg_text((select config_json from public.games where id = v.game_id), 'roles', 'gm_mode', 'auto') <> 'auto' then
    update public.violations set auto_apply_at = null where id = v.id and status = 'offen';
  end if;
  perform public.notify(v.game_id, 'gm', null, 'violation_explained', 'Erklärung: ' || public.pname(v.participant_id), left(p_text, 200), jsonb_build_object('violation_id', v.id), 'normal');
  perform public.bump(v.game_id);
end; $$;

create or replace function public.violation_decide(p_violation_id uuid, p_penalty text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.violations;
  g public.games;
begin
  select * into v from public.violations where id = p_violation_id;
  perform public.require_participant(v.game_id, array['gm']);
  select * into g from public.games where id = v.game_id;
  if v.status <> 'offen' then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  if p_penalty is null or p_penalty = 'verwerfen' then
    update public.violations set status = 'verworfen', decided_at = public.engine_now(g.id) where id = v.id;
    perform public.notify(g.id, null, v.participant_id, 'violation_dismissed', 'Verstoss verworfen', '', '{}', 'normal');
  else
    perform public.apply_penalty(g, v.id, p_penalty, public.engine_now(g.id));
  end if;
  perform public.bump(g.id);
end; $$;

create or replace function public.violation_report(p_game_id uuid, p_participant uuid, p_type text, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_id uuid;
begin
  v_me := public.require_participant(p_game_id);
  select * into g from public.games where id = p_game_id;
  v_id := public.create_violation(g, p_participant, coalesce(nullif(p_type, ''), 'sonstiges'), jsonb_build_object('note', p_note, 'by', public.pname(v_me.id)),
    public.engine_now(p_game_id), null, case when v_me.role = 'gm' then 'gm' else 'meldung' end);
  -- Meldungen durch Mitspielende werden nie automatisch bestraft.
  if v_me.role <> 'gm' then update public.violations set auto_apply_at = null where id = v_id; end if;
  perform public.bump(p_game_id);
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Spielleitung (7.16, 22.7)
-- ---------------------------------------------------------------------------

create or replace function public.gm_ping(p_game_id uuid, p_participant uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_pos record;
  v_id uuid;
begin
  perform public.require_participant(p_game_id, array['gm']);
  g := public.require_running(p_game_id);
  select * into v_pos from public.best_position(p_participant, public.engine_now(p_game_id));
  v_id := public.create_ping(g, p_participant, 'gm', v_pos.lat, v_pos.lng, v_pos.accuracy_m, v_pos.age_s, null, null, 'Spielleitung', 0, public.engine_now(p_game_id));
  perform public.notify(p_game_id, 'taskforce', null, 'gm_ping', 'Sonder-Ping: ' || public.pname(p_participant), '', jsonb_build_object('ping_id', v_id), 'hoch');
  perform public.bump(p_game_id);
  return v_id;
end; $$;

create or replace function public.gm_add_zone(p_game_id uuid, p_feature jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
  v_geom extensions.geometry;
begin
  perform public.require_participant(p_game_id, array['gm']);
  if (p_feature #>> '{properties,kind}') not in ('sperrzone', 'sicher', 'treffpunkt') then
    raise exception 'Im Spiel nur Sperrzonen, sichere Zonen oder Treffpunkte.' using errcode = 'P0001';
  end if;
  v_geom := ST_SetSRID(ST_GeomFromGeoJSON((p_feature -> 'geometry')::text), 4326);
  -- Punkt mit Radius als Kreisfläche speichern (Sperr- und Schutzzonen sind Flächen).
  if ST_GeometryType(v_geom) = 'ST_Point' and (p_feature #>> '{properties,kind}') <> 'treffpunkt' then
    v_geom := ST_Buffer(v_geom::geography, coalesce(nullif(p_feature #>> '{properties,radius_m}', '')::int, 50))::geometry;
  end if;
  insert into public.zones (game_id, kind, name, geom, radius_m, crossing_allowed)
  values (p_game_id, p_feature #>> '{properties,kind}', coalesce(p_feature #>> '{properties,name}', ''),
          v_geom, nullif(p_feature #>> '{properties,radius_m}', '')::int,
          coalesce((p_feature #>> '{properties,crossing_allowed}')::boolean, false))
  returning id into v_id;
  update public.games set map_version = map_version + 1 where id = p_game_id;
  perform public.notify(p_game_id, 'alle', null, 'zone_added', 'Neue Zone: ' || coalesce(nullif(p_feature #>> '{properties,name}', ''), p_feature #>> '{properties,kind}'), 'Siehe Karte.', '{}', 'hoch');
  perform public.bump(p_game_id);
  return v_id;
end; $$;

create or replace function public.gm_set_state(p_participant uuid, p_state text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p public.participants;
  g public.games;
begin
  select * into v_p from public.participants where id = p_participant;
  perform public.require_participant(v_p.game_id, array['gm']);
  select * into g from public.games where id = v_p.game_id;
  if p_state not in ('aktiv', 'gefangen', 'disqualifiziert', 'im_ziel', 'pausiert') then raise exception 'Unbekannter Status.' using errcode = 'P0001'; end if;
  if p_state = 'disqualifiziert' then
    perform public.disqualify(g, p_participant, 'Spielleitung', public.engine_now(g.id));
  elsif p_state = 'gefangen' then
    perform public.auto_catch(g, p_participant, 'Spielleitung', public.engine_now(g.id));
  elsif p_state = 'im_ziel' then
    perform public.reach_exit(g, p_participant, public.engine_now(g.id));
  else
    update public.participants set state = p_state where id = p_participant;
    if p_state = 'aktiv' and v_p.next_ping_at is null and v_p.role = 'spieler' then
      perform public.schedule_next_ping(g, p_participant, public.engine_now(g.id));
    end if;
  end if;
  perform public.bump(g.id);
end; $$;

create or replace function public.gm_end_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.status in ('entwurf', 'geplant', 'lobby') then
    update public.games set status = 'beendet', ended_at = now(), result_json = '{"reason": "abgebrochen", "winners": []}' where id = p_game_id;
  else
    perform public.finish_game(g, public.engine_now(p_game_id), 'abgebrochen');
  end if;
  perform public.bump(p_game_id);
end; $$;

-- Live-Regeländerung durch die Spielleitung (z. B. Ping-Intervall), mit Protokoll.
create or replace function public.gm_update_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
  g public.games;
begin
  perform public.require_participant(p_game_id, array['gm']);
  select * into g from public.games where id = p_game_id;
  if not public.cfg_bool(g.config_json, 'ping', 'gm_can_change_live', true) then raise exception 'Live-Änderungen sind ausgeschaltet.' using errcode = 'P0001'; end if;
  update public.games set config_json = p_config, updated_at = now() where id = p_game_id;
  for c in select * from jsonb_array_elements(coalesce(p_changes, '[]')) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value) values (p_game_id, auth.uid(), c ->> 'path', c -> 'old', c -> 'new');
  end loop;
  perform public.notify(p_game_id, 'alle', null, 'rules_changed', 'Regeln geändert', (select string_agg(c ->> 'path', ', ') from jsonb_array_elements(coalesce(p_changes, '[]')) c), '{}', 'hoch');
  perform public.bump(p_game_id);
end; $$;

create or replace function public.briefing_confirm(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale']);
  select * into g from public.games where id = p_game_id;
  update public.participants set briefing_done_day = g.current_day where id = v_me.id;
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Chat (7.20)
-- ---------------------------------------------------------------------------

create or replace function public.send_message(p_game_id uuid, p_channel text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id);
  select * into g from public.games where id = p_game_id;
  if p_channel = 'ankuendigung' and v_me.role <> 'gm' and not public.is_game_host(p_game_id) then
    raise exception 'Nur die Spielleitung kündigt an.' using errcode = '42501';
  elsif p_channel = 'taskforce' and v_me.role not in ('hunter', 'zentrale', 'gm') then
    raise exception 'Nur für die Taskforce.' using errcode = '42501';
  elsif p_channel = 'spieler' and (v_me.role not in ('spieler', 'gm') or (v_me.role = 'spieler' and not public.cfg_bool(g.config_json, 'communication', 'player_to_player', false))) then
    raise exception 'Chat zwischen Spielern ist in diesem Spiel aus.' using errcode = '42501';
  elsif p_channel like 'gm:%' and v_me.role <> 'gm' and p_channel <> 'gm:' || v_me.id::text then
    raise exception 'Nicht dein Kanal.' using errcode = '42501';
  elsif p_channel not in ('ankuendigung', 'taskforce', 'spieler') and p_channel not like 'gm:%' then
    raise exception 'Unbekannter Kanal.' using errcode = 'P0001';
  end if;
  insert into public.messages (game_id, channel, sender_id, sender_name, body, at)
  values (p_game_id, p_channel, auth.uid(), public.pname(v_me.id), trim(p_body), now());
end; $$;

create or replace function public.send_group_message(p_group_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_group_member(p_group_id) then raise exception 'Nicht in der Gruppe.' using errcode = '42501'; end if;
  insert into public.messages (group_id, channel, sender_id, sender_name, body, at)
  values (p_group_id, 'gruppe', auth.uid(), (select display_name from public.profiles where user_id = auth.uid()), trim(p_body), now());
end; $$;

-- Zugriffsrechte
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'require_participant', 'require_running', 'catch_code_at', 'catch_blocked_reason', 'register_catch', 'challenge_reward', 'pause_internal'
    )
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
  for r in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'is_game_leader', 'start_game', 'advance_time', 'game_tick', 'report_location', 'set_device_check', 'speedhunt_start', 'speedhunt_approve',
      'speedhunt_query', 'my_catch_code', 'catch_by_code', 'catch_claim', 'catch_respond', 'catch_attach_media', 'gm_catch_decide',
      'confirm_exit', 'give_up', 'hideout_report', 'transit_checkin', 'transit_checkout', 'make_purchase', 'use_item', 'gm_grant_item',
      'challenge_create', 'challenge_cancel', 'challenge_join', 'challenge_submit', 'challenge_decide', 'pause_game', 'resume_game',
      'emergency_start', 'emergency_resolve', 'emergency_contact', 'violation_explain', 'violation_decide', 'violation_report',
      'gm_ping', 'gm_add_zone', 'gm_set_state', 'gm_end_game', 'gm_update_config', 'briefing_confirm', 'send_message', 'send_group_message'
    )
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- ===== 0006_spielstand.sql =====

-- Spielstand für die Oberfläche: eine Abfrage, Sichtbarkeit nach Rolle (Kapitel 5.2, 16).

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  me public.participants;
  v_role text;
  v_now timestamptz;
  v_tf boolean;
  v_gm boolean;
  v_ended boolean;
  v_delay int;
  v_hist int;
  v_out jsonb;
begin
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if me.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  v_cfg := g.config_json;
  v_role := me.role;
  v_now := now() + g.clock_offset;
  v_gm := v_role = 'gm';
  v_tf := v_role in ('hunter', 'zentrale');
  v_ended := g.status in ('beendet', 'archiviert');
  v_delay := public.cfg_int(v_cfg, 'spectator', 'delay_minutes', 30);
  v_hist := public.cfg_int(v_cfg, 'ping', 'history_per_player', 5);

  v_out := jsonb_build_object(
    'now', v_now,
    'server_now', now(),
    'game', jsonb_build_object(
      'id', g.id, 'name', g.name, 'code', g.code, 'status', g.status, 'is_test', g.is_test, 'host', g.host_id = auth.uid(),
      'start_at', g.start_at, 'hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at, 'deadline_at', g.deadline_at,
      'next_day_at', g.next_day_at, 'current_day', g.current_day, 'paused', g.paused_at is not null, 'pause_reason', g.pause_reason,
      'timezone', g.timezone, 'speedhunts_left', g.speedhunts_left, 'exit_revealed', g.exit_revealed, 'exit_reveal_at', g.exit_reveal_at,
      'map_version', g.map_version, 'result', g.result_json, 'meeting_point', g.meeting_point, 'config', v_cfg, 'group_id', g.group_id,
      'quiet', public.in_quiet_hours(g, v_now)
    ),
    'me', jsonb_build_object(
      'id', me.id, 'role', me.role, 'state', me.state, 'budget', me.budget_balance, 'bounty', me.bounty,
      'next_ping_at', case when v_role = 'spieler' then me.next_ping_at end,
      'location_requested', me.location_request_at is not null,
      'hideout_prompt', me.hideout_prompted_at is not null and not exists (select 1 from public.hideouts where participant_id = me.id and status = 'aktiv' and inside),
      'transport_prompt', me.transport_prompted_at is not null,
      'out_accum_s', me.out_accum_s, 'out_pending', me.out_pending_since is not null, 'in_restricted', me.restricted_zone_id is not null,
      'briefing_done', me.briefing_done_day = g.current_day,
      'live', public.has_live_window(me.id, v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.type, 'ends_at', e.ends_at, 'payload', e.payload)), '[]')
                  from public.active_effects e where e.participant_id = me.id and e.starts_at <= v_now and (e.ends_at is null or e.ends_at > v_now) and not (e.payload ? 'done')),
      'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'source', i.source) order by i.granted_at), '[]')
                    from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired),
      'hideout', (select jsonb_build_object('id', h.id, 'inside', h.inside, 'accum_s', h.accum_s, 'entered_at', h.entered_at,
                    'max_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))
                  from public.hideouts h where h.participant_id = me.id and h.status = 'aktiv' limit 1),
      'transit', (select jsonb_build_object('id', t.id, 'mode', t.mode, 'line', t.line, 'started_at', t.started_at)
                  from public.transit_sessions t where t.participant_id = me.id and t.ended_at is null limit 1),
      'device_check', me.device_check
    ),
    'participants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', pr.display_name, 'username', pr.username, 'role', p.role, 'color', p.color,
        'state', case when v_gm or v_ended or p.id = me.id or p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren', 'ausserhalb', 'notfall') then p.state else 'aktiv' end,
        'battery', case when v_gm or (v_tf and p.role in ('hunter', 'zentrale')) then p.battery end,
        'last_seen_at', case when v_gm then p.last_seen_at end,
        'bounty', p.bounty,
        'budget', case when v_gm then p.budget_balance end,
        'device_check', case when v_gm or p.id = me.id or g.status in ('lobby', 'geplant', 'entwurf') then p.device_check end,
        'next_ping_at', case when (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true)) or v_gm then p.next_ping_at end,
        'protected', case when v_tf or v_gm then (public.has_effect(p.id, 'regeneration', v_now) or public.has_effect(p.id, 'hotel', v_now)) end,
        'catch_free', case when v_tf or v_gm then public.has_effect(p.id, 'catch_free', v_now) end,
        'briefing_done', p.briefing_done_day = g.current_day
      ) order by p.role, pr.display_name), '[]')
      from public.participants p join public.profiles pr on pr.user_id = p.user_id
      where p.game_id = g.id
    ),
    -- Positionen: Spielleitung alles, Taskforce die eigenen Leute und Spieler im Live-Fenster,
    -- Spieler nur sich selbst, Zuschauer verzögert (5.2, 7.18).
    'positions', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', x.participant_id, 'lat', x.lat, 'lng', x.lng, 'accuracy_m', x.accuracy_m,
        'speed_mps', x.speed_mps, 'heading', x.heading, 'at', x.at, 'live', x.live)), '[]')
      from (
        select pos.participant_id, pos.lat, pos.lng, pos.accuracy_m, pos.speed_mps, pos.heading, pos.at,
               public.has_live_window(pos.participant_id, v_now) live
        from public.positions pos join public.participants p on p.id = pos.participant_id
        where pos.game_id = g.id and v_role <> 'zuschauer' and (
          v_gm or v_ended or pos.participant_id = me.id
          or (v_tf and p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'taskforce', 'share_positions_internally', true))
          or (v_tf and p.role = 'spieler' and public.has_live_window(p.id, v_now) and p.state in ('aktiv', 'ausserhalb', 'notfall'))
          or (v_role = 'spieler' and p.role = 'spieler' and p.state = 'notfall')
        )
        union all
        (select distinct on (s.participant_id) s.participant_id, ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.speed_mps, s.heading, s.at, false
        from public.location_samples s
        where s.game_id = g.id and v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false)
          and s.at <= v_now - make_interval(mins => v_delay)
        order by s.participant_id, s.at desc)
      ) x
    ),
    -- Pings: Taskforce sieht die letzten n je Spieler (ohne Fake-Markierung), Spieler die eigenen,
    -- Spielleitung alles inkl. echter Position, Zuschauer verzögert.
    'pings', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds,
        'is_fake', case when v_gm or v_ended or x.participant_id = me.id then x.is_fake end,
        'truth', case when (v_gm or v_ended) and x.is_fake then (select jsonb_build_object('lat', t.lat, 'lng', t.lng) from public.ping_truth t where t.ping_id = x.id) end
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg
        where pg.game_id = g.id and (
          v_gm or v_ended
          or (v_tf and pg.visible_at <= v_now)
          or (v_role = 'spieler' and pg.participant_id = me.id)
          or (v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false) and pg.visible_at <= v_now - make_interval(mins => v_delay))
        )
      ) x where x.rn <= case when v_gm or v_ended then 1000 else v_hist end
    ),
    'speedhunts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty,
        'target_id', case when v_gm or v_tf or v_ended or (s.target_id = me.id and public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false)) then s.target_id end,
        'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
        'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
      from public.speedhunts s where s.game_id = g.id and (s.status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') or s.ended_at > v_now - interval '2 hours' or v_gm or v_ended)
        and (s.status <> 'wartet_auf_freigabe' or v_gm or v_tf) and (s.status <> 'aufgeschoben' or v_gm or v_tf)
        and not (s.status = 'beendet' and s.started_at is null and not v_gm)
    ),
    'catches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'runner_id', c.runner_id, 'hunter_id', c.hunter_id, 'at', c.at, 'method', c.method,
        'status', c.status, 'expires_at', c.expires_at, 'distance_m', c.distance_m, 'reason', c.reason, 'lat', case when v_gm or v_ended then c.lat end,
        'lng', case when v_gm or v_ended then c.lng end) order by c.at desc), '[]')
      from public.catches c where c.game_id = g.id and (c.status = 'gueltig' or v_gm or c.runner_id = me.id or c.hunter_id = me.id)
    ),
    'violations', (
      select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'participant_id', v.participant_id, 'type', v.type, 'at', v.at, 'evidence', v.evidence,
        'proposed_penalty', v.proposed_penalty, 'decided_penalty', v.decided_penalty, 'status', v.status, 'auto_apply_at', v.auto_apply_at,
        'explanation', v.explanation, 'detected_by', v.detected_by) order by v.at desc), '[]')
      from public.violations v where v.game_id = g.id and (v_gm or v.participant_id = me.id or v_ended)
    ),
    'challenges', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'description', c.description, 'template', c.template,
        'lat', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lat end,
        'lng', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lng end,
        'radius_m', c.radius_m, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'announce_at', c.announce_at, 'proof_type', c.proof_type,
        'secret_code', case when v_gm then c.secret_code end, 'reward_type', c.reward_type, 'reward_value', c.reward_value, 'status', c.status,
        'max_participants', c.max_participants,
        'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'result', e.result, 'proof_path', case when v_gm then e.proof_path end, 'proof_text', case when v_gm then e.proof_text end)), '[]')
                    from public.challenge_entries e where e.challenge_id = c.id and (v_gm or e.participant_id = me.id or v_ended))
      ) order by c.starts_at), '[]')
      from public.challenges c where c.game_id = g.id and (v_gm or c.status <> 'geplant')
    ),
    'emergencies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'status', e.status)), '[]')
      from public.emergencies e where e.game_id = g.id and e.status = 'offen' and (v_gm or v_tf or e.participant_id = me.id or public.is_game_host(g.id))
    ),
    'transits', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', t.participant_id, 'mode', t.mode, 'line', t.line, 'from', t.from_station, 'to', t.to_station,
        'started_at', t.started_at)), '[]')
      from public.transit_sessions t where t.game_id = g.id and t.ended_at is null and (v_gm or v_tf or t.participant_id = me.id)
    ),
    'hideouts', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', h.participant_id, 'inside', h.inside, 'accum_s', h.accum_s, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))), '[]')
      from public.hideouts h where h.game_id = g.id and h.status = 'aktiv' and v_gm
    ),
    'purchases', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', u.participant_id, 'amount', u.amount, 'category', u.category, 'note', u.note, 'at', u.at) order by u.at desc), '[]')
      from public.purchases u where u.game_id = g.id and (v_gm or u.participant_id = me.id)
    ),
    'notifications', (
      select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
        select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
        from public.notifications n where n.game_id = g.id and public.can_see_notification(n)
        order by n.id desc limit 60
      ) q
    ),
    'next_silent_ping_at', case when v_gm or (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true))
      then (select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb')) end,
    'free_players', public.free_players(g.id)
  );
  return v_out;
end; $$;

-- Wiederholung nach Spielende (12.3): alle Spuren, ausgedünnt auf einen Punkt pro Minute.
create or replace function public.game_replay(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if not public.is_game_member(p_game_id) then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if g.status not in ('beendet', 'archiviert') and not public.is_game_gm(p_game_id) then
    raise exception 'Die Wiederholung gibt es erst nach Spielende.' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'start', g.hunt_start_at, 'end', coalesce(g.ended_at, now() + g.clock_offset),
    'tracks', (
      select coalesce(jsonb_object_agg(pid, pts), '{}') from (
        select participant_id pid, jsonb_agg(jsonb_build_array(extract(epoch from m)::bigint, round(lat::numeric, 6), round(lng::numeric, 6)) order by m) pts
        from (
          select distinct on (participant_id, date_trunc('minute', at)) participant_id, date_trunc('minute', at) m, ST_Y(geom) lat, ST_X(geom) lng
          from public.location_samples where game_id = p_game_id
          order by participant_id, date_trunc('minute', at), at desc
        ) s group by participant_id
      ) t
    ),
    'pings', (select coalesce(jsonb_agg(jsonb_build_object('participant_id', participant_id, 'at', at, 'lat', lat, 'lng', lng, 'source', source, 'is_fake', is_fake) order by at), '[]')
              from public.pings where game_id = p_game_id and lat is not null),
    'catches', (select coalesce(jsonb_agg(jsonb_build_object('runner_id', runner_id, 'hunter_id', hunter_id, 'at', at, 'lat', lat, 'lng', lng)), '[]')
                from public.catches where game_id = p_game_id and status = 'gueltig'),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'type', type, 'payload', payload_json) order by at), '[]')
               from public.game_events where game_id = p_game_id)
  );
end; $$;

revoke execute on function public.game_state(uuid), public.game_replay(uuid) from public, anon;
grant execute on function public.game_state(uuid), public.game_replay(uuid) to authenticated;

-- ===== 0007_zeitplan.sql =====

-- Zeitplan: die Engine tickt alle 15 Sekunden (14.1), auch wenn niemand die App offen hat.
-- In Supabase: Database > Extensions > pg_cron muss aktiv sein (dieses Skript versucht es selbst).

create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'hunt-mode-tick';
  perform cron.schedule('hunt-mode-tick', '15 seconds', 'select public.engine_tick_all()');
end $$;

-- Standortdaten nach Ablauf der Aufbewahrungsfrist löschen (Kapitel 15).
create or replace function public.purge_old_locations()
returns void language sql security definer set search_path = public as $$
  delete from public.location_samples s using public.games g
  where s.game_id = g.id and g.status in ('beendet', 'archiviert')
    and g.ended_at < now() - make_interval(days => public.cfg_int(g.config_json, 'privacy', 'retention_days', 30));
$$;
revoke execute on function public.purge_old_locations() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'hunt-mode-purge';
  perform cron.schedule('hunt-mode-purge', '17 3 * * *', 'select public.purge_old_locations()');
end $$;

-- ===== 0008_zonen_phasen.sql =====

-- Spielfeld-Phasen: Verkleinerung auch alle X Minuten (nicht nur pro Spieltag),
-- Prüfungen der Karte beim Start (Treffpunkt und Exit im Spielfeld, nicht in Sperrzonen).
-- Spielfeld-Zonen mit day_index meinen ab jetzt "Phase": pro Spieltag oder pro Zeitabschnitt.

-- Minuten pro Phase (0 = eine Phase pro Spieltag).
create or replace function public.shrink_every_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.cfg_text(p_cfg, 'zone', 'shrink_mode', 'manuell') = 'aus' then 0
    else greatest(0, public.cfg_int(p_cfg, 'zone', 'shrink_every_minutes', 0)) end;
$$;

-- Anzahl Phasen des Spiels.
create or replace function public.phase_count(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.shrink_every_minutes(p_cfg) > 0
    then least(50, greatest(1, ceil(public.cfg_int(p_cfg, 'game', 'duration_minutes', 5760)::numeric / public.shrink_every_minutes(p_cfg))::int))
    else public.cfg_int(p_cfg, 'game', 'days', 4) end;
$$;

-- Beginn einer Phase.
create or replace function public.phase_start(p_game public.games, p_phase int)
returns timestamptz language sql stable set search_path = public as $$
  select case when public.shrink_every_minutes(p_game.config_json) > 0
    then p_game.hunt_start_at + make_interval(mins => (greatest(p_phase, 1) - 1) * public.shrink_every_minutes(p_game.config_json))
    else public.day_start(p_game, p_phase) end;
$$;

-- Aktuelle Phase für das Spielfeld (bei Zeit-Phasen aus dem Spielzustand, sonst der Spieltag).
create or replace function public.field_phase(p_game_id uuid, p_day int)
returns int language sql stable security definer set search_path = public as $$
  select case when public.shrink_every_minutes(g.config_json) > 0
    then coalesce((g.state_json ->> 'phase')::int, 1) else p_day end
  from public.games g where g.id = p_game_id;
$$;

-- Nächste Phase aktivieren (Zeit-Phasen).
create or replace function public.phase_advance(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_phase int := coalesce((p_game.state_json ->> 'phase')::int, 1) + 1;
  v_next timestamptz;
  v_grace int := public.cfg_int(v_cfg, 'zone', 'shrink_grace_minutes', 0);
begin
  v_next := public.phase_start(p_game, v_phase + 1);
  if v_phase >= public.phase_count(v_cfg) or v_next >= p_game.ends_at then v_next := null; end if;
  update public.games set state_json = state_json || jsonb_build_object('phase', v_phase, 'next_phase_at', v_next)
  where id = p_game.id returning * into p_game;
  if exists (select 1 from public.zones where game_id = p_game.id and kind = 'spielfeld' and day_index = v_phase) then
    if v_grace > 0 then
      update public.participants set grace_until = p_now + make_interval(mins => v_grace) where game_id = p_game.id and role = 'spieler';
    end if;
    perform public.recheck_zones(p_game, p_now);
    perform public.notify(p_game.id, 'alle', null, 'zone_active', 'Das Spielfeld ist jetzt kleiner',
      'Phase ' || v_phase || ' von ' || public.phase_count(v_cfg) || ': neue Grenzen gelten ab sofort.', '{}', 'hoch');
    update public.games set map_version = map_version + 1 where id = p_game.id returning * into p_game;
    perform public.log_game_event(p_game.id, 'phase', jsonb_build_object('phase', v_phase));
  end if;
  return p_game;
end; $$;

-- Ankündigung der nächsten Phase (Zeit-Phasen).
create or replace function public.phase_announce(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_next timestamptz := (p_game.state_json ->> 'next_phase_at')::timestamptz;
  v_phase int := coalesce((p_game.state_json ->> 'phase')::int, 1) + 1;
begin
  if v_next is null then return p_game; end if;
  if v_next - make_interval(mins => public.cfg_int(v_cfg, 'zone', 'shrink_announce_minutes', 180)) > p_now then return p_game; end if;
  if coalesce((p_game.state_json ->> 'announced_phase')::int, 0) >= v_phase then return p_game; end if;
  if not exists (select 1 from public.zones where game_id = p_game.id and kind = 'spielfeld' and day_index = v_phase) then return p_game; end if;
  update public.games set state_json = state_json || jsonb_build_object('announced_phase', v_phase), map_version = map_version + 1
  where id = p_game.id returning * into p_game;
  perform public.notify(p_game.id, 'alle', null, 'zone_announce', 'Spielfeld wird kleiner um ' || to_char(v_next at time zone p_game.timezone, 'HH24:MI'),
    'Die neuen Grenzen sind auf der Karte gestrichelt.', '{}', 'hoch');
  return p_game;
end; $$;

revoke execute on function public.shrink_every_minutes(jsonb), public.phase_count(jsonb), public.phase_start(public.games, int),
  public.field_phase(uuid, int), public.phase_advance(public.games, timestamptz), public.phase_announce(public.games, timestamptz)
  from public, anon, authenticated;


create or replace function public.allowed_area(p_game_id uuid, p_participant_id uuid, p_day int, p_sections boolean)
returns extensions.geometry language plpgsql stable security definer set search_path = public, extensions as $$
declare v extensions.geometry;
begin
  if p_sections then
    select ST_Union(geom) into v from public.zones
    where game_id = p_game_id and (
      (kind = 'sektion' and (owner_participant_id = p_participant_id or released))
      or kind in ('startzone', 'center')
    );
    return v;
  end if;
  v := public.spielfeld_day(p_game_id, public.field_phase(p_game_id, p_day));
  if v is null then
    select ST_Union(geom) into v from public.zones where game_id = p_game_id and kind in ('sektion', 'startzone', 'center');
  end if;
  return v;
end; $$;

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
  -- 1. Spieltag-Zähler
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
    perform public.notify(p_game.id, 'alle', null, 'zone_active', 'Das Spielfeld hat sich geändert', 'Spieltag ' || v_day || ': neue Grenzen gelten jetzt.', '{}', 'hoch');
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
    perform public.notify(p_game.id, 'alle', null, 'day_reset', 'Neuer Spieltag: ' || v_day || ' von ' || v_days,
      case when public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then 'Speedhunts heute: ' || v_left else '' end, '{}', 'hoch');
  end if;
  if public.cfg_bool(v_cfg, 'taskforce', 'daily_briefing', false) then
    perform public.notify(p_game.id, 'taskforce', null, 'briefing', 'Einsatzbesprechung', 'Bitte trefft euch und bestätigt das Briefing.', '{}', 'normal');
  end if;
  perform public.log_game_event(p_game.id, 'day_reset', jsonb_build_object('day', v_day));
  return p_game;
end; $$;

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
        'Die Taskforce kennt deinen Ort. Verlass ihn sofort.', '{}', 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'hotel_end', 'Hotel-Ping: ' || public.pname(v_e.participant_id), '', '{}', 'hoch');
    elsif v_e.type in ('regeneration', 'catch_free', 'leo') then
      perform public.notify(g.id, null, v_e.participant_id, 'effect_end',
        case v_e.type when 'regeneration' then 'Regeneration vorbei' when 'catch_free' then 'Catch-Free vorbei' else 'LEO vorbei' end,
        '', '{}', 'normal');
    end if;
  end loop;
  -- Aufgeschobene Straf-Speedhunts starten, sobald keine Regeneration mehr läuft.
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
      -- Auto-Spielleitung: gültig, wenn der GPS-Abstand passt (7.6).
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

  -- Exitpoint bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now and g.exit_zone_id is not null then
    update public.zones set visible_from = v_now,
      visible_to = case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end
    where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1,
      state_json = state_json || jsonb_build_object('exit_taskforce_at', case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig')
        when 'verzoegert' then to_jsonb(v_now + interval '15 minutes') else null end)
    where id = g.id returning * into g;
    perform public.notify(g.id, case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end,
      null, 'exit_reveal', 'Exitpoint bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
    if public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') <> 'gleichzeitig' then
      perform public.notify(g.id, 'gm', null, 'exit_reveal', 'Exitpoint an Spieler bekanntgegeben', '', '{}', 'normal');
    end if;
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
  end if;
  if g.state_json ? 'exit_taskforce_at' and jsonb_typeof(g.state_json -> 'exit_taskforce_at') = 'string'
     and (g.state_json ->> 'exit_taskforce_at')::timestamptz <= v_now then
    update public.zones set visible_to = 'alle' where id = g.exit_zone_id;
    update public.games set state_json = state_json - 'exit_taskforce_at', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Exitpoint bekannt', 'Siehe Karte.', '{}', 'kritisch');
  end if;

  -- Spielende
  if v_now >= g.ends_at and not coalesce((g.state_json ->> 'end_notified')::boolean, false) and public.cfg_bool(v_cfg, 'exit', 'enabled', true)
     and g.deadline_at > g.ends_at then
    update public.games set state_json = state_json || '{"end_notified": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'alle', null, 'time_up', 'Spielzeit vorbei', 'Ankunft am Exitpoint noch bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
  end if;
  if v_now >= g.deadline_at then
    perform public.finish_game(g, v_now, 'zeit_abgelaufen');
  end if;

  update public.games set last_tick_at = v_now where id = g.id;
  perform public.bump(g.id);
end; $$;

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
    raise exception 'Setze mindestens einen Exitpoint-Kandidaten auf der Karte (oder schalte den Exitpoint aus).' using errcode = 'P0001';
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
    raise exception 'Treffpunkt, HQ oder ein Exitpoint liegt in einer Sperrzone.' using errcode = 'P0001';
  end if;

  -- Exitpoint auswählen (zufällig oder der erste Kandidat)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    select id into v_exit from public.zones where game_id = p_game_id and kind = 'exit'
    order by case when public.cfg_bool(v_cfg, 'exit', 'random_from_candidates', true) then random() else 0 end, created_at limit 1;
    -- Nicht gewählte Kandidaten bleiben für immer verborgen.
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit' and id <> v_exit;
    update public.zones set visible_to = 'gm' where id = v_exit;
  end if;

  -- Automatische Verkleinerung: Spielfeld je Tag um x % (Fläche) um den Exit bzw. Mittelpunkt (7.1).
  -- Phasen: pro Spieltag oder alle X Minuten.
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

create or replace function public.resume_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_now timestamptz;
  d interval;
  v_ext boolean;
begin
  if not public.is_game_leader(p_game_id) then raise exception 'Nur Host oder Spielleitung.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id for update;
  if g.paused_at is null then return; end if;
  v_now := public.engine_now(p_game_id);
  d := v_now - g.paused_at;
  v_ext := public.cfg_bool(g.config_json, 'game', 'pause_extends_game', true);
  update public.games set paused_at = null, pause_reason = null, last_tick_at = v_now,
    hunt_start_at = case when status = 'vorsprung' then hunt_start_at + d else hunt_start_at end,
    ends_at = case when v_ext then ends_at + d else ends_at end,
    deadline_at = case when v_ext then deadline_at + d else deadline_at end,
    exit_reveal_at = case when v_ext then exit_reveal_at + d else exit_reveal_at end,
    next_day_at = case when v_ext then next_day_at + d else next_day_at end
  where id = p_game_id;
  update public.participants set next_ping_at = next_ping_at + d, ping_pending_until = ping_pending_until + d,
    grace_until = grace_until + d, out_pending_since = out_pending_since + d, stationary_since = stationary_since + d,
    speeding_since = speeding_since + d, transport_prompted_at = transport_prompted_at + d
  where game_id = p_game_id;
  update public.speedhunts set deadline_at = deadline_at + d where game_id = p_game_id and status = 'laeuft';
  update public.active_effects set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.live_windows set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.violations set auto_apply_at = auto_apply_at + d where game_id = p_game_id and status = 'offen';
  update public.catches set expires_at = expires_at + d where game_id = p_game_id and expires_at > g.paused_at;
  update public.challenges set starts_at = starts_at + d, ends_at = ends_at + d, announce_at = announce_at + d
    where game_id = p_game_id and status in ('geplant', 'angekuendigt', 'laeuft');
  update public.games set state_json = jsonb_set(state_json, '{next_phase_at}', to_jsonb((state_json ->> 'next_phase_at')::timestamptz + d))
    where id = p_game_id and v_ext and (state_json ->> 'next_phase_at') is not null;
  update public.zones set visible_from = visible_from + d where game_id = p_game_id and visible_from > g.paused_at and visible_from <> 'infinity' and v_ext;
  perform public.notify(p_game_id, 'alle', null, 'resume', 'Weiter geht''s!', 'Das Spiel läuft wieder.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'resumed', jsonb_build_object('seconds', extract(epoch from d)::int));
  perform public.bump(p_game_id);
end; $$;

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  me public.participants;
  v_role text;
  v_now timestamptz;
  v_tf boolean;
  v_gm boolean;
  v_ended boolean;
  v_delay int;
  v_hist int;
  v_out jsonb;
begin
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if me.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  v_cfg := g.config_json;
  v_role := me.role;
  v_now := now() + g.clock_offset;
  v_gm := v_role = 'gm';
  v_tf := v_role in ('hunter', 'zentrale');
  v_ended := g.status in ('beendet', 'archiviert');
  v_delay := public.cfg_int(v_cfg, 'spectator', 'delay_minutes', 30);
  v_hist := public.cfg_int(v_cfg, 'ping', 'history_per_player', 5);

  v_out := jsonb_build_object(
    'now', v_now,
    'server_now', now(),
    'game', jsonb_build_object(
      'id', g.id, 'name', g.name, 'code', g.code, 'status', g.status, 'is_test', g.is_test, 'host', g.host_id = auth.uid(),
      'start_at', g.start_at, 'hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at, 'deadline_at', g.deadline_at,
      'next_day_at', g.next_day_at, 'current_day', g.current_day,
      'phase', public.field_phase(g.id, g.current_day), 'phase_count', public.phase_count(v_cfg),
      'next_phase_at', case when public.shrink_every_minutes(v_cfg) > 0 then (g.state_json ->> 'next_phase_at')::timestamptz else g.next_day_at end, 'paused', g.paused_at is not null, 'pause_reason', g.pause_reason,
      'timezone', g.timezone, 'speedhunts_left', g.speedhunts_left, 'exit_revealed', g.exit_revealed, 'exit_reveal_at', g.exit_reveal_at,
      'map_version', g.map_version, 'result', g.result_json, 'meeting_point', g.meeting_point, 'config', v_cfg, 'group_id', g.group_id,
      'quiet', public.in_quiet_hours(g, v_now)
    ),
    'me', jsonb_build_object(
      'id', me.id, 'role', me.role, 'state', me.state, 'budget', me.budget_balance, 'bounty', me.bounty,
      'next_ping_at', case when v_role = 'spieler' then me.next_ping_at end,
      'location_requested', me.location_request_at is not null,
      'hideout_prompt', me.hideout_prompted_at is not null and not exists (select 1 from public.hideouts where participant_id = me.id and status = 'aktiv' and inside),
      'transport_prompt', me.transport_prompted_at is not null,
      'out_accum_s', me.out_accum_s, 'out_pending', me.out_pending_since is not null, 'in_restricted', me.restricted_zone_id is not null,
      'briefing_done', me.briefing_done_day = g.current_day,
      'live', public.has_live_window(me.id, v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.type, 'ends_at', e.ends_at, 'payload', e.payload)), '[]')
                  from public.active_effects e where e.participant_id = me.id and e.starts_at <= v_now and (e.ends_at is null or e.ends_at > v_now) and not (e.payload ? 'done')),
      'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'source', i.source) order by i.granted_at), '[]')
                    from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired),
      'hideout', (select jsonb_build_object('id', h.id, 'inside', h.inside, 'accum_s', h.accum_s, 'entered_at', h.entered_at,
                    'max_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))
                  from public.hideouts h where h.participant_id = me.id and h.status = 'aktiv' limit 1),
      'transit', (select jsonb_build_object('id', t.id, 'mode', t.mode, 'line', t.line, 'started_at', t.started_at)
                  from public.transit_sessions t where t.participant_id = me.id and t.ended_at is null limit 1),
      'device_check', me.device_check
    ),
    'participants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', pr.display_name, 'username', pr.username, 'role', p.role, 'color', p.color,
        'state', case when v_gm or v_ended or p.id = me.id or p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren', 'ausserhalb', 'notfall') then p.state else 'aktiv' end,
        'battery', case when v_gm or (v_tf and p.role in ('hunter', 'zentrale')) then p.battery end,
        'last_seen_at', case when v_gm then p.last_seen_at end,
        'bounty', p.bounty,
        'budget', case when v_gm then p.budget_balance end,
        'device_check', case when v_gm or p.id = me.id or g.status in ('lobby', 'geplant', 'entwurf') then p.device_check end,
        'next_ping_at', case when (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true)) or v_gm then p.next_ping_at end,
        'protected', case when v_tf or v_gm then (public.has_effect(p.id, 'regeneration', v_now) or public.has_effect(p.id, 'hotel', v_now)) end,
        'catch_free', case when v_tf or v_gm then public.has_effect(p.id, 'catch_free', v_now) end,
        'briefing_done', p.briefing_done_day = g.current_day
      ) order by p.role, pr.display_name), '[]')
      from public.participants p join public.profiles pr on pr.user_id = p.user_id
      where p.game_id = g.id
    ),
    -- Positionen: Spielleitung alles, Taskforce die eigenen Leute und Spieler im Live-Fenster,
    -- Spieler nur sich selbst, Zuschauer verzögert (5.2, 7.18).
    'positions', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', x.participant_id, 'lat', x.lat, 'lng', x.lng, 'accuracy_m', x.accuracy_m,
        'speed_mps', x.speed_mps, 'heading', x.heading, 'at', x.at, 'live', x.live)), '[]')
      from (
        select pos.participant_id, pos.lat, pos.lng, pos.accuracy_m, pos.speed_mps, pos.heading, pos.at,
               public.has_live_window(pos.participant_id, v_now) live
        from public.positions pos join public.participants p on p.id = pos.participant_id
        where pos.game_id = g.id and v_role <> 'zuschauer' and (
          v_gm or v_ended or pos.participant_id = me.id
          or (v_tf and p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'taskforce', 'share_positions_internally', true))
          or (v_tf and p.role = 'spieler' and public.has_live_window(p.id, v_now) and p.state in ('aktiv', 'ausserhalb', 'notfall'))
          or (v_role = 'spieler' and p.role = 'spieler' and p.state = 'notfall')
        )
        union all
        (select distinct on (s.participant_id) s.participant_id, ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.speed_mps, s.heading, s.at, false
        from public.location_samples s
        where s.game_id = g.id and v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false)
          and s.at <= v_now - make_interval(mins => v_delay)
        order by s.participant_id, s.at desc)
      ) x
    ),
    -- Pings: Taskforce sieht die letzten n je Spieler (ohne Fake-Markierung), Spieler die eigenen,
    -- Spielleitung alles inkl. echter Position, Zuschauer verzögert.
    'pings', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds,
        'is_fake', case when v_gm or v_ended or x.participant_id = me.id then x.is_fake end,
        'truth', case when (v_gm or v_ended) and x.is_fake then (select jsonb_build_object('lat', t.lat, 'lng', t.lng) from public.ping_truth t where t.ping_id = x.id) end
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg
        where pg.game_id = g.id and (
          v_gm or v_ended
          or (v_tf and pg.visible_at <= v_now)
          or (v_role = 'spieler' and pg.participant_id = me.id)
          or (v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false) and pg.visible_at <= v_now - make_interval(mins => v_delay))
        )
      ) x where x.rn <= case when v_gm or v_ended then 1000 else v_hist end
    ),
    'speedhunts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty,
        'target_id', case when v_gm or v_tf or v_ended or (s.target_id = me.id and public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false)) then s.target_id end,
        'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
        'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
      from public.speedhunts s where s.game_id = g.id and (s.status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') or s.ended_at > v_now - interval '2 hours' or v_gm or v_ended)
        and (s.status <> 'wartet_auf_freigabe' or v_gm or v_tf) and (s.status <> 'aufgeschoben' or v_gm or v_tf)
        and not (s.status = 'beendet' and s.started_at is null and not v_gm)
    ),
    'catches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'runner_id', c.runner_id, 'hunter_id', c.hunter_id, 'at', c.at, 'method', c.method,
        'status', c.status, 'expires_at', c.expires_at, 'distance_m', c.distance_m, 'reason', c.reason, 'lat', case when v_gm or v_ended then c.lat end,
        'lng', case when v_gm or v_ended then c.lng end) order by c.at desc), '[]')
      from public.catches c where c.game_id = g.id and (c.status = 'gueltig' or v_gm or c.runner_id = me.id or c.hunter_id = me.id)
    ),
    'violations', (
      select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'participant_id', v.participant_id, 'type', v.type, 'at', v.at, 'evidence', v.evidence,
        'proposed_penalty', v.proposed_penalty, 'decided_penalty', v.decided_penalty, 'status', v.status, 'auto_apply_at', v.auto_apply_at,
        'explanation', v.explanation, 'detected_by', v.detected_by) order by v.at desc), '[]')
      from public.violations v where v.game_id = g.id and (v_gm or v.participant_id = me.id or v_ended)
    ),
    'challenges', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'description', c.description, 'template', c.template,
        'lat', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lat end,
        'lng', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lng end,
        'radius_m', c.radius_m, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'announce_at', c.announce_at, 'proof_type', c.proof_type,
        'secret_code', case when v_gm then c.secret_code end, 'reward_type', c.reward_type, 'reward_value', c.reward_value, 'status', c.status,
        'max_participants', c.max_participants,
        'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'result', e.result, 'proof_path', case when v_gm then e.proof_path end, 'proof_text', case when v_gm then e.proof_text end)), '[]')
                    from public.challenge_entries e where e.challenge_id = c.id and (v_gm or e.participant_id = me.id or v_ended))
      ) order by c.starts_at), '[]')
      from public.challenges c where c.game_id = g.id and (v_gm or c.status <> 'geplant')
    ),
    'emergencies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'status', e.status)), '[]')
      from public.emergencies e where e.game_id = g.id and e.status = 'offen' and (v_gm or v_tf or e.participant_id = me.id or public.is_game_host(g.id))
    ),
    'transits', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', t.participant_id, 'mode', t.mode, 'line', t.line, 'from', t.from_station, 'to', t.to_station,
        'started_at', t.started_at)), '[]')
      from public.transit_sessions t where t.game_id = g.id and t.ended_at is null and (v_gm or v_tf or t.participant_id = me.id)
    ),
    'hideouts', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', h.participant_id, 'inside', h.inside, 'accum_s', h.accum_s, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))), '[]')
      from public.hideouts h where h.game_id = g.id and h.status = 'aktiv' and v_gm
    ),
    'purchases', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', u.participant_id, 'amount', u.amount, 'category', u.category, 'note', u.note, 'at', u.at) order by u.at desc), '[]')
      from public.purchases u where u.game_id = g.id and (v_gm or u.participant_id = me.id)
    ),
    'notifications', (
      select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
        select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
        from public.notifications n where n.game_id = g.id and public.can_see_notification(n)
        order by n.id desc limit 60
      ) q
    ),
    'next_silent_ping_at', case when v_gm or (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true))
      then (select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb')) end,
    'free_players', public.free_players(g.id)
  );
  return v_out;
end; $$;

-- ===== 0009_notfall_joker_chat.sql =====

-- Verbesserungen Runde 3:
-- * Joker erst ab einer einstellbaren Zeit nach Jagdbeginn (joker.available_after_minutes), einmal pro Spieltag.
-- * Ausserhalb der eigenen Zone bzw. des Spielfelds: Live-Standort immer an alle Hunter.
-- * Notfall: alle Hunter werden alarmiert und sehen den Notfallkontakt; die Person selbst kann einen Fehlalarm abbrechen.
-- * Chat: Spieler schreiben nur mit der Spielleitung; Ankündigungen schreibt nur die Spielleitung.

create or replace function public.grant_jokers(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_types jsonb := coalesce(v_cfg -> 'joker' -> 'types', '[]');
  v_n int := jsonb_array_length(v_types);
  v_per int := public.cfg_int(v_cfg, 'joker', 'per_day', 1);
  v_sel text := public.cfg_text(v_cfg, 'joker', 'selection', 'zufall');
  v_carry text := public.cfg_text(v_cfg, 'joker', 'carry_over', 'einen_tag');
  v_max int := public.cfg_int(v_cfg, 'joker', 'max_inventory', 2);
  v_p public.participants;
  v_t jsonb;
  v_done int;
  v_after int := public.cfg_int(v_cfg, 'joker', 'available_after_minutes', 0);
  v_have int;
  i int;
begin
  if not public.cfg_bool(v_cfg, 'joker', 'enabled', false) or v_n = 0 or v_per = 0 then return; end if;
  if p_game.status not in ('laeuft', 'finale') or p_game.current_day < 1 then return; end if;
  -- Erst ab "verfügbar ab" nach Jagdbeginn, und pro Spieltag nur einmal.
  if p_game.hunt_start_at is null or p_now < p_game.hunt_start_at + make_interval(mins => v_after) then return; end if;
  select coalesce((state_json ->> 'joker_day')::int, 0) into v_done from public.games where id = p_game.id;
  if v_done >= p_game.current_day then return; end if;
  update public.games set state_json = state_json || jsonb_build_object('joker_day', p_game.current_day) where id = p_game.id;
  -- Aufheben: nie = alte verfallen, einen_tag = älter als gestern verfällt.
  if v_carry = 'nie' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired;
  elsif v_carry = 'einen_tag' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired
      and granted_day < p_game.current_day - 1;
  end if;
  for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall') loop
    for i in 1..v_per loop
      select count(*) into v_have from public.inventory_items where participant_id = v_p.id and kind = 'joker' and used_at is null and not expired;
      exit when v_have >= v_max;
      v_t := case v_sel
        when 'fest_pro_tag' then v_types -> ((p_game.current_day - 1) % v_n)
        when 'spieler_waehlt' then jsonb_build_object('type', 'wahl')
        else v_types -> floor(random() * v_n)::int
      end;
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
      values (p_game.id, v_p.id, 'joker', v_t ->> 'type', (v_t ->> 'minutes')::int, p_game.current_day, p_now, 'tag');
      perform public.notify(p_game.id, null, v_p.id, 'joker', 'Neuer Joker: ' || replace(v_t ->> 'type', '_', ' '),
        case when v_t ? 'minutes' then (v_t ->> 'minutes') || ' min' else '' end, '{}', 'normal');
    end loop;
  end loop;
end; $$;

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

  -- Joker des Spieltags (sobald sie verfügbar sind)
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
        'Die Taskforce kennt deinen Ort. Verlass ihn sofort.', '{}', 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'hotel_end', 'Hotel-Ping: ' || public.pname(v_e.participant_id), '', '{}', 'hoch');
    elsif v_e.type in ('regeneration', 'catch_free', 'leo') then
      perform public.notify(g.id, null, v_e.participant_id, 'effect_end',
        case v_e.type when 'regeneration' then 'Regeneration vorbei' when 'catch_free' then 'Catch-Free vorbei' else 'LEO vorbei' end,
        '', '{}', 'normal');
    end if;
  end loop;
  -- Aufgeschobene Straf-Speedhunts starten, sobald keine Regeneration mehr läuft.
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
      -- Auto-Spielleitung: gültig, wenn der GPS-Abstand passt (7.6).
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

  -- Exitpoint bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now and g.exit_zone_id is not null then
    update public.zones set visible_from = v_now,
      visible_to = case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end
    where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1,
      state_json = state_json || jsonb_build_object('exit_taskforce_at', case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig')
        when 'verzoegert' then to_jsonb(v_now + interval '15 minutes') else null end)
    where id = g.id returning * into g;
    perform public.notify(g.id, case public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') when 'gleichzeitig' then 'alle' else 'spieler' end,
      null, 'exit_reveal', 'Exitpoint bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
    if public.cfg_text(v_cfg, 'exit', 'reveal_to_taskforce', 'gleichzeitig') <> 'gleichzeitig' then
      perform public.notify(g.id, 'gm', null, 'exit_reveal', 'Exitpoint an Spieler bekanntgegeben', '', '{}', 'normal');
    end if;
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
  end if;
  if g.state_json ? 'exit_taskforce_at' and jsonb_typeof(g.state_json -> 'exit_taskforce_at') = 'string'
     and (g.state_json ->> 'exit_taskforce_at')::timestamptz <= v_now then
    update public.zones set visible_to = 'alle' where id = g.exit_zone_id;
    update public.games set state_json = state_json - 'exit_taskforce_at', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Exitpoint bekannt', 'Siehe Karte.', '{}', 'kritisch');
  end if;

  -- Spielende
  if v_now >= g.ends_at and not coalesce((g.state_json ->> 'end_notified')::boolean, false) and public.cfg_bool(v_cfg, 'exit', 'enabled', true)
     and g.deadline_at > g.ends_at then
    update public.games set state_json = state_json || '{"end_notified": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'alle', null, 'time_up', 'Spielzeit vorbei', 'Ankunft am Exitpoint noch bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
  end if;
  if v_now >= g.deadline_at then
    perform public.finish_game(g, v_now, 'zeit_abgelaufen');
  end if;

  update public.games set last_tick_at = v_now where id = g.id;
  perform public.bump(g.id);
end; $$;

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
        when 'catch' then 'zum Fang' when 'disqualify' then 'zur Disqualifikation' else 'zur Strafe' end || '. Die Taskforce sieht dich live.',
      '{}', 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
    perform public.notify(p_game.id, 'gm', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', '', '{}', 'normal');
  end if;
end; $$;

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
    'Alle Hunter' || case when exists (select 1 from public.participants where game_id = p_game_id and role = 'gm') then ' und die Spielleitung' else '' end
    || ' sind alarmiert. Bei Gefahr: Polizei 117, Sanität 144, Notruf 112.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  perform public.log_game_event(p_game_id, 'emergency', jsonb_build_object('participant', v_me.id));
  perform public.bump(p_game_id);
  return v_id;
end; $$;

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
    raise exception 'Nur die Person selbst oder die Spielleitung kann den Notfall beenden.' using errcode = '42501';
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

create or replace function public.emergency_contact(p_game_id uuid, p_participant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  -- Spielleitung immer; Hunter nur bei einem offenen Notfall dieser Person.
  if not (public.is_game_leader(p_game_id)
          or (exists (select 1 from public.participants where game_id = p_game_id and user_id = auth.uid() and role in ('hunter', 'zentrale'))
              and exists (select 1 from public.emergencies where game_id = p_game_id and participant_id = p_participant and status = 'offen'))) then
    raise exception 'Nur Spielleitung, oder Hunter bei einem Notfall.' using errcode = '42501';
  end if;
  select jsonb_build_object('name', pp.emergency_contact_name, 'phone', pp.emergency_contact_phone) into v
  from public.participants p join public.profile_private pp on pp.user_id = p.user_id where p.id = p_participant and p.game_id = p_game_id;
  perform public.log_game_event(p_game_id, 'emergency_contact_viewed', jsonb_build_object('participant', p_participant));
  return v;
end; $$;

create or replace function public.send_message(p_game_id uuid, p_channel text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id);
  select * into g from public.games where id = p_game_id;
  if p_channel = 'ankuendigung' and v_me.role <> 'gm'
     and not (public.is_game_host(p_game_id) and v_me.role not in ('spieler', 'hunter', 'zentrale')) then
    raise exception 'Nur die Spielleitung kündigt an.' using errcode = '42501';
  elsif p_channel = 'taskforce' and v_me.role not in ('hunter', 'zentrale', 'gm') then
    raise exception 'Nur für die Taskforce.' using errcode = '42501';
  elsif p_channel = 'spieler' and v_me.role <> 'gm' then
    raise exception 'Spieler schreiben nur mit der Spielleitung.' using errcode = '42501';
  elsif p_channel like 'gm:%' and v_me.role <> 'gm' and p_channel <> 'gm:' || v_me.id::text then
    raise exception 'Nicht dein Kanal.' using errcode = '42501';
  elsif p_channel not in ('ankuendigung', 'taskforce', 'spieler') and p_channel not like 'gm:%' then
    raise exception 'Unbekannter Kanal.' using errcode = 'P0001';
  end if;
  insert into public.messages (game_id, channel, sender_id, sender_name, body, at)
  values (p_game_id, p_channel, auth.uid(), public.pname(v_me.id), trim(p_body), now());
end; $$;

revoke all on function public.grant_jokers(public.games, timestamptz) from public, anon, authenticated;
revoke all on function public.check_player_zone(public.games, public.participants, extensions.geometry, timestamptz) from public, anon, authenticated;

-- ===== 0010_konto_loeschen.sql =====

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

-- ===== 0011_joker_texte.sql =====

-- Joker-Meldungen auf Deutsch und mit Erklärung, was der Joker macht.

CREATE OR REPLACE FUNCTION public.grant_jokers(p_game games, p_now timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg jsonb := p_game.config_json;
  v_types jsonb := coalesce(v_cfg -> 'joker' -> 'types', '[]');
  v_n int := jsonb_array_length(v_types);
  v_per int := public.cfg_int(v_cfg, 'joker', 'per_day', 1);
  v_sel text := public.cfg_text(v_cfg, 'joker', 'selection', 'zufall');
  v_carry text := public.cfg_text(v_cfg, 'joker', 'carry_over', 'einen_tag');
  v_max int := public.cfg_int(v_cfg, 'joker', 'max_inventory', 2);
  v_p public.participants;
  v_t jsonb;
  v_done int;
  v_after int := public.cfg_int(v_cfg, 'joker', 'available_after_minutes', 0);
  v_have int;
  i int;
begin
  if not public.cfg_bool(v_cfg, 'joker', 'enabled', false) or v_n = 0 or v_per = 0 then return; end if;
  if p_game.status not in ('laeuft', 'finale') or p_game.current_day < 1 then return; end if;
  -- Erst ab "verfügbar ab" nach Jagdbeginn, und pro Spieltag nur einmal.
  if p_game.hunt_start_at is null or p_now < p_game.hunt_start_at + make_interval(mins => v_after) then return; end if;
  select coalesce((state_json ->> 'joker_day')::int, 0) into v_done from public.games where id = p_game.id;
  if v_done >= p_game.current_day then return; end if;
  update public.games set state_json = state_json || jsonb_build_object('joker_day', p_game.current_day) where id = p_game.id;
  -- Aufheben: nie = alte verfallen, einen_tag = älter als gestern verfällt.
  if v_carry = 'nie' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired;
  elsif v_carry = 'einen_tag' then
    update public.inventory_items set expired = true where game_id = p_game.id and kind = 'joker' and used_at is null and not expired
      and granted_day < p_game.current_day - 1;
  end if;
  for v_p in select * from public.participants where game_id = p_game.id and role = 'spieler' and state in ('aktiv', 'ausserhalb', 'notfall') loop
    for i in 1..v_per loop
      select count(*) into v_have from public.inventory_items where participant_id = v_p.id and kind = 'joker' and used_at is null and not expired;
      exit when v_have >= v_max;
      v_t := case v_sel
        when 'fest_pro_tag' then v_types -> ((p_game.current_day - 1) % v_n)
        when 'spieler_waehlt' then jsonb_build_object('type', 'wahl')
        else v_types -> floor(random() * v_n)::int
      end;
      insert into public.inventory_items (game_id, participant_id, kind, type, minutes, granted_day, granted_at, source)
      values (p_game.id, v_p.id, 'joker', v_t ->> 'type', (v_t ->> 'minutes')::int, p_game.current_day, p_now, 'tag');
      perform public.notify(p_game.id, null, v_p.id, 'joker', 'Neuer Joker: ' || case v_t ->> 'type'
          when 'regeneration' then 'Regeneration'
          when 'hunter_erfragen' then 'Hunter-Standorte'
          when 'catch_free' then 'Catch-Free'
          when 'wahl' then 'freie Wahl'
          else replace(v_t ->> 'type', '_', ' ') end,
        case v_t ->> 'type'
          when 'regeneration' then 'Du wirst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gepingt. Einsetzen unter Aktionen.'
          when 'hunter_erfragen' then 'Zeigt dir 5 min lang, wo die Hunter sind. Einsetzen unter Aktionen.'
          when 'catch_free' then 'Du kannst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gefangen werden. Einsetzen unter Aktionen.'
          when 'wahl' then 'Du wählst beim Einsetzen, welcher Joker es wird. Unter Aktionen.'
          else '' end, '{}', 'normal');
    end loop;
  end loop;
end; $function$;

-- ===== 0012_ohne_spielleitung_am_stueck.sql =====

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

-- ===== 0013_ohne_budget.sql =====

-- Budget ist ganz entfernt: keine Käufe, kein Kauf-Ping, keine Beträge.
-- Noch nicht gestartete Spiele bekommen das Budget ausgeschaltet; Käufe melden ist gesperrt.

update public.games
  set config_json = config_json || '{"budget": {"enabled": false}}'::jsonb
  where status in ('entwurf', 'geplant', 'lobby');

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'make_purchase'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- ===== 0014_nur_ein_spielfeld.sql =====

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

-- ===== 0015_alarm_blitzjagd_joker.sql =====

-- Alarm bei jedem Ping und jeder Blitzjagd, Blitzjagd nur durch Hunter und ohne Zeitlimit, kein Schutzschild.
-- * Bei jedem Ping bekommen alle Spieler eine Meldung (der gepingte Spieler: "Du wurdest gepingt").
-- * Blitzjagden starten nur die Hunter: keine Zufalls-Blitzjagden, keine Straf-Blitzjagden.
--   Die Strafstufe dazwischen ist jetzt "15 min live sichtbar".
-- * Eine Blitzjagd hat keine Höchstdauer mehr.
-- * Der Joker "Schutzschild" (catch_free) ist entfernt.
-- * Der Alarm, wenn Spieler zusammen laufen, heisst Nähe-Alarm.

-- Noch nicht gestartete Spiele anpassen.
update public.games set config_json = config_json
  || jsonb_build_object('speedhunt', coalesce(config_json -> 'speedhunt', '{}'::jsonb) || '{"trigger_mode": "taskforce"}'::jsonb)
  || jsonb_build_object('ping', coalesce(config_json -> 'ping', '{}'::jsonb) - 'notify_player')
  || jsonb_build_object('penalty', coalesce(config_json -> 'penalty', '{}'::jsonb)
       || '{"escalation": ["verwarnung", "live_standort", "disqualifikation"]}'::jsonb)
where status in ('entwurf', 'geplant', 'lobby');

update public.games set config_json = jsonb_set(config_json, '{joker,types}', (
    select coalesce(jsonb_agg(t), '[]'::jsonb) from jsonb_array_elements(config_json #> '{joker,types}') t
    where t ->> 'type' <> 'catch_free'))
where status in ('entwurf', 'geplant', 'lobby') and jsonb_typeof(config_json #> '{joker,types}') = 'array';

-- Laufende Blitzjagden ohne Zeitlimit weiterführen.
update public.speedhunts set deadline_at = null where status = 'laeuft';

-- Nicht eingesetzte Schutzschild-Joker verfallen.
update public.inventory_items set expired = true where kind = 'joker' and type = 'catch_free' and used_at is null and not expired;

-- default_penalty (zuletzt in 0004_engine_logik.sql)
create or replace function public.default_penalty(p_cfg jsonb, p_type text)
returns text language sql immutable as $$
  select case p_type
    when 'ausserhalb_limit' then 'live_standort'
    when 'sperrzone' then 'verwarnung'
    when 'verschanzen_limit' then 'live_standort'
    when 'versteck_gesperrt' then 'live_standort'
    when 'oev_nicht_angemeldet' then 'live_standort'
    when 'fahrzeug_verbotene_zone' then 'live_standort'
    when 'faehren_limit' then 'verwarnung'
    when 'signalverlust' then 'live_standort'
    when 'hunter_hq' then 'verwarnung'
    else 'verwarnung'
  end;
$$;

-- apply_penalty (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
    -- Blitzjagden starten nur die Hunter; eine alte Stufe "Straf-Blitzjagd" wird zu 15 min live.
    when 'straf_speedhunt', 'live_standort' then
      if v_p.role <> 'spieler' then
        perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Verwarnung', replace(v.type, '_', ' '), '{}', 'hoch');
      else
        perform public.open_live_window(p_game.id, v.participant_id, 'strafe', p_now, p_now + interval '15 minutes');
        perform public.notify(p_game.id, null, v.participant_id, 'penalty', 'Strafe: 15 min live',
          'Die Hunter sehen dich 15 Minuten live (' || replace(v.type, '_', ' ') || ').', '{}', 'kritisch');
        perform public.notify(p_game.id, 'taskforce', null, 'penalty', public.pname(v.participant_id) || ' ist 15 min live',
          'Strafe: ' || replace(v.type, '_', ' '), '{}', 'hoch');
      end if;
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
    else
      null;
  end case;
end; $$;

-- start_speedhunt_internal (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
          null) -- keine Höchstdauer: endet, wenn alle Abfragen gemacht sind oder das Ziel gefangen ist
  returning * into v_sh;

  if p_status = 'laeuft' then
    update public.games set last_speedhunt_target = p_target where id = p_game.id;
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_start', 'BLITZJAGD!',
      v_text || ' Einer von euch wird gejagt.', jsonb_build_object('speedhunt_id', v_sh.id), 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_start',
      case when p_is_penalty then 'Straf-Blitzjagd: ' else 'Blitzjagd: ' end || public.pname(p_target),
      v_queries - v_used || ' Abfragen, ohne Zeitlimit',
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

-- speedhunt_query_internal (zuletzt in 0004_engine_logik.sql)
create or replace function public.speedhunt_query_internal(p_game public.games, p_sh public.speedhunts, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_pos record;
  v_n int := p_sh.queries_used + 1;
  v_ping uuid;
  v_live int := public.cfg_int(v_cfg, 'speedhunt', 'vehicle_live_seconds', 60);
  v_speed real;
  v_in_vehicle boolean;
begin
  select * into v_pos from public.best_position(p_sh.target_id, p_now);
  v_ping := public.create_ping(p_game, p_sh.target_id, 'speedhunt', v_pos.lat, v_pos.lng, v_pos.accuracy_m,
    case when v_pos.age_s > public.cfg_int(v_cfg, 'ping', 'max_age_seconds', 60) then v_pos.age_s end,
    v_n, p_sh.id, null, 0, p_now);
  update public.speedhunts set queries_used = v_n, last_query_at = p_now where id = p_sh.id;
  update public.participants set location_request_at = p_now where id = p_sh.target_id;

  select speed_mps into v_speed from public.positions where participant_id = p_sh.target_id;
  v_in_vehicle := exists (select 1 from public.transit_sessions where participant_id = p_sh.target_id and ended_at is null)
    or coalesce(v_speed, 0) * 3.6 > public.cfg_int(v_cfg, 'transport', 'speed_threshold_kmh', 8);
  if v_in_vehicle and v_live > 0 then
    perform public.open_live_window(p_game.id, p_sh.target_id, 'fahrzeug', p_now, p_now + make_interval(secs => v_live));
  end if;

  if public.cfg_bool(v_cfg, 'speedhunt', 'notify_each_query_to_players', true) then
    perform public.notify(p_game.id, 'spieler', null, 'speedhunt_query', 'BLITZJAGD: Abfrage ' || v_n || ' von ' || p_sh.queries_total,
      '', jsonb_build_object('speedhunt_id', p_sh.id), 'hoch');
  end if;
  perform public.notify(p_game.id, 'taskforce', null, 'speedhunt_query',
    'Abfrage ' || v_n || '/' || p_sh.queries_total || ': ' || public.pname(p_sh.target_id),
    case when v_in_vehicle and v_live > 0 then 'Ziel ist unterwegs: ' || v_live || ' s live.' else '' end,
    jsonb_build_object('speedhunt_id', p_sh.id, 'ping_id', v_ping), 'hoch');

  if v_n >= p_sh.queries_total then
    select * into p_sh from public.speedhunts where id = p_sh.id;
    perform public.end_speedhunt(p_game, p_sh, 'abfragen_aufgebraucht', p_now);
  end if;
  return v_ping;
end; $$;

-- process_ping_due (zuletzt in 0004_engine_logik.sql)
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

-- schedule_random_speedhunts: Blitzjagden starten nur noch die Hunter, nie der Zufall.
create or replace function public.schedule_random_speedhunts(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.games set state_json = state_json - 'random_speedhunts' where id = p_game.id;
end; $$;

-- check_proximity (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
        perform public.notify(p_game.id, 'taskforce', null, 'proximity', 'Nähe-Alarm',
          public.pname(v_pair.a_id) || ' und ' || public.pname(v_pair.b_id) || ' sind unter ' || v_dist || ' m.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.b_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'name', public.pname(v_pair.b_id)), 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.a_id) || ' ist in der Nähe',
          'Die Hunter wurden alarmiert.', jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'name', public.pname(v_pair.a_id)), 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.alerted then
      update public.proximity_pairs set alerted = false where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;

-- ===== 0016_ein_startpunkt_ohne_zentrale.sql =====

-- Ein Startpunkt für alle, keine Zentrale, keine Ping-Ungenauigkeit.
-- * Spieler und Hunter starten am selben Punkt (Zone `treffpunkt`). Den Wartebereich der Hunter (Zone `hq`)
--   legt die Datenbank selbst an diesen Punkt; die Hunter warten dort während des Vorsprungs.
-- * Die Rolle "Zentrale" gibt es nicht mehr: alle Hunter jagen gemeinsam unterwegs.
-- * Pings zeigen immer den genauen Ort (keine Ungenauigkeit).
-- * Spielfeld verlassen: 1. und 2. Mal Alarm und 1 Minute Countdown, danach live; ab dem 3. Mal sofort live.
-- * Gefahrenzone betreten: gleiche Regel mit eigener Zählung; zu lange drin = Folge wie ausserhalb.
-- * Joker Hunter-Standorte: einmaliger Ping aller Hunter im Moment des Einsetzens, bleibt mit Uhrzeit auf der Karte.

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

-- use_item: Hunter-Standorte als einmaliger Ping (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
      where p.game_id = g.id and p.role = 'hunter';
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
      values (g.id, v_me.id, 'hunter_snapshot', v_now, greatest(coalesce(g.deadline_at, g.ends_at), v_now + interval '5 minutes'), jsonb_build_object('hunters', v_snapshot), v_i.id);
      perform public.notify(g.id, null, v_me.id, 'joker', 'Hunter-Standorte', 'Einmaliger Ping aller Hunter von ' || to_char(v_now at time zone g.timezone, 'HH24:MI') || ', nicht live. Auf der Karte eingezeichnet.', jsonb_build_object('hunters', v_snapshot), 'hoch');
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

-- grant_jokers: Texte zu den Jokern (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
          when 'regeneration' then 'Du wirst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gepingt, und keine Blitzjagd auf dich ist möglich. Einsetzen unter Aktionen (nicht während einer Blitzjagd).'
          when 'hunter_erfragen' then 'Zeigt dir beim Einsetzen einmalig, wo alle Hunter gerade sind (nicht live). Einsetzen unter Aktionen.'
          when 'catch_free' then 'Du kannst ' || coalesce(v_t ->> 'minutes', '?') || ' min nicht gefangen werden. Einsetzen unter Aktionen.'
          else '' end, '{}', 'hoch');
    end loop;
  end loop;
end; $$;

-- Spielfeld verlassen: wie oft jemand draussen war.
alter table public.participants add column if not exists out_exits int not null default 0;
alter table public.participants add column if not exists danger_exits int not null default 0;

-- check_player_zone: Countdown beim 1. und 2. Verlassen, ab dem 3. Mal sofort live (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
  v_exits int := p_p.out_exits;
  v_danger int := p_p.danger_exits;
begin
  v_area := public.allowed_area(p_game.id, p_p.id, p_game.current_day, public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false));
  v_inside := v_area is null or ST_DWithin(v_area::geography, p_point::geography, v_tol);

  -- Gefahrenzonen: gleiche Regel wie beim Verlassen des Spielfelds, mit eigener Zählung.
  -- 1. und 2. Mal: Alarm und Countdown, danach live. Ab dem 3. Mal: sofort live. Zu lange drin: Folge wie ausserhalb.
  -- Zonen mit "Überqueren erlaubt" (z. B. Brücken) lösen nichts aus, solange man sie in der erlaubten Zeit überquert.
  select * into v_restricted from public.zones where game_id = p_game.id and kind = 'sperrzone' and ST_Covers(geom, p_point) limit 1;
  if v_restricted.id is not null and v_restricted.crossing_allowed then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false where id = p_p.id;
    elsif not p_p.restricted_violated and p_now - p_p.restricted_since > make_interval(secs => v_cross) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'sperrzone',
        jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
  elsif v_restricted.id is not null then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false,
        danger_exits = danger_exits + 1 where id = p_p.id
      returning danger_exits into v_danger;
      p_p.restricted_since := p_now;
      p_p.restricted_violated := false;
      if v_grace > 0 and v_danger <= 2 then
        perform public.notify(p_game.id, null, p_p.id, 'danger_warning', 'Gefahrenzone! Sofort raus',
          coalesce(nullif(v_restricted.name, ''), 'Gefahrenzone') || ': du hast ' || v_grace || ' Sekunden Zeit, sonst sehen dich die Hunter live ('
          || v_danger || '. Mal von 2 mit Countdown).',
          jsonb_build_object('deadline', p_now + make_interval(secs => v_grace), 'exits', v_danger), 'kritisch');
      else
        p_p.restricted_since := p_now - make_interval(secs => v_grace);
      end if;
    end if;
    if not p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.open_live_window(p_game.id, p_p.id, 'gefahrenzone', p_now, null);
      perform public.notify(p_game.id, null, p_p.id, 'danger_live', 'Du bist in einer Gefahrenzone!',
        'Die Hunter sehen dich live. Verlass die Zone sofort. Nach ' || v_max || ' min gilt: ' ||
        case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch') when 'catch' then 'gefangen' when 'disqualify' then 'disqualifiziert' else 'Strafe' end || '.',
        '{}', 'kritisch');
      perform public.notify(p_game.id, 'taskforce', null, 'danger_live', public.pname(p_p.id) || ' ist in einer Gefahrenzone', 'Live-Standort sichtbar.', '{}', 'hoch');
    elsif p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) + make_interval(mins => v_max) then
      update public.participants set restricted_zone_id = null, restricted_since = null, restricted_violated = false where id = p_p.id;
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
        when 'catch' then perform public.auto_catch(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        when 'disqualify' then perform public.disqualify(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        else perform public.create_violation(p_game, p_p.id, 'sperrzone', jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
      end case;
      return;
    end if;
  elsif p_p.restricted_zone_id is not null then
    if p_p.restricted_violated then
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      perform public.notify(p_game.id, 'taskforce', null, 'back_inside', public.pname(p_p.id) || ' hat die Gefahrenzone verlassen', 'Live-Standort beendet.', '{}', 'normal');
    end if;
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
    -- Jedes Verlassen zählt. 1. und 2. Mal: Alarm und Countdown. Ab dem 3. Mal: sofort live.
    update public.participants set out_pending_since = p_now, out_exits = out_exits + 1 where id = p_p.id
    returning out_exits into v_exits;
    if v_grace > 0 and v_exits <= 2 then
      perform public.notify(p_game.id, null, p_p.id, 'outside_warning', 'Zurück ins Spielfeld!',
        'Du hast ' || v_grace || ' Sekunden Zeit, sonst sehen dich die Hunter live (' || v_exits || '. Mal von 2 mit Countdown).',
        jsonb_build_object('deadline', p_now + make_interval(secs => v_grace), 'exits', v_exits), 'kritisch');
      return;
    end if;
    p_p.out_pending_since := p_now - make_interval(secs => v_grace);
  end if;
  if p_now - p_p.out_pending_since >= make_interval(secs => v_grace) then
    update public.participants set state = 'ausserhalb' where id = p_p.id;
    -- Immer live an die Hunter, solange die Person ausserhalb ist.
    perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
    perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb!',
      case when v_exits > 2 then 'Schon das ' || v_exits || '. Mal: kein Countdown mehr. ' else '' end ||
      greatest(0, v_max - p_p.out_accum_s / 60) || ' min bis ' ||
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'disqualify')
        when 'catch' then 'zum Fang' when 'disqualify' then 'zur Disqualifikation' else 'zur Strafe' end || '. Die Hunter sehen dich live.',
      '{}', 'kritisch');
    perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
  end if;
end; $$;

-- ===== 0017_ohne_strafen_sos_fluchtpunkt.sql =====

-- Keine Strafen, Fortbewegung nur erlaubt/verboten, Nähe-Alarm mit Timer, SOS unterbricht das Spiel,
-- Fluchtpunkt erst bei der Bekanntgabe zufällig gewählt und nur für Spieler.
-- * Keine Strafen mehr: Verstösse werden nicht mehr erfasst. Folgen gibt es nur noch, wo sie zum Spiel gehören
--   (zu lange ausserhalb, in einer Gefahrenzone oder verschanzt: gefangen). Ein Hunter, der den Startpunkt
--   während des Vorsprungs verlässt, bekommt nur einen Alarm.
-- * Fortbewegung: nur noch erlaubt oder nicht (ÖV/Taxi/Auto und Velo/Trottinett), ohne Anmelden und ohne Live-Standort.
-- * Nähe-Alarm: zuerst werden beide Spieler gewarnt und sehen sich gegenseitig; erst wenn sie nach der eingestellten
--   Zeit noch zu nahe sind, bekommen die Hunter den Ping beider. Ab der Bekanntgabe des Fluchtpunkts aus.
-- * SOS: das ganze Spiel wird unterbrochen, alle werden mit dem Standort alarmiert und sollen helfen.
--   Ist kein Notfall mehr offen, geht das Spiel weiter; die unterbrochene Zeit wird angehängt.
-- * Fluchtpunkt: mindestens 4 Kandidaten; die App wählt erst bei der Bekanntgabe zufällig einen (im aktuellen
--   Spielfeld). Nur die Spieler erfahren ihn, alle denselben; die Hunter nie.

-- Noch nicht gestartete Spiele anpassen.
update public.games set config_json = config_json
  || jsonb_build_object('transport', coalesce(config_json -> 'transport', '{}'::jsonb)
       || '{"checkin_required": false, "live_during": false, "live_after_base_minutes": 0, "live_after_increment_minutes": 0}'::jsonb)
  || jsonb_build_object('speedhunt', coalesce(config_json -> 'speedhunt', '{}'::jsonb) || '{"vehicle_live_seconds": 0}'::jsonb)
  || jsonb_build_object('out_of_bounds', coalesce(config_json -> 'out_of_bounds', '{}'::jsonb) || '{"on_timeout": "catch"}'::jsonb)
  || jsonb_build_object('hideout', coalesce(config_json -> 'hideout', '{}'::jsonb) || '{"on_timeout": "catch", "lockout_after_first_entry_minutes": 0}'::jsonb)
  || jsonb_build_object('zone', coalesce(config_json -> 'zone', '{}'::jsonb) || '{"shrink_grace_minutes": 0}'::jsonb)
  || jsonb_build_object('exit', coalesce(config_json -> 'exit', '{}'::jsonb) || '{"reveal_to_taskforce": "nie", "random_from_candidates": true}'::jsonb)
where status in ('entwurf', 'geplant', 'lobby');
update public.games set config_json = config_json - 'penalty' where status in ('entwurf', 'geplant', 'lobby');

-- Nähe-Alarm: Zeitpunkt der Warnung je Paar.
alter table public.proximity_pairs add column if not exists warned_at timestamptz;

-- create_violation: keine Strafen mehr. Nur ein Hunter, der zu früh vom Startpunkt weggeht, bekommt einen Alarm.
create or replace function public.create_violation(p_game public.games, p_participant_id uuid, p_type text,
  p_evidence jsonb, p_now timestamptz, p_penalty text default null, p_detected_by text default 'auto')
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if p_type = 'hunter_hq' and not exists (
    select 1 from public.notifications where game_id = p_game.id and recipient_id = p_participant_id
      and kind = 'hunter_early' and at > p_now - interval '1 minute') then
    perform public.notify(p_game.id, null, p_participant_id, 'hunter_early', 'Zurück zum Startpunkt!',
      'Der Vorsprung der Spieler läuft noch. Die Jagd beginnt um ' || to_char(p_game.hunt_start_at at time zone p_game.timezone, 'HH24:MI') || '.',
      '{}', 'kritisch');
  end if;
  return null;
end; $$;

-- check_transport: Fortbewegung ist nur noch erlaubt oder nicht; die App prüft und meldet nichts mehr.
create or replace function public.check_transport(p_game public.games, p_p public.participants, p_point extensions.geometry, p_speed real, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  return;
end; $$;

-- check_proximity: erst warnen (beide sehen sich), nach der eingestellten Zeit Ping an die Hunter.
create or replace function public.check_proximity(p_game public.games, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_dist int := public.cfg_int(v_cfg, 'proximity', 'distance_m', 150);
  v_hyst int := public.cfg_int(v_cfg, 'proximity', 'hysteresis_m', 50);
  v_wait int := public.cfg_int(v_cfg, 'proximity', 'warn_minutes', 2);
  v_pair record;
  v_state public.proximity_pairs;
begin
  if not public.cfg_bool(v_cfg, 'proximity', 'enabled', true) then return; end if;
  -- Ab der Bekanntgabe des Fluchtpunkts dürfen die Spieler zusammen sein.
  if p_game.exit_revealed then return; end if;
  if p_now < p_game.hunt_start_at + make_interval(mins => public.cfg_int(v_cfg, 'proximity', 'active_after_minutes', 10)) then return; end if;

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
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.b_id) || ' ist in der Nähe',
          'Ihr seid unter ' || v_dist || ' m. Entfernt euch innerhalb von ' || v_wait || ' min, sonst bekommen die Hunter euren Standort.',
          jsonb_build_object('lat', v_pair.blat, 'lng', v_pair.blng, 'name', public.pname(v_pair.b_id), 'deadline', p_now + make_interval(mins => v_wait)), 'kritisch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_self', 'Nähe-Alarm: ' || public.pname(v_pair.a_id) || ' ist in der Nähe',
          'Ihr seid unter ' || v_dist || ' m. Entfernt euch innerhalb von ' || v_wait || ' min, sonst bekommen die Hunter euren Standort.',
          jsonb_build_object('lat', v_pair.alat, 'lng', v_pair.alng, 'name', public.pname(v_pair.a_id), 'deadline', p_now + make_interval(mins => v_wait)), 'kritisch');
      elsif not v_state.alerted and p_now >= v_state.warned_at + make_interval(mins => v_wait) then
        -- 2. Nach Ablauf immer noch zu nahe: Ping beider an die Hunter.
        update public.proximity_pairs set alerted = true, last_alert_at = p_now where a = v_pair.a_id and b = v_pair.b_id;
        if not public.has_effect(v_pair.a_id, 'regeneration', p_now) then
          perform public.create_ping(p_game, v_pair.a_id, 'proximity', v_pair.alat, v_pair.alng, v_pair.aacc, null, null, null, null, 0, p_now);
        end if;
        if not public.has_effect(v_pair.b_id, 'regeneration', p_now) then
          perform public.create_ping(p_game, v_pair.b_id, 'proximity', v_pair.blat, v_pair.blng, v_pair.bacc, null, null, null, null, 0, p_now);
        end if;
        perform public.notify(p_game.id, 'taskforce', null, 'proximity', 'Nähe-Alarm',
          public.pname(v_pair.a_id) || ' und ' || public.pname(v_pair.b_id) || ' sind zusammen (unter ' || v_dist || ' m). Ping auf der Karte.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.a_id, 'proximity_ping', 'Die Hunter haben euren Standort', 'Ihr wart zu lange zusammen.', '{}', 'hoch');
        perform public.notify(p_game.id, null, v_pair.b_id, 'proximity_ping', 'Die Hunter haben euren Standort', 'Ihr wart zu lange zusammen.', '{}', 'hoch');
      end if;
    elsif v_pair.d > v_dist + v_hyst and v_state.a is not null and (v_state.warned_at is not null or v_state.alerted) then
      update public.proximity_pairs set alerted = false, warned_at = null where a = v_pair.a_id and b = v_pair.b_id;
    end if;
  end loop;
end; $$;

-- resume_internal: Spiel nach einem Notfall fortsetzen (ohne Rechteprüfung, nur intern)
create or replace function public.resume_internal(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_now timestamptz;
  d interval;
  v_ext boolean;
begin
  select * into g from public.games where id = p_game_id for update;
  if g.paused_at is null then return; end if;
  v_now := public.engine_now(p_game_id);
  d := v_now - g.paused_at;
  v_ext := true; -- die unterbrochene Zeit wird angehängt
  update public.games set paused_at = null, pause_reason = null, last_tick_at = v_now,
    hunt_start_at = case when status = 'vorsprung' then hunt_start_at + d else hunt_start_at end,
    ends_at = case when v_ext then ends_at + d else ends_at end,
    deadline_at = case when v_ext then deadline_at + d else deadline_at end,
    exit_reveal_at = case when v_ext then exit_reveal_at + d else exit_reveal_at end,
    next_day_at = case when v_ext then next_day_at + d else next_day_at end
  where id = p_game_id;
  update public.participants set next_ping_at = next_ping_at + d, ping_pending_until = ping_pending_until + d,
    grace_until = grace_until + d, out_pending_since = out_pending_since + d, stationary_since = stationary_since + d,
    speeding_since = speeding_since + d, transport_prompted_at = transport_prompted_at + d
  where game_id = p_game_id;
  update public.speedhunts set deadline_at = deadline_at + d where game_id = p_game_id and status = 'laeuft';
  update public.active_effects set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.live_windows set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.violations set auto_apply_at = auto_apply_at + d where game_id = p_game_id and status = 'offen';
  update public.catches set expires_at = expires_at + d where game_id = p_game_id and expires_at > g.paused_at;
  update public.challenges set starts_at = starts_at + d, ends_at = ends_at + d, announce_at = announce_at + d
    where game_id = p_game_id and status in ('geplant', 'angekuendigt', 'laeuft');
  update public.games set state_json = jsonb_set(state_json, '{next_phase_at}', to_jsonb((state_json ->> 'next_phase_at')::timestamptz + d))
    where id = p_game_id and v_ext and (state_json ->> 'next_phase_at') is not null;
  update public.zones set visible_from = visible_from + d where game_id = p_game_id and visible_from > g.paused_at and visible_from <> 'infinity' and v_ext;
  perform public.notify(p_game_id, 'alle', null, 'resume', 'Weiter geht''s!', 'Der Notfall ist beendet. Das Spiel läuft wieder, die unterbrochene Zeit wird angehängt.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'resumed', jsonb_build_object('seconds', extract(epoch from d)::int));
  perform public.bump(p_game_id);
end; $$;
revoke all on function public.resume_internal(uuid) from public, anon, authenticated;

-- emergency_start (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
  -- Das ganze Spiel wird unterbrochen; alle werden mit dem Standort alarmiert und sollen helfen.
  if g.status in ('vorsprung', 'laeuft', 'finale') then
    update public.games set paused_at = v_now, pause_reason = 'Notfall: ' || public.pname(v_me.id) where id = p_game_id and paused_at is null;
  end if;
  perform public.notify(p_game_id, 'alle', null, 'emergency', 'NOTFALL: ' || public.pname(v_me.id) || ' braucht Hilfe',
    'Das Spiel ist unterbrochen. Geht sofort zum Standort auf der Karte und helft. Bei Gefahr: 117 Polizei, 144 Sanität, 112 Notruf.',
    jsonb_build_object('emergency_id', v_id, 'lat', coalesce(p_lat, v_pos.lat), 'lng', coalesce(p_lng, v_pos.lng)), 'kritisch');
  perform public.notify(p_game_id, null, v_me.id, 'emergency_self', 'Notfall gemeldet',
    'Alle sind alarmiert und sehen deinen Standort. Das Spiel ist unterbrochen. Bei Gefahr: Polizei 117, Sanität 144, Notruf 112.', jsonb_build_object('emergency_id', v_id), 'kritisch');
  perform public.log_game_event(p_game_id, 'emergency', jsonb_build_object('participant', v_me.id));
  perform public.bump(p_game_id);
  return v_id;
end; $$;

-- emergency_resolve (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
  if not (public.is_game_host(g.id) or v_me.id = v_e.participant_id) then
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
  -- Kein Notfall mehr offen: das Spiel geht weiter.
  if g.paused_at is not null and not exists (select 1 from public.emergencies where game_id = g.id and status = 'offen') then
    perform public.resume_internal(g.id);
  end if;
  perform public.bump(g.id);
end; $$;

-- start_game (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
  select count(*) filter (where role = 'spieler'), count(*) filter (where role = 'hunter'), count(*) filter (where role = 'offen')
    into v_players, v_hunters, v_open from public.participants where game_id = p_game_id;
  if v_open > 0 then raise exception 'Noch % Person(en) ohne Rolle.', v_open using errcode = 'P0001'; end if;
  if v_players < 1 then raise exception 'Mindestens 1 Spieler nötig.' using errcode = 'P0001'; end if;
  if v_hunters < 1 then raise exception 'Mindestens 1 Hunter nötig.' using errcode = 'P0001'; end if;
  if v_players > public.cfg_int(v_cfg, 'roles', 'players_max', 9) then raise exception 'Zu viele Spieler für die Regeln.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'spielfeld') then
    raise exception 'Zeichne zuerst ein Spielfeld auf der Karte.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'treffpunkt') then
    raise exception 'Setze den Startpunkt auf der Karte.' using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
     and (select count(*) from public.zones where game_id = p_game_id and kind = 'exit') < 4 then
    raise exception 'Setze mindestens 4 Fluchtpunkt-Kandidaten auf der Karte (oder schalte den Fluchtpunkt aus).' using errcode = 'P0001';
  end if;

  -- Kartenprüfungen (22.4)
  if exists (
    select 1 from public.zones t
    where t.game_id = p_game_id and t.kind = 'treffpunkt'
      and public.spielfeld_day(p_game_id, 1) is not null
      and not ST_DWithin(public.spielfeld_day(p_game_id, 1)::geography, t.geom::geography, 25)
  ) then
    raise exception 'Der Startpunkt liegt ausserhalb des Spielfelds.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.zones p join public.zones s on s.game_id = p.game_id and s.kind = 'sperrzone'
    where p.game_id = p_game_id and p.kind in ('treffpunkt', 'exit', 'hq') and ST_Intersects(s.geom, p.geom)
  ) then
    raise exception 'Der Startpunkt oder ein Fluchtpunkt liegt in einer Gefahrenzone.' using errcode = 'P0001';
  end if;

  -- Fluchtpunkt: alle Kandidaten sind während des Spiels verborgen; gewählt wird erst bei der Bekanntgabe.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit';
  end if;

  -- Automatische Verkleinerung: um x % (Fläche) Richtung Mitte des Spielfelds (der Fluchtpunkt steht noch nicht fest).
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
      + case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then public.cfg_int(v_cfg, 'exit', 'arrival_deadline_offset_minutes', 15) else 0 end),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then g.hunt_start_at
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
    'Wartet am Startpunkt. Die Jagd beginnt um ' || to_char(g.hunt_start_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'game_started', jsonb_build_object('test', p_test));
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;

-- tick_game (zuletzt in 0012_ohne_spielleitung_am_stueck.sql)
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
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
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
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    -- Erst jetzt zufällig einen Kandidaten wählen, bevorzugt im aktuellen Spielfeld. Nur die Spieler sehen ihn.
    if g.exit_zone_id is null then
      update public.games set exit_zone_id = (
        select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
        order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.field_phase(g.id, g.current_day)), z.geom), z.geom) then 0 else 1 end, random()
        limit 1)
      where id = g.id returning * into g;
    end if;
    update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '. Ab jetzt dürft ihr auch zusammen sein.', '{}', 'kritisch');
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
      'Ihr erfahrt ihn nicht. Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
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

-- game_state: offene Notfälle sehen alle (zuletzt in 0008_zonen_phasen.sql)
create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  me public.participants;
  v_role text;
  v_now timestamptz;
  v_tf boolean;
  v_gm boolean;
  v_ended boolean;
  v_delay int;
  v_hist int;
  v_out jsonb;
begin
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if me.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  v_cfg := g.config_json;
  v_role := me.role;
  v_now := now() + g.clock_offset;
  v_gm := v_role = 'gm';
  v_tf := v_role in ('hunter', 'zentrale');
  v_ended := g.status in ('beendet', 'archiviert');
  v_delay := public.cfg_int(v_cfg, 'spectator', 'delay_minutes', 30);
  v_hist := public.cfg_int(v_cfg, 'ping', 'history_per_player', 5);

  v_out := jsonb_build_object(
    'now', v_now,
    'server_now', now(),
    'game', jsonb_build_object(
      'id', g.id, 'name', g.name, 'code', g.code, 'status', g.status, 'is_test', g.is_test, 'host', g.host_id = auth.uid(),
      'start_at', g.start_at, 'hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at, 'deadline_at', g.deadline_at,
      'next_day_at', g.next_day_at, 'current_day', g.current_day,
      'phase', public.field_phase(g.id, g.current_day), 'phase_count', public.phase_count(v_cfg),
      'next_phase_at', case when public.shrink_every_minutes(v_cfg) > 0 then (g.state_json ->> 'next_phase_at')::timestamptz else g.next_day_at end, 'paused', g.paused_at is not null, 'pause_reason', g.pause_reason,
      'timezone', g.timezone, 'speedhunts_left', g.speedhunts_left, 'exit_revealed', g.exit_revealed, 'exit_reveal_at', g.exit_reveal_at,
      'map_version', g.map_version, 'result', g.result_json, 'meeting_point', g.meeting_point, 'config', v_cfg, 'group_id', g.group_id,
      'quiet', public.in_quiet_hours(g, v_now)
    ),
    'me', jsonb_build_object(
      'id', me.id, 'role', me.role, 'state', me.state, 'budget', me.budget_balance, 'bounty', me.bounty,
      'next_ping_at', case when v_role = 'spieler' then me.next_ping_at end,
      'location_requested', me.location_request_at is not null,
      'hideout_prompt', me.hideout_prompted_at is not null and not exists (select 1 from public.hideouts where participant_id = me.id and status = 'aktiv' and inside),
      'transport_prompt', me.transport_prompted_at is not null,
      'out_accum_s', me.out_accum_s, 'out_pending', me.out_pending_since is not null, 'in_restricted', me.restricted_zone_id is not null,
      'briefing_done', me.briefing_done_day = g.current_day,
      'live', public.has_live_window(me.id, v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.type, 'ends_at', e.ends_at, 'payload', e.payload)), '[]')
                  from public.active_effects e where e.participant_id = me.id and e.starts_at <= v_now and (e.ends_at is null or e.ends_at > v_now) and not (e.payload ? 'done')),
      'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'source', i.source) order by i.granted_at), '[]')
                    from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired),
      'hideout', (select jsonb_build_object('id', h.id, 'inside', h.inside, 'accum_s', h.accum_s, 'entered_at', h.entered_at,
                    'max_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))
                  from public.hideouts h where h.participant_id = me.id and h.status = 'aktiv' limit 1),
      'transit', (select jsonb_build_object('id', t.id, 'mode', t.mode, 'line', t.line, 'started_at', t.started_at)
                  from public.transit_sessions t where t.participant_id = me.id and t.ended_at is null limit 1),
      'device_check', me.device_check
    ),
    'participants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', pr.display_name, 'username', pr.username, 'role', p.role, 'color', p.color,
        'state', case when v_gm or v_ended or p.id = me.id or p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren', 'ausserhalb', 'notfall') then p.state else 'aktiv' end,
        'battery', case when v_gm or (v_tf and p.role in ('hunter', 'zentrale')) then p.battery end,
        'last_seen_at', case when v_gm then p.last_seen_at end,
        'bounty', p.bounty,
        'budget', case when v_gm then p.budget_balance end,
        'device_check', case when v_gm or p.id = me.id or g.status in ('lobby', 'geplant', 'entwurf') then p.device_check end,
        'next_ping_at', case when (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true)) or v_gm then p.next_ping_at end,
        'protected', case when v_tf or v_gm then (public.has_effect(p.id, 'regeneration', v_now) or public.has_effect(p.id, 'hotel', v_now)) end,
        'catch_free', case when v_tf or v_gm then public.has_effect(p.id, 'catch_free', v_now) end,
        'briefing_done', p.briefing_done_day = g.current_day
      ) order by p.role, pr.display_name), '[]')
      from public.participants p join public.profiles pr on pr.user_id = p.user_id
      where p.game_id = g.id
    ),
    -- Positionen: Spielleitung alles, Taskforce die eigenen Leute und Spieler im Live-Fenster,
    -- Spieler nur sich selbst, Zuschauer verzögert (5.2, 7.18).
    'positions', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', x.participant_id, 'lat', x.lat, 'lng', x.lng, 'accuracy_m', x.accuracy_m,
        'speed_mps', x.speed_mps, 'heading', x.heading, 'at', x.at, 'live', x.live)), '[]')
      from (
        select pos.participant_id, pos.lat, pos.lng, pos.accuracy_m, pos.speed_mps, pos.heading, pos.at,
               public.has_live_window(pos.participant_id, v_now) live
        from public.positions pos join public.participants p on p.id = pos.participant_id
        where pos.game_id = g.id and v_role <> 'zuschauer' and (
          v_gm or v_ended or pos.participant_id = me.id
          or (v_tf and p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'taskforce', 'share_positions_internally', true))
          or (v_tf and p.role = 'spieler' and public.has_live_window(p.id, v_now) and p.state in ('aktiv', 'ausserhalb', 'notfall'))
          or (v_role = 'spieler' and p.role = 'spieler' and p.state = 'notfall')
        )
        union all
        (select distinct on (s.participant_id) s.participant_id, ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.speed_mps, s.heading, s.at, false
        from public.location_samples s
        where s.game_id = g.id and v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false)
          and s.at <= v_now - make_interval(mins => v_delay)
        order by s.participant_id, s.at desc)
      ) x
    ),
    -- Pings: Taskforce sieht die letzten n je Spieler (ohne Fake-Markierung), Spieler die eigenen,
    -- Spielleitung alles inkl. echter Position, Zuschauer verzögert.
    'pings', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds,
        'is_fake', case when v_gm or v_ended or x.participant_id = me.id then x.is_fake end,
        'truth', case when (v_gm or v_ended) and x.is_fake then (select jsonb_build_object('lat', t.lat, 'lng', t.lng) from public.ping_truth t where t.ping_id = x.id) end
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg
        where pg.game_id = g.id and (
          v_gm or v_ended
          or (v_tf and pg.visible_at <= v_now)
          or (v_role = 'spieler' and pg.participant_id = me.id)
          or (v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false) and pg.visible_at <= v_now - make_interval(mins => v_delay))
        )
      ) x where x.rn <= case when v_gm or v_ended then 1000 else v_hist end
    ),
    'speedhunts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty,
        'target_id', case when v_gm or v_tf or v_ended or (s.target_id = me.id and public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false)) then s.target_id end,
        'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
        'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
      from public.speedhunts s where s.game_id = g.id and (s.status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') or s.ended_at > v_now - interval '2 hours' or v_gm or v_ended)
        and (s.status <> 'wartet_auf_freigabe' or v_gm or v_tf) and (s.status <> 'aufgeschoben' or v_gm or v_tf)
        and not (s.status = 'beendet' and s.started_at is null and not v_gm)
    ),
    'catches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'runner_id', c.runner_id, 'hunter_id', c.hunter_id, 'at', c.at, 'method', c.method,
        'status', c.status, 'expires_at', c.expires_at, 'distance_m', c.distance_m, 'reason', c.reason, 'lat', case when v_gm or v_ended then c.lat end,
        'lng', case when v_gm or v_ended then c.lng end) order by c.at desc), '[]')
      from public.catches c where c.game_id = g.id and (c.status = 'gueltig' or v_gm or c.runner_id = me.id or c.hunter_id = me.id)
    ),
    'violations', (
      select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'participant_id', v.participant_id, 'type', v.type, 'at', v.at, 'evidence', v.evidence,
        'proposed_penalty', v.proposed_penalty, 'decided_penalty', v.decided_penalty, 'status', v.status, 'auto_apply_at', v.auto_apply_at,
        'explanation', v.explanation, 'detected_by', v.detected_by) order by v.at desc), '[]')
      from public.violations v where v.game_id = g.id and (v_gm or v.participant_id = me.id or v_ended)
    ),
    'challenges', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'description', c.description, 'template', c.template,
        'lat', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lat end,
        'lng', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lng end,
        'radius_m', c.radius_m, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'announce_at', c.announce_at, 'proof_type', c.proof_type,
        'secret_code', case when v_gm then c.secret_code end, 'reward_type', c.reward_type, 'reward_value', c.reward_value, 'status', c.status,
        'max_participants', c.max_participants,
        'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'result', e.result, 'proof_path', case when v_gm then e.proof_path end, 'proof_text', case when v_gm then e.proof_text end)), '[]')
                    from public.challenge_entries e where e.challenge_id = c.id and (v_gm or e.participant_id = me.id or v_ended))
      ) order by c.starts_at), '[]')
      from public.challenges c where c.game_id = g.id and (v_gm or c.status <> 'geplant')
    ),
    'emergencies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'status', e.status)), '[]')
      from public.emergencies e where e.game_id = g.id and e.status = 'offen'
    ),
    'transits', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', t.participant_id, 'mode', t.mode, 'line', t.line, 'from', t.from_station, 'to', t.to_station,
        'started_at', t.started_at)), '[]')
      from public.transit_sessions t where t.game_id = g.id and t.ended_at is null and (v_gm or v_tf or t.participant_id = me.id)
    ),
    'hideouts', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', h.participant_id, 'inside', h.inside, 'accum_s', h.accum_s, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))), '[]')
      from public.hideouts h where h.game_id = g.id and h.status = 'aktiv' and v_gm
    ),
    'purchases', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', u.participant_id, 'amount', u.amount, 'category', u.category, 'note', u.note, 'at', u.at) order by u.at desc), '[]')
      from public.purchases u where u.game_id = g.id and (v_gm or u.participant_id = me.id)
    ),
    'notifications', (
      select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
        select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
        from public.notifications n where n.game_id = g.id and public.can_see_notification(n)
        order by n.id desc limit 60
      ) q
    ),
    'next_silent_ping_at', case when v_gm or (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true))
      then (select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb')) end,
    'free_players', public.free_players(g.id)
  );
  return v_out;
end; $$;

-- ===== 0018_host_sieht_karte_in_lobby.sql =====

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

-- ===== 0019_fluchtpunkte_innerste_zone.sql =====

-- Fluchtpunkte in der innersten Zone.
-- Beim Start prüft die App, dass jeder Fluchtpunkt-Kandidat im Spielfeld der letzten Phase liegt.
-- Liegt einer weiter aussen, wäre er nach der Verkleinerung nicht mehr erreichbar.

-- start_game: prüft zusätzlich, dass alle Fluchtpunkte in der innersten Zone liegen (zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql)
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
  select count(*) filter (where role = 'spieler'), count(*) filter (where role = 'hunter'), count(*) filter (where role = 'offen')
    into v_players, v_hunters, v_open from public.participants where game_id = p_game_id;
  if v_open > 0 then raise exception 'Noch % Person(en) ohne Rolle.', v_open using errcode = 'P0001'; end if;
  if v_players < 1 then raise exception 'Mindestens 1 Spieler nötig.' using errcode = 'P0001'; end if;
  if v_hunters < 1 then raise exception 'Mindestens 1 Hunter nötig.' using errcode = 'P0001'; end if;
  if v_players > public.cfg_int(v_cfg, 'roles', 'players_max', 9) then raise exception 'Zu viele Spieler für die Regeln.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'spielfeld') then
    raise exception 'Zeichne zuerst ein Spielfeld auf der Karte.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'treffpunkt') then
    raise exception 'Setze den Startpunkt auf der Karte.' using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
     and (select count(*) from public.zones where game_id = p_game_id and kind = 'exit') < 4 then
    raise exception 'Setze mindestens 4 Fluchtpunkt-Kandidaten auf der Karte (oder schalte den Fluchtpunkt aus).' using errcode = 'P0001';
  end if;

  -- Kartenprüfungen (22.4)
  if exists (
    select 1 from public.zones t
    where t.game_id = p_game_id and t.kind = 'treffpunkt'
      and public.spielfeld_day(p_game_id, 1) is not null
      and not ST_DWithin(public.spielfeld_day(p_game_id, 1)::geography, t.geom::geography, 25)
  ) then
    raise exception 'Der Startpunkt liegt ausserhalb des Spielfelds.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.zones p join public.zones s on s.game_id = p.game_id and s.kind = 'sperrzone'
    where p.game_id = p_game_id and p.kind in ('treffpunkt', 'exit', 'hq') and ST_Intersects(s.geom, p.geom)
  ) then
    raise exception 'Der Startpunkt oder ein Fluchtpunkt liegt in einer Gefahrenzone.' using errcode = 'P0001';
  end if;

  -- Fluchtpunkt: alle Kandidaten sind während des Spiels verborgen; gewählt wird erst bei der Bekanntgabe.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit';
  end if;

  -- Automatische Verkleinerung: um x % (Fläche) Richtung Mitte des Spielfelds (der Fluchtpunkt steht noch nicht fest).
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

  -- Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase), sonst sind sie am Ende nicht erreichbar.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and exists (
    select 1 from public.zones e
    where e.game_id = p_game_id and e.kind = 'exit'
      and not ST_DWithin(public.spielfeld_day(p_game_id, greatest(v_days, 1))::geography, e.geom::geography, 5)
  ) then
    raise exception 'Alle Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase).' using errcode = 'P0001';
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
      + case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then public.cfg_int(v_cfg, 'exit', 'arrival_deadline_offset_minutes', 15) else 0 end),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then g.hunt_start_at
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
    'Wartet am Startpunkt. Die Jagd beginnt um ' || to_char(g.hunt_start_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'game_started', jsonb_build_object('test', p_test));
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;

-- ===== 0020_nummern.sql =====

-- Feste Nummern für Spieler (1, 2, 3 …) und Hunter (H1, H2 …), vergeben beim Start in der Reihenfolge der Lobby.
-- Die Nummer steht in den Punkten auf der Karte (Pings, Positionen) und neben den Namen.
alter table public.participants add column if not exists tag text;

-- start_game: vergibt beim Start feste Nummern (zuletzt in 0019_fluchtpunkte_innerste_zone.sql)
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
  select count(*) filter (where role = 'spieler'), count(*) filter (where role = 'hunter'), count(*) filter (where role = 'offen')
    into v_players, v_hunters, v_open from public.participants where game_id = p_game_id;
  if v_open > 0 then raise exception 'Noch % Person(en) ohne Rolle.', v_open using errcode = 'P0001'; end if;
  if v_players < 1 then raise exception 'Mindestens 1 Spieler nötig.' using errcode = 'P0001'; end if;
  if v_hunters < 1 then raise exception 'Mindestens 1 Hunter nötig.' using errcode = 'P0001'; end if;
  if v_players > public.cfg_int(v_cfg, 'roles', 'players_max', 9) then raise exception 'Zu viele Spieler für die Regeln.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'spielfeld') then
    raise exception 'Zeichne zuerst ein Spielfeld auf der Karte.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.zones where game_id = p_game_id and kind = 'treffpunkt') then
    raise exception 'Setze den Startpunkt auf der Karte.' using errcode = 'P0001';
  end if;
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and public.cfg_text(v_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
     and (select count(*) from public.zones where game_id = p_game_id and kind = 'exit') < 4 then
    raise exception 'Setze mindestens 4 Fluchtpunkt-Kandidaten auf der Karte (oder schalte den Fluchtpunkt aus).' using errcode = 'P0001';
  end if;

  -- Kartenprüfungen (22.4)
  if exists (
    select 1 from public.zones t
    where t.game_id = p_game_id and t.kind = 'treffpunkt'
      and public.spielfeld_day(p_game_id, 1) is not null
      and not ST_DWithin(public.spielfeld_day(p_game_id, 1)::geography, t.geom::geography, 25)
  ) then
    raise exception 'Der Startpunkt liegt ausserhalb des Spielfelds.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.zones p join public.zones s on s.game_id = p.game_id and s.kind = 'sperrzone'
    where p.game_id = p_game_id and p.kind in ('treffpunkt', 'exit', 'hq') and ST_Intersects(s.geom, p.geom)
  ) then
    raise exception 'Der Startpunkt oder ein Fluchtpunkt liegt in einer Gefahrenzone.' using errcode = 'P0001';
  end if;

  -- Fluchtpunkt: alle Kandidaten sind während des Spiels verborgen; gewählt wird erst bei der Bekanntgabe.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) then
    update public.zones set visible_to = 'gm' where game_id = p_game_id and kind = 'exit';
  end if;

  -- Automatische Verkleinerung: um x % (Fläche) Richtung Mitte des Spielfelds (der Fluchtpunkt steht noch nicht fest).
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

  -- Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase), sonst sind sie am Ende nicht erreichbar.
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and exists (
    select 1 from public.zones e
    where e.game_id = p_game_id and e.kind = 'exit'
      and not ST_DWithin(public.spielfeld_day(p_game_id, greatest(v_days, 1))::geography, e.geom::geography, 5)
  ) then
    raise exception 'Alle Fluchtpunkte müssen in der innersten Zone liegen (Spielfeld der letzten Phase).' using errcode = 'P0001';
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
  -- Feste Nummern: Spieler 1, 2, 3 … und Hunter H1, H2 … in der Reihenfolge der Lobby.
  update public.participants p set tag = case when n.role = 'hunter' then 'H' else '' end || n.rn
  from (select id, role, row_number() over (partition by role order by joined_at, id) rn
        from public.participants where game_id = p_game_id and role in ('spieler', 'hunter')) n
  where p.id = n.id;
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
      + case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then public.cfg_int(v_cfg, 'exit', 'arrival_deadline_offset_minutes', 15) else 0 end),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true) then g.hunt_start_at
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
    'Wartet am Startpunkt. Die Jagd beginnt um ' || to_char(g.hunt_start_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'game_started', jsonb_build_object('test', p_test));
  perform public.tick_game(p_game_id);
  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;

-- game_state: mit Nummer (tag) je Person (zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql)
create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  me public.participants;
  v_role text;
  v_now timestamptz;
  v_tf boolean;
  v_gm boolean;
  v_ended boolean;
  v_delay int;
  v_hist int;
  v_out jsonb;
begin
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  if me.id is null then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  v_cfg := g.config_json;
  v_role := me.role;
  v_now := now() + g.clock_offset;
  v_gm := v_role = 'gm';
  v_tf := v_role in ('hunter', 'zentrale');
  v_ended := g.status in ('beendet', 'archiviert');
  v_delay := public.cfg_int(v_cfg, 'spectator', 'delay_minutes', 30);
  v_hist := public.cfg_int(v_cfg, 'ping', 'history_per_player', 5);

  v_out := jsonb_build_object(
    'now', v_now,
    'server_now', now(),
    'game', jsonb_build_object(
      'id', g.id, 'name', g.name, 'code', g.code, 'status', g.status, 'is_test', g.is_test, 'host', g.host_id = auth.uid(),
      'start_at', g.start_at, 'hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at, 'deadline_at', g.deadline_at,
      'next_day_at', g.next_day_at, 'current_day', g.current_day,
      'phase', public.field_phase(g.id, g.current_day), 'phase_count', public.phase_count(v_cfg),
      'next_phase_at', case when public.shrink_every_minutes(v_cfg) > 0 then (g.state_json ->> 'next_phase_at')::timestamptz else g.next_day_at end, 'paused', g.paused_at is not null, 'pause_reason', g.pause_reason,
      'timezone', g.timezone, 'speedhunts_left', g.speedhunts_left, 'exit_revealed', g.exit_revealed, 'exit_reveal_at', g.exit_reveal_at,
      'map_version', g.map_version, 'result', g.result_json, 'meeting_point', g.meeting_point, 'config', v_cfg, 'group_id', g.group_id,
      'quiet', public.in_quiet_hours(g, v_now)
    ),
    'me', jsonb_build_object(
      'id', me.id, 'role', me.role, 'state', me.state, 'budget', me.budget_balance, 'bounty', me.bounty,
      'next_ping_at', case when v_role = 'spieler' then me.next_ping_at end,
      'location_requested', me.location_request_at is not null,
      'hideout_prompt', me.hideout_prompted_at is not null and not exists (select 1 from public.hideouts where participant_id = me.id and status = 'aktiv' and inside),
      'transport_prompt', me.transport_prompted_at is not null,
      'out_accum_s', me.out_accum_s, 'out_pending', me.out_pending_since is not null, 'in_restricted', me.restricted_zone_id is not null,
      'briefing_done', me.briefing_done_day = g.current_day,
      'live', public.has_live_window(me.id, v_now),
      'effects', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.type, 'ends_at', e.ends_at, 'payload', e.payload)), '[]')
                  from public.active_effects e where e.participant_id = me.id and e.starts_at <= v_now and (e.ends_at is null or e.ends_at > v_now) and not (e.payload ? 'done')),
      'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'type', i.type, 'minutes', i.minutes, 'source', i.source) order by i.granted_at), '[]')
                    from public.inventory_items i where i.participant_id = me.id and i.used_at is null and not i.expired),
      'hideout', (select jsonb_build_object('id', h.id, 'inside', h.inside, 'accum_s', h.accum_s, 'entered_at', h.entered_at,
                    'max_s', public.cfg_int(v_cfg, 'hideout', 'max_minutes', 120) * 60, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))
                  from public.hideouts h where h.participant_id = me.id and h.status = 'aktiv' limit 1),
      'transit', (select jsonb_build_object('id', t.id, 'mode', t.mode, 'line', t.line, 'started_at', t.started_at)
                  from public.transit_sessions t where t.participant_id = me.id and t.ended_at is null limit 1),
      'device_check', me.device_check
    ),
    'participants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', pr.display_name, 'username', pr.username, 'role', p.role, 'color', p.color, 'tag', p.tag,
        'state', case when v_gm or v_ended or p.id = me.id or p.state in ('gefangen', 'disqualifiziert', 'aufgegeben', 'im_ziel', 'verloren', 'ausserhalb', 'notfall') then p.state else 'aktiv' end,
        'battery', case when v_gm or (v_tf and p.role in ('hunter', 'zentrale')) then p.battery end,
        'last_seen_at', case when v_gm then p.last_seen_at end,
        'bounty', p.bounty,
        'budget', case when v_gm then p.budget_balance end,
        'device_check', case when v_gm or p.id = me.id or g.status in ('lobby', 'geplant', 'entwurf') then p.device_check end,
        'next_ping_at', case when (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true)) or v_gm then p.next_ping_at end,
        'protected', case when v_tf or v_gm then (public.has_effect(p.id, 'regeneration', v_now) or public.has_effect(p.id, 'hotel', v_now)) end,
        'catch_free', case when v_tf or v_gm then public.has_effect(p.id, 'catch_free', v_now) end,
        'briefing_done', p.briefing_done_day = g.current_day
      ) order by p.role, pr.display_name), '[]')
      from public.participants p join public.profiles pr on pr.user_id = p.user_id
      where p.game_id = g.id
    ),
    -- Positionen: Spielleitung alles, Taskforce die eigenen Leute und Spieler im Live-Fenster,
    -- Spieler nur sich selbst, Zuschauer verzögert (5.2, 7.18).
    'positions', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', x.participant_id, 'lat', x.lat, 'lng', x.lng, 'accuracy_m', x.accuracy_m,
        'speed_mps', x.speed_mps, 'heading', x.heading, 'at', x.at, 'live', x.live)), '[]')
      from (
        select pos.participant_id, pos.lat, pos.lng, pos.accuracy_m, pos.speed_mps, pos.heading, pos.at,
               public.has_live_window(pos.participant_id, v_now) live
        from public.positions pos join public.participants p on p.id = pos.participant_id
        where pos.game_id = g.id and v_role <> 'zuschauer' and (
          v_gm or v_ended or pos.participant_id = me.id
          or (v_tf and p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'taskforce', 'share_positions_internally', true))
          or (v_tf and p.role = 'spieler' and public.has_live_window(p.id, v_now) and p.state in ('aktiv', 'ausserhalb', 'notfall'))
          or (v_role = 'spieler' and p.role = 'spieler' and p.state = 'notfall')
        )
        union all
        (select distinct on (s.participant_id) s.participant_id, ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.speed_mps, s.heading, s.at, false
        from public.location_samples s
        where s.game_id = g.id and v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false)
          and s.at <= v_now - make_interval(mins => v_delay)
        order by s.participant_id, s.at desc)
      ) x
    ),
    -- Pings: Taskforce sieht die letzten n je Spieler (ohne Fake-Markierung), Spieler die eigenen,
    -- Spielleitung alles inkl. echter Position, Zuschauer verzögert.
    'pings', (
      select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'participant_id', x.participant_id, 'at', x.at, 'lat', x.lat, 'lng', x.lng,
        'accuracy_m', x.accuracy_m, 'source', x.source, 'n', x.n, 'speedhunt_id', x.speedhunt_id, 'zone_kind', x.zone_kind, 'label', x.label,
        'stale_seconds', x.stale_seconds,
        'is_fake', case when v_gm or v_ended or x.participant_id = me.id then x.is_fake end,
        'truth', case when (v_gm or v_ended) and x.is_fake then (select jsonb_build_object('lat', t.lat, 'lng', t.lng) from public.ping_truth t where t.ping_id = x.id) end
      ) order by x.at), '[]')
      from (
        select pg.*, row_number() over (partition by pg.participant_id order by pg.at desc) rn
        from public.pings pg
        where pg.game_id = g.id and (
          v_gm or v_ended
          or (v_tf and pg.visible_at <= v_now)
          or (v_role = 'spieler' and pg.participant_id = me.id)
          or (v_role = 'zuschauer' and public.cfg_bool(v_cfg, 'spectator', 'enabled', false) and pg.visible_at <= v_now - make_interval(mins => v_delay))
        )
      ) x where x.rn <= case when v_gm or v_ended then 1000 else v_hist end
    ),
    'speedhunts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'is_penalty', s.is_penalty,
        'target_id', case when v_gm or v_tf or v_ended or (s.target_id = me.id and public.cfg_bool(v_cfg, 'speedhunt', 'reveal_target_to_target', false)) then s.target_id end,
        'queries_total', s.queries_total, 'queries_used', s.queries_used, 'started_at', s.started_at, 'deadline_at', s.deadline_at,
        'last_query_at', s.last_query_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason, 'day_index', s.day_index) order by s.created_at desc), '[]')
      from public.speedhunts s where s.game_id = g.id and (s.status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') or s.ended_at > v_now - interval '2 hours' or v_gm or v_ended)
        and (s.status <> 'wartet_auf_freigabe' or v_gm or v_tf) and (s.status <> 'aufgeschoben' or v_gm or v_tf)
        and not (s.status = 'beendet' and s.started_at is null and not v_gm)
    ),
    'catches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'runner_id', c.runner_id, 'hunter_id', c.hunter_id, 'at', c.at, 'method', c.method,
        'status', c.status, 'expires_at', c.expires_at, 'distance_m', c.distance_m, 'reason', c.reason, 'lat', case when v_gm or v_ended then c.lat end,
        'lng', case when v_gm or v_ended then c.lng end) order by c.at desc), '[]')
      from public.catches c where c.game_id = g.id and (c.status = 'gueltig' or v_gm or c.runner_id = me.id or c.hunter_id = me.id)
    ),
    'violations', (
      select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'participant_id', v.participant_id, 'type', v.type, 'at', v.at, 'evidence', v.evidence,
        'proposed_penalty', v.proposed_penalty, 'decided_penalty', v.decided_penalty, 'status', v.status, 'auto_apply_at', v.auto_apply_at,
        'explanation', v.explanation, 'detected_by', v.detected_by) order by v.at desc), '[]')
      from public.violations v where v.game_id = g.id and (v_gm or v.participant_id = me.id or v_ended)
    ),
    'challenges', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'description', c.description, 'template', c.template,
        'lat', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lat end,
        'lng', case when v_role <> 'zuschauer' and (not v_tf or c.reveal_location_to_taskforce) then c.lng end,
        'radius_m', c.radius_m, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'announce_at', c.announce_at, 'proof_type', c.proof_type,
        'secret_code', case when v_gm then c.secret_code end, 'reward_type', c.reward_type, 'reward_value', c.reward_value, 'status', c.status,
        'max_participants', c.max_participants,
        'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'result', e.result, 'proof_path', case when v_gm then e.proof_path end, 'proof_text', case when v_gm then e.proof_text end)), '[]')
                    from public.challenge_entries e where e.challenge_id = c.id and (v_gm or e.participant_id = me.id or v_ended))
      ) order by c.starts_at), '[]')
      from public.challenges c where c.game_id = g.id and (v_gm or c.status <> 'geplant')
    ),
    'emergencies', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'participant_id', e.participant_id, 'at', e.at, 'lat', e.lat, 'lng', e.lng, 'status', e.status)), '[]')
      from public.emergencies e where e.game_id = g.id and e.status = 'offen'
    ),
    'transits', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', t.participant_id, 'mode', t.mode, 'line', t.line, 'from', t.from_station, 'to', t.to_station,
        'started_at', t.started_at)), '[]')
      from public.transit_sessions t where t.game_id = g.id and t.ended_at is null and (v_gm or v_tf or t.participant_id = me.id)
    ),
    'hideouts', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', h.participant_id, 'inside', h.inside, 'accum_s', h.accum_s, 'lat', ST_Y(h.center), 'lng', ST_X(h.center))), '[]')
      from public.hideouts h where h.game_id = g.id and h.status = 'aktiv' and v_gm
    ),
    'purchases', (
      select coalesce(jsonb_agg(jsonb_build_object('participant_id', u.participant_id, 'amount', u.amount, 'category', u.category, 'note', u.note, 'at', u.at) order by u.at desc), '[]')
      from public.purchases u where u.game_id = g.id and (v_gm or u.participant_id = me.id)
    ),
    'notifications', (
      select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
        select jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'payload', n.payload, 'priority', n.priority, 'at', n.at) x
        from public.notifications n where n.game_id = g.id and public.can_see_notification(n)
        order by n.id desc limit 60
      ) q
    ),
    'next_silent_ping_at', case when v_gm or (v_tf and public.cfg_bool(v_cfg, 'ping', 'reveal_schedule_to_taskforce', true))
      then (select min(next_ping_at) from public.participants where game_id = g.id and role = 'spieler' and state in ('aktiv', 'ausserhalb')) end,
    'free_players', public.free_players(g.id)
  );
  return v_out;
end; $$;

-- use_item: Hunter-Standorte mit Nummer (zuletzt in 0016_ein_startpunkt_ohne_zentrale.sql)
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
      select coalesce(jsonb_agg(jsonb_build_object('name', public.pname(p.id), 'tag', p.tag, 'lat', pos.lat, 'lng', pos.lng, 'at', pos.at)), '[]') into v_snapshot
      from public.participants p join public.positions pos on pos.participant_id = p.id
      where p.game_id = g.id and p.role = 'hunter';
      insert into public.active_effects (game_id, participant_id, type, starts_at, ends_at, payload, source_item_id)
      values (g.id, v_me.id, 'hunter_snapshot', v_now, greatest(coalesce(g.deadline_at, g.ends_at), v_now + interval '5 minutes'), jsonb_build_object('hunters', v_snapshot), v_i.id);
      perform public.notify(g.id, null, v_me.id, 'joker', 'Hunter-Standorte', 'Einmaliger Ping aller Hunter von ' || to_char(v_now at time zone g.timezone, 'HH24:MI') || ', nicht live. Auf der Karte eingezeichnet.', jsonb_build_object('hunters', v_snapshot), 'hoch');
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

-- ===== 0021_ping_alarm_immer.sql =====

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

-- ===== 0022_spielzeit_fluchtpunkt_blitzjagd.sql =====

-- 0022: Rückmeldungen aus dem Testspiel
-- 1. Spielzeit gilt alles inklusive: vom Start (mit Vorsprung) bis zum Ende, ohne Nachspielzeit.
-- 2. Nach dem Vorsprung kommt sofort ein Ping (kein "Erster Ping nach …" mehr).
-- 3. Fluchtpunkt: Bekanntgabe X min vor Schluss, nutzbar erst Y min vor Schluss (bis Spielende).
-- 4. Blitzjagd: beim Start gleich die erste Abfrage; nie zweimal hintereinander dieselbe Person.
-- 5. Countdown ausserhalb des Spielfelds läuft auch ab, wenn das Handy gerade keinen neuen Standort schickt.
-- 6. Spieler haben Buchstaben (A, B, C …), damit die Pings nummeriert werden können (A1, A2 …).
-- 7. Vergangene Spiele löschen.

-- Länge der Jagd (Spielzeit ohne Vorsprung), mindestens 5 min.
create or replace function public.hunt_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select greatest(5, public.cfg_int(p_cfg, 'game', 'duration_minutes', 180) - public.cfg_int(p_cfg, 'start', 'head_start_minutes', 0));
$$;

-- Phasen der Verkleinerung passen in die Jagd (nach dem Vorsprung).
create or replace function public.phase_count(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.shrink_every_minutes(p_cfg) > 0
    then least(50, greatest(1, ceil(public.hunt_minutes(p_cfg)::numeric / public.shrink_every_minutes(p_cfg))::int))
    else public.cfg_int(p_cfg, 'game', 'days', 4) end;
$$;

-- Nutzbar ab so vielen Minuten vor Schluss (höchstens so viel wie die Bekanntgabe).
create or replace function public.exit_usable_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select least(public.cfg_int(p_cfg, 'exit', 'reveal_minutes_before_end', 20),
               greatest(0, public.cfg_int(p_cfg, 'exit', 'usable_minutes_before_end', 2)));
$$;

create or replace function public.exit_active(p_game public.games, p_now timestamptz)
returns boolean language sql stable as $$
  select p_game.exit_revealed and p_game.ends_at is not null
     and p_now >= p_game.ends_at - make_interval(mins => public.exit_usable_minutes(p_game.config_json));
$$;

-- ---------------------------------------------------------------------------
-- Start: Zeiten neu berechnen (alles inklusive), Spieler bekommen Buchstaben.
alter function public.start_game(uuid, boolean) rename to start_game_basis;
revoke execute on function public.start_game_basis(uuid, boolean) from public, anon, authenticated;

create or replace function public.start_game(p_game_id uuid, p_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_total int;
  v_head int;
  v_reveal int;
  v_z public.zones;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null then raise exception 'Spiel nicht gefunden.' using errcode = 'P0001'; end if;
  v_cfg := g.config_json;
  v_total := public.cfg_int(v_cfg, 'game', 'duration_minutes', 180);
  v_head := public.cfg_int(v_cfg, 'start', 'head_start_minutes', 0);
  if v_head > v_total - 5 then
    raise exception 'Der Vorsprung muss mindestens 5 min kürzer sein als die Spielzeit.' using errcode = 'P0001';
  end if;

  perform public.start_game_basis(p_game_id, p_test);

  select * into g from public.games where id = p_game_id for update;
  v_reveal := least(public.cfg_int(v_cfg, 'exit', 'reveal_minutes_before_end', 20), v_total - v_head);
  update public.games set
    ends_at = start_at + make_interval(mins => v_total),
    deadline_at = start_at + make_interval(mins => v_total),
    exit_reveal_at = case when public.cfg_bool(v_cfg, 'exit', 'enabled', true)
      then start_at + make_interval(mins => v_total - v_reveal) end
  where id = p_game_id returning * into g;
  if public.shrink_every_minutes(v_cfg) > 0 then
    update public.games set state_json = state_json || jsonb_build_object('next_phase_at',
      case when public.phase_count(v_cfg) > 1 and public.phase_start(g, 2) < g.ends_at then public.phase_start(g, 2) end)
    where id = p_game_id returning * into g;
  end if;
  -- Phasen nach Spielende gibt es nicht.
  for v_z in select * from public.zones where game_id = p_game_id and kind = 'spielfeld' and day_index > public.phase_count(v_cfg) loop
    update public.zones set visible_from = 'infinity' where id = v_z.id;
  end loop;

  -- Spieler: Buchstaben A, B, C … (danach A2, B2 …); Hunter bleiben H1, H2 …
  update public.participants p set tag = chr(65 + ((n.rn - 1) % 26)::int) || case when n.rn > 26 then ((n.rn - 1) / 26 + 1)::text else '' end
  from (select id, row_number() over (order by joined_at, id) rn
        from public.participants where game_id = p_game_id and role = 'spieler') n
  where p.id = n.id;

  perform public.bump(p_game_id);
  return jsonb_build_object('hunt_start_at', g.hunt_start_at, 'ends_at', g.ends_at);
end; $$;
revoke execute on function public.start_game(uuid, boolean) from public, anon;
grant execute on function public.start_game(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Jagdbeginn: sofort ein Ping für alle Spieler, danach im eingestellten Abstand.
create or replace function public.hunt_begin(p_game public.games, p_now timestamptz)
returns public.games language plpgsql security definer set search_path = public as $$
begin
  update public.games set status = 'laeuft', current_day = 0 where id = p_game.id returning * into p_game;
  p_game := public.day_reset(p_game, p_now);
  update public.participants set next_ping_at = p_game.hunt_start_at, ping_pending_until = null
  where game_id = p_game.id and role = 'spieler' and state = 'aktiv';
  perform public.notify(p_game.id, 'alle', null, 'hunt_begin', 'Die Jagd beginnt!', 'Die Hunter sind unterwegs.', '{}', 'hoch');
  perform public.log_game_event(p_game.id, 'hunt_begin');
  return p_game;
end; $$;

-- Ping-Takt ab Jagdbeginn (ohne Verzögerung des ersten Pings).
create or replace function public.next_ping_time(p_game public.games, p_from timestamptz, p_interval int)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_offset int := public.cfg_int(v_cfg, 'ping', 'offset_minutes', 0);
  v_jitter int := public.cfg_int(v_cfg, 'ping', 'jitter_minutes', 0);
  v_local timestamp;
  v_midnight timestamp;
  v_min double precision;
  v_k bigint;
  v_t timestamptz;
begin
  if public.cfg_bool(v_cfg, 'time', 'align_to_full_hour', false) then
    v_local := p_from at time zone p_game.timezone;
    v_midnight := date_trunc('day', v_local);
    v_min := extract(epoch from (v_local - v_midnight)) / 60.0;
    v_k := floor((v_min - v_offset) / p_interval) + 1;
    v_t := (v_midnight + make_interval(mins => (v_offset + v_k * p_interval)::int)) at time zone p_game.timezone;
  else
    v_k := greatest(1, floor(extract(epoch from (p_from - p_game.hunt_start_at)) / 60.0 / p_interval) + 1);
    v_t := p_game.hunt_start_at + make_interval(mins => (v_k * p_interval)::int);
  end if;
  if v_t <= p_from then v_t := v_t + make_interval(mins => p_interval); end if;
  if v_jitter > 0 then v_t := v_t + make_interval(secs => floor(random() * v_jitter * 60)); end if;
  return v_t;
end; $$;

-- ---------------------------------------------------------------------------
-- Fluchtpunkt erst nutzbar ab Y min vor Schluss.
create or replace function public.process_location(p_game public.games, p_p public.participants, p_point extensions.geometry, p_speed real, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := p_game.config_json;
  v_hq public.zones;
  v_exit public.zones;
begin
  if p_game.status = 'vorsprung' and p_p.role in ('hunter', 'zentrale') and public.cfg_bool(v_cfg, 'start', 'hunters_must_stay_in_hq', true) then
    select * into v_hq from public.zones where game_id = p_game.id and kind = 'hq' limit 1;
    if v_hq.id is not null and public.dist_m(v_hq.geom, p_point) > coalesce(v_hq.radius_m, public.cfg_int(v_cfg, 'start', 'hq_radius_m', 100)) + public.cfg_int(v_cfg, 'zone', 'edge_tolerance_m', 25)
       and not exists (select 1 from public.violations where participant_id = p_p.id and type = 'hunter_hq') then
      perform public.create_violation(p_game, p_p.id, 'hunter_hq', jsonb_build_object('lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
    return;
  end if;

  if p_p.role <> 'spieler' or p_game.status not in ('laeuft', 'finale') then return; end if;
  if p_p.state not in ('aktiv', 'ausserhalb') then return; end if;

  perform public.check_player_zone(p_game, p_p, p_point, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_transport(p_game, p_p, p_point, p_speed, p_now);
  select * into p_p from public.participants where id = p_p.id;
  perform public.check_hideout(p_game, p_p, p_point, p_now);

  if p_game.exit_zone_id is not null and public.exit_active(p_game, p_now)
     and public.cfg_text(v_cfg, 'exit', 'confirm', 'geofence') = 'geofence' and p_now <= p_game.deadline_at then
    select * into v_exit from public.zones where id = p_game.exit_zone_id;
    if public.dist_m(v_exit.geom, p_point) <= coalesce(v_exit.radius_m, public.cfg_int(v_cfg, 'exit', 'radius_m', 30)) then
      perform public.reach_exit(p_game, p_p.id, p_now);
    end if;
  end if;
end; $$;

create or replace function public.confirm_exit(p_game_id uuid, p_participant uuid default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_me public.participants;
  g public.games;
  v_exit public.zones;
  v_pos public.positions;
  v_now timestamptz;
begin
  v_me := public.require_participant(p_game_id);
  g := public.require_running(p_game_id);
  v_now := public.engine_now(p_game_id);
  if not g.exit_revealed then raise exception 'Der Fluchtpunkt ist noch nicht bekannt.' using errcode = 'P0001'; end if;
  if not public.exit_active(g, v_now) then
    raise exception 'Der Fluchtpunkt ist erst ab % offen.', to_char((g.ends_at - make_interval(mins => public.exit_usable_minutes(g.config_json))) at time zone g.timezone, 'HH24:MI')
      using errcode = 'P0001';
  end if;
  if v_me.role = 'gm' and p_participant is not null then
    perform public.reach_exit(g, p_participant, v_now);
  elsif v_me.role = 'spieler' then
    select * into v_exit from public.zones where id = g.exit_zone_id;
    select * into v_pos from public.positions where participant_id = v_me.id;
    if v_pos.participant_id is null or public.dist_m(v_exit.geom, v_pos.geom) > coalesce(v_exit.radius_m, 30) + coalesce(v_pos.accuracy_m, 0) + 20 then
      raise exception 'Du bist noch nicht am Fluchtpunkt.' using errcode = 'P0001';
    end if;
    perform public.reach_exit(g, v_me.id, v_now);
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Tick: Bekanntgabe und Freigabe des Fluchtpunkts, Countdown ausserhalb auch ohne neuen Standort.
alter function public.tick_game(uuid) rename to tick_game_basis;
revoke execute on function public.tick_game_basis(uuid) from public, anon, authenticated;

create or replace function public.tick_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_open timestamptz;
  v_name text;
  v_p public.participants;
  v_pos public.positions;
  v_grace int;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or g.status not in ('laeuft', 'finale') or g.paused_at is not null then
    perform public.tick_game_basis(p_game_id);
    return;
  end if;
  v_cfg := g.config_json;
  v_now := now() + g.clock_offset;
  v_open := g.ends_at - make_interval(mins => public.exit_usable_minutes(v_cfg));

  -- Bekanntgabe (vor dem Basis-Tick, damit dort nichts doppelt passiert).
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    select * into g from public.games where id = p_game_id for update;
    if not g.exit_revealed then
      if g.exit_zone_id is null then
        update public.games set exit_zone_id = (
          select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
          order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.phase_count(v_cfg)), z.geom), z.geom) then 0 else 1 end, random()
          limit 1)
        where id = g.id returning * into g;
      end if;
      update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
      update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
      select coalesce(nullif(name, ''), 'siehe Karte') into v_name from public.zones where id = g.exit_zone_id;
      perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(v_name, 'siehe Karte'),
        'Er ist erst ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' offen. Seid zwischen '
        || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' und ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI')
        || ' im Kreis. Ab jetzt dürft ihr auch zusammen sein.', jsonb_build_object('open_at', v_open), 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
        'Ihr erfahrt ihn nicht. Er ist ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' bis zum Spielende offen.', '{}', 'hoch');
    end if;
  end if;

  perform public.tick_game_basis(p_game_id);

  select * into g from public.games where id = p_game_id;
  if g.status not in ('laeuft', 'finale') or g.paused_at is not null then return; end if;

  -- Freigabe: ab jetzt zählt, wer im Kreis steht.
  if g.exit_revealed and g.exit_zone_id is not null and v_now >= v_open and not coalesce((g.state_json ->> 'exit_open')::boolean, false) then
    update public.games set state_json = state_json || '{"exit_open": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_open', 'Fluchtpunkt ist jetzt offen!',
      'Seid bis ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI') || ' im Kreis, dann seid ihr gerettet.', '{}', 'kritisch');
    perform public.recheck_exit(g, v_now);
    select * into g from public.games where id = p_game_id;
    if g.status not in ('laeuft', 'finale') then perform public.bump(g.id); return; end if;
  end if;

  -- Countdown abgelaufen, aber kein neuer Standort: mit dem letzten bekannten Standort weiterprüfen.
  v_grace := public.cfg_int(v_cfg, 'out_of_bounds', 'grace_seconds', 60);
  for v_p in select * from public.participants
             where game_id = g.id and role = 'spieler' and state = 'aktiv'
               and ((out_pending_since is not null and out_pending_since <= v_now - make_interval(secs => v_grace))
                 or (restricted_zone_id is not null and not restricted_violated and restricted_since <= v_now - make_interval(secs => v_grace))) loop
    select * into v_pos from public.positions where participant_id = v_p.id;
    if v_pos.participant_id is not null then
      perform public.check_player_zone(g, v_p, v_pos.geom, v_now);
    end if;
  end loop;
  perform public.bump(g.id);
end; $$;
revoke execute on function public.tick_game(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Blitzjagd: Start mit Bestätigung in der App, dann gleich die erste Abfrage.
-- Nie zweimal hintereinander dieselbe Person (auch wenn nur noch eine frei ist).
create or replace function public.speedhunt_start(p_game_id uuid, p_target uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_t public.participants;
  v_sh public.speedhunts;
begin
  v_me := public.require_participant(p_game_id, array['hunter', 'zentrale', 'gm']);
  g := public.require_running(p_game_id);
  v_cfg := g.config_json;
  v_now := public.engine_now(p_game_id);
  if not public.cfg_bool(v_cfg, 'speedhunt', 'enabled', true) then raise exception 'Blitzjagden sind ausgeschaltet.' using errcode = 'P0001'; end if;
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
  if public.has_effect(p_target, 'regeneration', v_now) then raise exception 'Ziel ist durch einen Joker geschützt.' using errcode = 'P0001'; end if;
  if g.last_speedhunt_target = p_target then
    raise exception 'Nicht zweimal hintereinander dasselbe Ziel.' using errcode = 'P0001';
  end if;
  if public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) > 0
     and (select count(*) from public.speedhunts where target_id = p_target and not is_penalty and started_at is not null)
       >= public.cfg_int(v_cfg, 'speedhunt', 'max_per_player_per_day', 0) then
    raise exception 'Dieses Ziel hatte schon genug Blitzjagden.' using errcode = 'P0001';
  end if;
  if public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0) > 0
     and public.cfg_text(v_cfg, 'speedhunt', 'early_start_policy', 'silent_zaehlt_als_abfrage') = 'verbieten'
     and v_t.last_silent_ping_at > v_now - make_interval(mins => public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0)) then
    raise exception 'Erst % min nach dem letzten Ping möglich.', public.cfg_int(v_cfg, 'speedhunt', 'min_minutes_after_silent_ping', 0) using errcode = 'P0001';
  end if;

  update public.games set speedhunts_left = speedhunts_left - 1 where id = p_game_id;
  v_sh := public.start_speedhunt_internal(g, p_target, v_me.id, false, v_now);
  if v_sh.status = 'laeuft' and v_sh.queries_used < v_sh.queries_total then
    perform public.speedhunt_query_internal(g, v_sh, v_now);
  end if;
  perform public.log_game_event(p_game_id, 'speedhunt_start', jsonb_build_object('target', p_target, 'by', v_me.id));
  perform public.bump(p_game_id);
  return v_sh.id;
end; $$;

-- ---------------------------------------------------------------------------
-- Vergangene Spiele löschen: der Host löscht das ganze Spiel, alle anderen entfernen es aus ihrer Liste.
create or replace function public.delete_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null then raise exception 'Spiel nicht gefunden.' using errcode = 'P0001'; end if;
  if g.status in ('vorsprung', 'laeuft', 'pausiert', 'finale') then
    raise exception 'Ein laufendes Spiel kann nicht gelöscht werden.' using errcode = 'P0001';
  end if;
  if g.host_id = auth.uid() then
    delete from public.games where id = p_game_id;
  elsif exists (select 1 from public.participants where game_id = p_game_id and user_id = auth.uid()) then
    delete from public.participants where game_id = p_game_id and user_id = auth.uid();
  else
    raise exception 'Nicht erlaubt.' using errcode = '42501';
  end if;
end; $$;
revoke execute on function public.delete_game(uuid) from public, anon;
grant execute on function public.delete_game(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Bestehende, noch nicht gestartete Spiele an die neuen Regeln anpassen.
update public.games set config_json = jsonb_set(jsonb_set(jsonb_set(config_json,
    '{ping,first_ping_delay_minutes}', '0'::jsonb, true),
    '{exit,arrival_deadline_offset_minutes}', '0'::jsonb, true),
    '{speedhunt,no_consecutive_same_target}', 'true'::jsonb, true)
where status in ('entwurf', 'geplant', 'lobby');
update public.games set config_json = jsonb_set(config_json, '{exit,usable_minutes_before_end}', '2'::jsonb, true)
where status in ('entwurf', 'geplant', 'lobby') and not (config_json -> 'exit' ? 'usable_minutes_before_end');

-- ---------------------------------------------------------------------------
-- Verständliche Meldungen statt alter Entwickler-Hinweise.
create or replace function public.remove_participant(p_participant_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_p public.participants;
  v_game public.games;
begin
  select * into v_p from public.participants where id = p_participant_id;
  if v_p.id is null then return; end if;
  select * into v_game from public.games where id = v_p.game_id;
  if v_p.user_id <> auth.uid() and v_game.host_id <> auth.uid() then
    raise exception 'Keine Berechtigung.' using errcode = '42501';
  end if;
  if v_p.user_id = v_game.host_id then
    raise exception 'Der Host kann das Spiel nicht verlassen.' using errcode = 'P0001';
  end if;
  if v_game.status not in ('entwurf', 'geplant', 'lobby', 'beendet', 'archiviert') then
    raise exception 'Das Spiel läuft. Verlassen geht nur über „Aufgeben“.' using errcode = 'P0001';
  end if;
  delete from public.participants where id = p_participant_id;
  perform public.log_game_event(v_p.game_id, 'participant_left', jsonb_build_object('user_id', v_p.user_id));
end; $$;

create or replace function public.update_game_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_change jsonb;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Regeln ändern.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.games where id = p_game_id and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Die Regeln lassen sich nach dem Start nicht mehr ändern.' using errcode = 'P0001';
  end if;
  update public.games
  set config_json = p_config, timezone = coalesce(p_config #>> '{game,timezone}', timezone), updated_at = now()
  where id = p_game_id;
  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value)
    values (p_game_id, auth.uid(), v_change ->> 'path', v_change -> 'old', v_change -> 'new');
  end loop;
  perform public.log_game_event(p_game_id, 'config_changed', jsonb_build_object('changes', jsonb_array_length(coalesce(p_changes, '[]'::jsonb))));
end; $$;

-- ===== 0023_pause_sicherheit_fang.sql =====

-- 0023: Rückmeldungen aus dem zweiten Testspiel
-- 1. Der Host kann das Spiel pausieren (die Zeit hält an) und während der Pause Einstellungen ändern.
-- 2. Der Vorsprung startet erst, wenn alle Spieler und Hunter den Sicherheitshinweis bestätigt haben
--    (der Host kann notfalls trotzdem starten).
-- 3. Fang: lehnt der Spieler einen gemeldeten Fang ab, gilt er nicht.
-- 4. Abgebrochenes Spiel: keiner hat gewonnen.
-- 5. Wiederholung: der ganze Weg aller Personen (ab Spielstart, fein aufgelöst), nicht nur die Pings.
-- 6. Eigene Spiel-Varianten speichern.

alter table public.games add column if not exists pause_kind text;
alter table public.participants add column if not exists safety_ok_at timestamptz;

-- ---------------------------------------------------------------------------
-- Fortsetzen nach einer Pause: alle Zeiten um die Pause verschieben.
-- p_kind: 'notfall' (SOS), 'host' (Pause durch den Host), 'sicherheit' (Warten auf den Sicherheitshinweis).
create or replace function public.resume_shift(p_game_id uuid, p_title text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_now timestamptz;
  d interval;
begin
  select * into g from public.games where id = p_game_id for update;
  if g.paused_at is null then return; end if;
  v_now := public.engine_now(p_game_id);
  d := v_now - g.paused_at;
  update public.games set paused_at = null, pause_reason = null, pause_kind = null, last_tick_at = v_now,
    -- Wartet das Spiel auf den Sicherheitshinweis, beginnt es erst jetzt richtig.
    start_at = case when g.pause_kind = 'sicherheit' then start_at + d else start_at end,
    hunt_start_at = case when status = 'vorsprung' then hunt_start_at + d else hunt_start_at end,
    ends_at = ends_at + d,
    deadline_at = deadline_at + d,
    exit_reveal_at = exit_reveal_at + d,
    next_day_at = next_day_at + d,
    state_json = case when g.pause_kind = 'sicherheit' then state_json
      else state_json || jsonb_build_object('paused_s', coalesce((state_json ->> 'paused_s')::int, 0) + extract(epoch from d)::int) end
  where id = p_game_id;
  update public.participants set next_ping_at = next_ping_at + d, ping_pending_until = ping_pending_until + d,
    grace_until = grace_until + d, out_pending_since = out_pending_since + d, stationary_since = stationary_since + d,
    speeding_since = speeding_since + d, transport_prompted_at = transport_prompted_at + d,
    restricted_since = restricted_since + d
  where game_id = p_game_id;
  update public.speedhunts set deadline_at = deadline_at + d where game_id = p_game_id and status = 'laeuft';
  update public.active_effects set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.live_windows set ends_at = ends_at + d where game_id = p_game_id and ends_at > g.paused_at;
  update public.violations set auto_apply_at = auto_apply_at + d where game_id = p_game_id and status = 'offen';
  update public.catches set expires_at = expires_at + d where game_id = p_game_id and expires_at > g.paused_at;
  update public.games set state_json = jsonb_set(state_json, '{next_phase_at}', to_jsonb((state_json ->> 'next_phase_at')::timestamptz + d))
    where id = p_game_id and (state_json ->> 'next_phase_at') is not null;
  update public.zones set visible_from = visible_from + d where game_id = p_game_id and visible_from > g.paused_at and visible_from <> 'infinity';
  perform public.notify(p_game_id, 'alle', null, 'resume', p_title, p_body, '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'resumed', jsonb_build_object('seconds', extract(epoch from d)::int, 'kind', coalesce(g.pause_kind, 'notfall')));
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.resume_shift(uuid, text, text) from public, anon, authenticated;

-- Nach einem Notfall geht es nur weiter, wenn das Spiel wegen des Notfalls unterbrochen war
-- (eine Pause des Hosts oder das Warten auf den Sicherheitshinweis bleibt bestehen).
create or replace function public.resume_internal(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.games where id = p_game_id and pause_kind is not null) then return; end if;
  perform public.resume_shift(p_game_id, 'Weiter geht''s!', 'Der Notfall ist beendet. Das Spiel läuft wieder, die unterbrochene Zeit wird angehängt.');
end; $$;
revoke execute on function public.resume_internal(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Pause durch den Host
create or replace function public.host_pause(p_game_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat, kann pausieren.' using errcode = '42501'; end if;
  perform public.tick_game(p_game_id);
  select * into g from public.games where id = p_game_id for update;
  if g.status not in ('vorsprung', 'laeuft', 'finale') then raise exception 'Das Spiel läuft nicht.' using errcode = 'P0001'; end if;
  if g.paused_at is not null then raise exception 'Das Spiel ist schon unterbrochen.' using errcode = 'P0001'; end if;
  update public.games set paused_at = public.engine_now(p_game_id), pause_kind = 'host',
    pause_reason = coalesce(nullif(trim(p_reason), ''), 'Pause') where id = p_game_id;
  perform public.notify(p_game_id, 'alle', null, 'pause', 'Spiel pausiert',
    'Der Host hat das Spiel angehalten' || coalesce(': ' || nullif(trim(p_reason), ''), '') || '. Die Zeit steht still, bis es weitergeht.', '{}', 'kritisch');
  perform public.log_game_event(p_game_id, 'paused', jsonb_build_object('reason', p_reason, 'kind', 'host'));
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.host_pause(uuid, text) from public, anon;
grant execute on function public.host_pause(uuid, text) to authenticated;

create or replace function public.host_resume(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat, kann fortsetzen.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is null then return; end if;
  if g.pause_kind is distinct from 'host' then raise exception 'Das Spiel ist nicht vom Host pausiert.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.emergencies where game_id = p_game_id and status = 'offen') then
    raise exception 'Es läuft noch ein Notfall. Zuerst den Notfall beenden.' using errcode = 'P0001';
  end if;
  perform public.resume_shift(p_game_id, 'Weiter geht''s!', 'Der Host hat das Spiel fortgesetzt. Die Pause wird hinten angehängt.');
end; $$;
revoke execute on function public.host_resume(uuid) from public, anon;
grant execute on function public.host_resume(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Sicherheitshinweis: jede Person bestätigt ihn. Vorher startet der Vorsprung nicht.
create or replace function public.safety_missing(p_game_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.participants
  where game_id = p_game_id and role in ('spieler', 'hunter', 'zentrale') and safety_ok_at is null;
$$;
revoke execute on function public.safety_missing(uuid) from public, anon, authenticated;

create or replace function public.safety_confirm(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.participants;
  g public.games;
begin
  v_me := public.require_participant(p_game_id);
  update public.participants set safety_ok_at = coalesce(safety_ok_at, now()) where id = v_me.id;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is not null and g.pause_kind = 'sicherheit' and public.safety_missing(p_game_id) = 0 then
    perform public.resume_shift(p_game_id, 'Los geht''s!', 'Alle haben den Sicherheitshinweis bestätigt. Der Vorsprung läuft.');
  end if;
  perform public.bump(p_game_id);
end; $$;
revoke execute on function public.safety_confirm(uuid) from public, anon;
grant execute on function public.safety_confirm(uuid) to authenticated;

-- Notfalls startet der Host ohne die fehlenden Bestätigungen.
create or replace function public.safety_force_start(p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  if not public.is_game_host(p_game_id) then raise exception 'Nur wer das Spiel erstellt hat.' using errcode = '42501'; end if;
  select * into g from public.games where id = p_game_id;
  if g.paused_at is null or g.pause_kind is distinct from 'sicherheit' then return; end if;
  perform public.log_game_event(p_game_id, 'safety_forced', jsonb_build_object('missing', public.safety_missing(p_game_id)));
  perform public.resume_shift(p_game_id, 'Los geht''s!', 'Der Host hat das Spiel gestartet. Der Vorsprung läuft.');
end; $$;
revoke execute on function public.safety_force_start(uuid) from public, anon;
grant execute on function public.safety_force_start(uuid) to authenticated;

-- Start: fehlt noch eine Bestätigung, wartet das Spiel (die Zeit steht still).
alter function public.start_game(uuid, boolean) rename to start_game_zeiten;
revoke execute on function public.start_game_zeiten(uuid, boolean) from public, anon, authenticated;

create or replace function public.start_game(p_game_id uuid, p_test boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
  v_missing int;
begin
  v_res := public.start_game_zeiten(p_game_id, p_test);
  v_missing := public.safety_missing(p_game_id);
  if v_missing > 0 then
    update public.games set paused_at = public.engine_now(p_game_id), pause_kind = 'sicherheit',
      pause_reason = 'Warten auf den Sicherheitshinweis' where id = p_game_id;
    perform public.notify(p_game_id, 'alle', null, 'safety_wait', 'Bitte Sicherheitshinweis bestätigen',
      'Der Vorsprung startet, sobald alle Spieler und Hunter den Hinweis gelesen und bestätigt haben.', '{}', 'kritisch');
    perform public.bump(p_game_id);
  end if;
  return v_res || jsonb_build_object('waiting_for_safety', v_missing);
end; $$;
revoke execute on function public.start_game(uuid, boolean) from public, anon;
grant execute on function public.start_game(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Regeln ändern: vor dem Start oder während einer Pause des Hosts (dann werden die Zeiten neu berechnet).
create or replace function public.update_game_config(p_game_id uuid, p_config jsonb, p_changes jsonb default '[]'::jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_change jsonb;
  g public.games;
  v_total int;
  v_head int;
  v_reveal int;
  v_paused int;
  v_ends timestamptz;
begin
  if not public.is_game_host(p_game_id) then
    raise exception 'Nur der Host kann die Regeln ändern.' using errcode = '42501';
  end if;
  select * into g from public.games where id = p_game_id for update;
  if g.status in ('entwurf', 'geplant', 'lobby') then
    update public.games
    set config_json = p_config, timezone = coalesce(p_config #>> '{game,timezone}', timezone), updated_at = now()
    where id = p_game_id;
  elsif g.status in ('vorsprung', 'laeuft', 'finale') and g.paused_at is not null and g.pause_kind = 'host' then
    v_total := public.cfg_int(p_config, 'game', 'duration_minutes', 180);
    v_head := public.cfg_int(p_config, 'start', 'head_start_minutes', 0);
    v_paused := coalesce((g.state_json ->> 'paused_s')::int, 0);
    v_reveal := least(public.cfg_int(p_config, 'exit', 'reveal_minutes_before_end', 20), v_total - v_head);
    v_ends := g.start_at + make_interval(mins => v_total, secs => v_paused);
    if v_ends < g.paused_at + interval '5 minutes' then
      raise exception 'Die Spielzeit ist zu kurz: es sind schon % min gespielt.',
        floor(extract(epoch from (g.paused_at - g.start_at)) / 60 - v_paused / 60.0)::int using errcode = 'P0001';
    end if;
    if g.status = 'vorsprung' and g.start_at + make_interval(mins => v_head, secs => v_paused) < g.paused_at then
      raise exception 'Der Vorsprung ist schon länger gelaufen.' using errcode = 'P0001';
    end if;
    update public.games set config_json = p_config, updated_at = now(),
      ends_at = v_ends, deadline_at = v_ends,
      hunt_start_at = case when status = 'vorsprung' then start_at + make_interval(mins => v_head, secs => v_paused) else hunt_start_at end,
      exit_reveal_at = case when exit_revealed then exit_reveal_at
        when public.cfg_bool(p_config, 'exit', 'enabled', true) then v_ends - make_interval(mins => v_reveal) end
    where id = p_game_id;
    perform public.notify(p_game_id, 'alle', null, 'config_changed', 'Regeln geändert',
      'Der Host hat während der Pause die Einstellungen angepasst. Schau unter „Regeln“ nach.', '{}', 'hoch');
  elsif g.status in ('vorsprung', 'laeuft', 'finale') then
    raise exception 'Regeln lassen sich im laufenden Spiel nur während einer Pause ändern.' using errcode = 'P0001';
  else
    raise exception 'Die Regeln lassen sich nach dem Start nicht mehr ändern.' using errcode = 'P0001';
  end if;
  for v_change in select * from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) loop
    insert into public.game_config_changes (game_id, changed_by, path, old_value, new_value)
    values (p_game_id, auth.uid(), v_change ->> 'path', v_change -> 'old', v_change -> 'new');
  end loop;
  perform public.log_game_event(p_game_id, 'config_changed', jsonb_build_object('changes', jsonb_array_length(coalesce(p_changes, '[]'::jsonb))));
  perform public.bump(p_game_id);
end; $$;

-- ---------------------------------------------------------------------------
-- Fang: lehnt der Spieler ab, gilt der Fang nicht. Der Hunter kann dann den Zahlencode verlangen.
create or replace function public.catch_respond(p_catch_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_c public.catches;
  v_me public.participants;
  g public.games;
begin
  select * into v_c from public.catches where id = p_catch_id;
  if v_c.id is null then raise exception 'Fang nicht gefunden.' using errcode = 'P0001'; end if;
  v_me := public.require_participant(v_c.game_id);
  g := public.require_running(v_c.game_id, true);
  if v_c.status <> 'wartet_auf_bestaetigung' then raise exception 'Schon entschieden.' using errcode = 'P0001'; end if;
  if v_me.id <> v_c.runner_id then raise exception 'Nur die gefangene Person.' using errcode = '42501'; end if;
  if p_accept then
    perform public.apply_catch(g, v_c.id, public.engine_now(g.id));
  else
    update public.catches set status = 'abgelehnt', reason = 'Vom Spieler abgelehnt', expires_at = null where id = v_c.id;
    perform public.notify(g.id, null, v_c.hunter_id, 'catch_rejected', 'Fang abgelehnt',
      public.pname(v_c.runner_id) || ' sagt, es war kein Fang. Lass dir den Fang-Code zeigen und gib ihn ein.', '{}', 'hoch');
  end if;
  perform public.bump(g.id);
end; $$;

-- ---------------------------------------------------------------------------
-- Spiel abgebrochen: keiner hat gewonnen, niemand verliert.
alter function public.finish_game(public.games, timestamptz, text) rename to finish_game_basis;
revoke execute on function public.finish_game_basis(public.games, timestamptz, text) from public, anon, authenticated;

create or replace function public.finish_game(p_game public.games, p_now timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sh public.speedhunts;
begin
  if p_reason is distinct from 'abgebrochen' then
    perform public.finish_game_basis(p_game, p_now, p_reason);
    return;
  end if;
  if p_game.status = 'beendet' then return; end if;
  for v_sh in select * from public.speedhunts where game_id = p_game.id and status in ('laeuft', 'wartet_auf_freigabe', 'aufgeschoben') loop
    perform public.end_speedhunt(p_game, v_sh, 'spielende', p_now);
  end loop;
  update public.live_windows set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);
  update public.active_effects set ends_at = p_now where game_id = p_game.id and (ends_at is null or ends_at > p_now);
  update public.games set status = 'beendet', ended_at = p_now, paused_at = null, pause_kind = null, result_json = jsonb_build_object(
    'reason', 'abgebrochen', 'winners', '[]'::jsonb, 'mode', public.cfg_text(p_game.config_json, 'win', 'mode', 'alle_ueberlebenden'),
    'scores', '{}'::jsonb,
    'hours', round((extract(epoch from (p_now - coalesce(p_game.hunt_start_at, p_now))) / 3600.0)::numeric, 2),
    'catches', (select count(*) from public.catches where game_id = p_game.id and status = 'gueltig'),
    'pings', (select count(*) from public.pings where game_id = p_game.id),
    'speedhunts', (select count(*) from public.speedhunts where game_id = p_game.id and started_at is not null)
  ) where id = p_game.id;
  perform public.notify(p_game.id, 'alle', null, 'game_end', 'Spiel abgebrochen', 'Keiner hat gewonnen.', jsonb_build_object('reason', 'abgebrochen'), 'hoch');
  perform public.log_game_event(p_game.id, 'game_ended', jsonb_build_object('reason', 'abgebrochen'));
end; $$;
revoke execute on function public.finish_game(public.games, timestamptz, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Wiederholung: der ganze Weg ab Spielstart, ein Punkt alle 10 s.
create or replace function public.game_replay(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if not public.is_game_member(p_game_id) then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if g.status not in ('beendet', 'archiviert') then
    raise exception 'Die Wiederholung gibt es erst nach Spielende.' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'start', coalesce(g.start_at, g.hunt_start_at), 'hunt_start', g.hunt_start_at, 'end', coalesce(g.ended_at, now() + g.clock_offset),
    'tracks', (
      select coalesce(jsonb_object_agg(pid, pts), '{}') from (
        select participant_id pid, jsonb_agg(jsonb_build_array(b, round(lat::numeric, 6), round(lng::numeric, 6)) order by b) pts
        from (
          select distinct on (participant_id, floor(extract(epoch from at) / 10)) participant_id,
                 (floor(extract(epoch from at) / 10) * 10)::bigint b, ST_Y(geom) lat, ST_X(geom) lng
          from public.location_samples
          where game_id = p_game_id and not is_mock and coalesce(accuracy_m, 0) <= 100
          order by participant_id, floor(extract(epoch from at) / 10), accuracy_m nulls last, at desc
        ) s group by participant_id
      ) t
    ),
    'pings', (select coalesce(jsonb_agg(jsonb_build_object('participant_id', participant_id, 'at', at, 'lat', lat, 'lng', lng, 'source', source, 'is_fake', is_fake) order by at), '[]')
              from public.pings where game_id = p_game_id and lat is not null),
    'catches', (select coalesce(jsonb_agg(jsonb_build_object('runner_id', runner_id, 'hunter_id', hunter_id, 'at', at, 'lat', lat, 'lng', lng)), '[]')
                from public.catches where game_id = p_game_id and status = 'gueltig'),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'type', type, 'payload', payload_json) order by at), '[]')
               from public.game_events where game_id = p_game_id)
  );
end; $$;

-- ---------------------------------------------------------------------------
-- Spielstand: Art der Pause und wer den Sicherheitshinweis noch nicht bestätigt hat.
alter function public.game_state(uuid) rename to game_state_basis;
revoke execute on function public.game_state_basis(uuid) from public, anon, authenticated;

create or replace function public.game_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v jsonb;
  g public.games;
  me public.participants;
begin
  v := public.game_state_basis(p_game_id);
  select * into g from public.games where id = p_game_id;
  select * into me from public.participants where game_id = p_game_id and user_id = auth.uid();
  v := jsonb_set(v, '{game,pause_kind}', coalesce(to_jsonb(case when g.paused_at is not null then coalesce(g.pause_kind, 'notfall') end), 'null'::jsonb));
  v := jsonb_set(v, '{me,safety_ok}', to_jsonb(me.safety_ok_at is not null));
  v := v || jsonb_build_object('safety_missing', (
    select coalesce(jsonb_agg(p.id), '[]') from public.participants p
    where p.game_id = p_game_id and p.role in ('spieler', 'hunter', 'zentrale') and p.safety_ok_at is null));
  return v;
end; $$;
revoke execute on function public.game_state(uuid) from public, anon;
grant execute on function public.game_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Eigene Spiel-Varianten (nur für die Person, die sie gespeichert hat).
create table if not exists public.config_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  config_json jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists config_templates_user_idx on public.config_templates (user_id, created_at desc);
alter table public.config_templates enable row level security;
drop policy if exists "Varianten: eigene" on public.config_templates;
create policy "Varianten: eigene" on public.config_templates for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.config_templates to authenticated;

-- ---------------------------------------------------------------------------
-- "Nochmal spielen": die Karte eines früheren Spiels übernehmen (Spielfeld, Gefahrenzonen, Start- und Fluchtpunkte).
-- Von der Engine erzeugte Stufen der automatischen Verkleinerung werden nicht kopiert, die entstehen beim Start neu.
create or replace function public.copy_map(p_from uuid, p_to uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  v_auto boolean;
  n int;
begin
  if not public.is_game_host(p_to) then raise exception 'Nur der Host kann die Karte bearbeiten.' using errcode = '42501'; end if;
  if not public.is_game_member(p_from) then raise exception 'Du warst in diesem Spiel nicht dabei.' using errcode = '42501'; end if;
  if not exists (select 1 from public.games where id = p_to and status in ('entwurf', 'geplant', 'lobby')) then
    raise exception 'Die Karte ist ab Spielstart gesperrt.' using errcode = 'P0001';
  end if;
  v_auto := public.cfg_text((select config_json from public.games where id = p_from), 'zone', 'shrink_mode', 'aus') = 'auto';
  delete from public.zones where game_id = p_to;
  insert into public.zones (game_id, kind, name, color, geom, radius_m, day_index, grows, ping_interval_override,
    crossing_allowed, restricted_type)
  select p_to, z.kind, z.name, z.color, z.geom, z.radius_m,
    case when v_auto then null else z.day_index end, z.grows, z.ping_interval_override, z.crossing_allowed, z.restricted_type
  from public.zones z
  where z.game_id = p_from and z.kind in ('spielfeld', 'sperrzone', 'exit', 'treffpunkt')
    and not (v_auto and z.kind = 'spielfeld' and coalesce(z.day_index, 1) > 1)
  order by z.created_at;
  get diagnostics n = row_count;
  perform public.place_hunter_wait(p_to);
  perform public.log_game_event(p_to, 'map_saved', jsonb_build_object('zones', n, 'copied_from', p_from));
  perform public.bump(p_to);
  return n;
end; $$;
revoke execute on function public.copy_map(uuid, uuid) from public, anon;
grant execute on function public.copy_map(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Ping so genau wie möglich, nie verschoben: statt eines Mittelwerts (der einen Punkt ergeben kann, an dem
-- niemand war) zählt der genaueste echte Messpunkt der letzten 20 Sekunden, bei Gleichstand der neueste.
create or replace function public.best_position(p_participant_id uuid, p_now timestamptz,
  out lat double precision, out lng double precision, out accuracy_m real, out age_s int)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_at timestamptz;
begin
  select ST_Y(s.geom), ST_X(s.geom), s.accuracy_m, s.at
    into lat, lng, accuracy_m, v_at
  from public.location_samples s
  where s.participant_id = p_participant_id and s.at > p_now - interval '20 seconds' and s.at <= p_now
    and coalesce(s.accuracy_m, 0) < 100 and not s.is_mock
  order by coalesce(s.accuracy_m, 50), s.at desc
  limit 1;
  if v_at is not null then
    age_s := greatest(0, extract(epoch from (p_now - v_at))::int);
    return;
  end if;
  select p.lat, p.lng, p.accuracy_m, greatest(0, extract(epoch from (p_now - p.at))::int)
    into lat, lng, accuracy_m, age_s
  from public.positions p where participant_id = p_participant_id;
end; $$;
revoke execute on function public.best_position(uuid, timestamptz) from public, anon, authenticated;

-- ===== 0024_spieler_pings_naehe_radar.sql =====

-- Runde 16:
-- 1. Spieler sehen die Pings der anderen Spieler (gleiche Pings wie die Hunter, aber ohne Blitzjagd-Pings),
--    damit sie sich besser auf der Karte verteilen können.
-- 2. Neuer Joker "Nähe-Radar": zeigt eine eingestellte Zeit lang, ob ein Hunter näher als ein eingestellter Abstand ist (nicht wo).
-- 3. Der Nähe-Alarm zweier Spieler wird ganz entfernt (Prüfung im Spieltakt, Funktion, Tabelle).

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
    -- Ohne Blitzjagd-Pings der anderen.
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
          or (p.role = 'spieler' and pg.visible_at <= v_now and pg.source <> 'speedhunt')
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
-- Nähe-Alarm zweier Spieler entfernt.
-- tick_game_basis: wie zuletzt in 0017_ohne_strafen_sos_fluchtpunkt.sql (als tick_game, in 0022 umbenannt),
-- nur ohne die Prüfung, ob zwei Spieler zu nahe sind.
create or replace function public.tick_game_basis(p_game_id uuid)
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
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
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


  -- Fluchtpunkt bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    -- Erst jetzt zufällig einen Kandidaten wählen, bevorzugt im aktuellen Spielfeld. Nur die Spieler sehen ihn.
    if g.exit_zone_id is null then
      update public.games set exit_zone_id = (
        select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
        order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.field_phase(g.id, g.current_day)), z.geom), z.geom) then 0 else 1 end, random()
        limit 1)
      where id = g.id returning * into g;
    end if;
    update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '. Ab jetzt dürft ihr auch zusammen sein.', '{}', 'kritisch');
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
      'Ihr erfahrt ihn nicht. Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
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
revoke execute on function public.tick_game_basis(uuid) from public, anon, authenticated;

drop function if exists public.check_proximity(public.games, timestamptz);
drop table if exists public.proximity_pairs;

-- ===== 0025_fluchtpunkt_meldung.sql =====

-- Nachtrag Runde 16: Der Nähe-Alarm ist entfernt, darum fällt in der Meldung zur Bekanntgabe des Fluchtpunkts
-- der Satz "Ab jetzt dürft ihr auch zusammen sein." weg. Sonst unverändert.

-- tick_game_basis (zuletzt in 0024_spieler_pings_naehe_radar.sql)
create or replace function public.tick_game_basis(p_game_id uuid)
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
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
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


  -- Fluchtpunkt bekanntgeben (7.19)
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    -- Erst jetzt zufällig einen Kandidaten wählen, bevorzugt im aktuellen Spielfeld. Nur die Spieler sehen ihn.
    if g.exit_zone_id is null then
      update public.games set exit_zone_id = (
        select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
        order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.field_phase(g.id, g.current_day)), z.geom), z.geom) then 0 else 1 end, random()
        limit 1)
      where id = g.id returning * into g;
    end if;
    update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
    update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(nullif((select name from public.zones where id = g.exit_zone_id), ''), 'siehe Karte'),
      'Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'kritisch');
    perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
      'Ihr erfahrt ihn nicht. Ankunft bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || '.', '{}', 'hoch');
    -- Spieler, die schon im Radius stehen, gelten sofort als angekommen.
    perform public.recheck_exit(g, v_now);
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
revoke execute on function public.tick_game_basis(uuid) from public, anon, authenticated;

-- tick_game (zuletzt in 0022_spielzeit_fluchtpunkt_blitzjagd.sql)
create or replace function public.tick_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_open timestamptz;
  v_name text;
  v_p public.participants;
  v_pos public.positions;
  v_grace int;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or g.status not in ('laeuft', 'finale') or g.paused_at is not null then
    perform public.tick_game_basis(p_game_id);
    return;
  end if;
  v_cfg := g.config_json;
  v_now := now() + g.clock_offset;
  v_open := g.ends_at - make_interval(mins => public.exit_usable_minutes(v_cfg));

  -- Bekanntgabe (vor dem Basis-Tick, damit dort nichts doppelt passiert).
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    select * into g from public.games where id = p_game_id for update;
    if not g.exit_revealed then
      if g.exit_zone_id is null then
        update public.games set exit_zone_id = (
          select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
          order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.phase_count(v_cfg)), z.geom), z.geom) then 0 else 1 end, random()
          limit 1)
        where id = g.id returning * into g;
      end if;
      update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
      update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
      select coalesce(nullif(name, ''), 'siehe Karte') into v_name from public.zones where id = g.exit_zone_id;
      perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(v_name, 'siehe Karte'),
        'Er ist erst ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' offen. Seid zwischen '
        || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' und ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI')
        || ' im Kreis.', jsonb_build_object('open_at', v_open), 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
        'Ihr erfahrt ihn nicht. Er ist ab ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' bis zum Spielende offen.', '{}', 'hoch');
    end if;
  end if;

  perform public.tick_game_basis(p_game_id);

  select * into g from public.games where id = p_game_id;
  if g.status not in ('laeuft', 'finale') or g.paused_at is not null then return; end if;

  -- Freigabe: ab jetzt zählt, wer im Kreis steht.
  if g.exit_revealed and g.exit_zone_id is not null and v_now >= v_open and not coalesce((g.state_json ->> 'exit_open')::boolean, false) then
    update public.games set state_json = state_json || '{"exit_open": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_open', 'Fluchtpunkt ist jetzt offen!',
      'Seid bis ' || to_char(g.ends_at at time zone g.timezone, 'HH24:MI') || ' im Kreis, dann seid ihr gerettet.', '{}', 'kritisch');
    perform public.recheck_exit(g, v_now);
    select * into g from public.games where id = p_game_id;
    if g.status not in ('laeuft', 'finale') then perform public.bump(g.id); return; end if;
  end if;

  -- Countdown abgelaufen, aber kein neuer Standort: mit dem letzten bekannten Standort weiterprüfen.
  v_grace := public.cfg_int(v_cfg, 'out_of_bounds', 'grace_seconds', 60);
  for v_p in select * from public.participants
             where game_id = g.id and role = 'spieler' and state = 'aktiv'
               and ((out_pending_since is not null and out_pending_since <= v_now - make_interval(secs => v_grace))
                 or (restricted_zone_id is not null and not restricted_violated and restricted_since <= v_now - make_interval(secs => v_grace))) loop
    select * into v_pos from public.positions where participant_id = v_p.id;
    if v_pos.participant_id is not null then
      perform public.check_player_zone(g, v_p, v_pos.geom, v_now);
    end if;
  end loop;
  perform public.bump(g.id);
end; $$;
revoke execute on function public.tick_game(uuid) from public, anon, authenticated;

-- ===== 0026_standort_takt.sql =====

-- Standort fix alle 5 s und Standortdaten bleiben erhalten:
-- 1. Alle Teilnehmenden senden ihren Standort immer alle 5 s (nicht mehr einstellbar). So kommen auch der
--    Nähe-Radar-Alarm und die Anzeige "nah / nicht mehr nah" nach wenigen Sekunden.
-- 2. Die aufgezeichneten Wege (für die Wiederholung) werden fix 30 Tage nach Spielende gelöscht (nicht mehr
--    einstellbar). Jeder Teilnehmende kann bei einem vergangenen Spiel "Für immer behalten" drücken, dann
--    bleibt dieses Spiel ganz erhalten. Wird ein Spiel gelöscht, verschwinden seine Daten wie bisher mit ihm.

alter function public.report_location(uuid, jsonb) rename to report_location_basis;
revoke execute on function public.report_location_basis(uuid, jsonb) from public, anon, authenticated;

create or replace function public.report_location(p_game_id uuid, p_samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
begin
  v_res := public.report_location_basis(p_game_id, p_samples);
  if v_res ? 'interval_s' then
    v_res := v_res || jsonb_build_object('interval_s', 5);
  end if;
  return v_res;
end; $$;
revoke execute on function public.report_location(uuid, jsonb) from public, anon;
grant execute on function public.report_location(uuid, jsonb) to authenticated;

-- Für immer behalten (je Spiel)
alter table public.games add column if not exists keep_forever boolean not null default false;

-- Nächtliches Löschen (pg_cron 03:17, aus 0007): fix 30 Tage, ausser das Spiel wird für immer behalten.
create or replace function public.purge_old_locations()
returns void language sql security definer set search_path = public as $$
  delete from public.location_samples s using public.games g
  where s.game_id = g.id and g.status in ('beendet', 'archiviert') and not g.keep_forever
    and g.ended_at < now() - interval '30 days';
$$;
revoke execute on function public.purge_old_locations() from public, anon, authenticated;

-- Knopf "Für immer behalten" / "Nicht mehr behalten": jeder Teilnehmende des Spiels, nur nach Spielende.
create or replace function public.set_keep_game(p_game_id uuid, p_keep boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or not public.is_game_member(p_game_id) then raise exception 'Du bist nicht in diesem Spiel.' using errcode = '42501'; end if;
  if g.status not in ('beendet', 'archiviert') then raise exception 'Das geht erst nach Spielende.' using errcode = 'P0001'; end if;
  if not p_keep and g.ended_at < now() - interval '30 days' then
    raise exception 'Das Spiel ist älter als 30 Tage. Ohne "Für immer behalten" würde die Wiederholung sofort gelöscht.' using errcode = 'P0001';
  end if;
  update public.games set keep_forever = p_keep where id = p_game_id;
  return p_keep;
end; $$;
revoke execute on function public.set_keep_game(uuid, boolean) from public, anon;
grant execute on function public.set_keep_game(uuid, boolean) to authenticated;

-- Wiederholung: zusätzlich, ob das Spiel für immer behalten wird und wann es endete (zuletzt in 0023).
alter function public.game_replay(uuid) rename to game_replay_basis;
revoke execute on function public.game_replay_basis(uuid) from public, anon, authenticated;
create or replace function public.game_replay(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.games;
begin
  select * into g from public.games where id = p_game_id;
  return public.game_replay_basis(p_game_id) || jsonb_build_object('keep_forever', g.keep_forever, 'ended_at', g.ended_at);
end; $$;
revoke execute on function public.game_replay(uuid) from public, anon;
grant execute on function public.game_replay(uuid) to authenticated;

-- ===== 0027_fluchtpunkt_nach_spielzeit.sql =====

-- Runde 17 (Rückmeldungen Marvin, 2026-11-14)
-- 1. Spielfeld verlassen: kein Countdown mehr, sofort live für die Hunter und Alarm. (Gefahrenzonen behalten den Countdown.)
-- 2. Fluchtpunkt: öffnet erst, wenn die Spielzeit abgelaufen ist. Danach läuft das Spiel weiter, bis alle Spieler gefangen
--    oder am Fluchtpunkt sind, höchstens aber die eingestellte Zeit (exit.arrival_deadline_offset_minutes, Standard 60 min).
--    Wer dann nicht angekommen ist, hat verloren. Ohne Fluchtpunkt endet das Spiel mit der Spielzeit; wer noch frei ist, gewinnt.

-- ---------------------------------------------------------------------------
-- Fluchtpunkt öffnet mit dem Ende der Spielzeit (nicht mehr X min vorher).
create or replace function public.exit_usable_minutes(p_cfg jsonb)
returns int language sql immutable as $$ select 0 $$;

-- Höchstzeit nach der Spielzeit (min), 5 bis 240; alte Spiele mit 0 bekommen 60. Ohne Fluchtpunkt 0.
create or replace function public.exit_extra_minutes(p_cfg jsonb)
returns int language sql immutable as $$
  select case when public.cfg_bool(p_cfg, 'exit', 'enabled', true) and public.cfg_text(p_cfg, 'win', 'mode', 'alle_ueberlebenden') <> 'letzter_ueberlebender'
    then least(240, greatest(5, coalesce(nullif(public.cfg_int(p_cfg, 'exit', 'arrival_deadline_offset_minutes', 60), 0), 60))) else 0 end;
$$;

-- Spielende (deadline_at) folgt immer der Spielzeit (ends_at) plus Höchstzeit: beim Start, bei Pausen und bei
-- Regeländerungen in der Pause. So müssen die vielen Stellen, die ends_at setzen, nicht einzeln angepasst werden.
create or replace function public.games_deadline()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.ends_at is not null and new.status in ('vorsprung', 'laeuft', 'finale')
     and (tg_op = 'INSERT' or new.ends_at is distinct from old.ends_at or new.config_json is distinct from old.config_json
          or new.deadline_at is distinct from old.deadline_at) then
    new.deadline_at := new.ends_at + make_interval(mins => public.exit_extra_minutes(new.config_json));
  end if;
  return new;
end; $$;
drop trigger if exists games_deadline on public.games;
create trigger games_deadline before insert or update on public.games
for each row execute function public.games_deadline();

-- Laufende Spiele gleich nachziehen.
update public.games set deadline_at = ends_at + make_interval(mins => public.exit_extra_minutes(config_json))
where status in ('vorsprung', 'laeuft', 'finale') and ends_at is not null;

-- ---------------------------------------------------------------------------
-- Spielfeld verlassen: sofort live und Alarm (zuletzt in 0016).
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
  v_exits int := p_p.out_exits;
  v_danger int := p_p.danger_exits;
begin
  v_area := public.allowed_area(p_game.id, p_p.id, p_game.current_day, public.cfg_bool(v_cfg, 'zone', 'sections_per_player', false));
  v_inside := v_area is null or ST_DWithin(v_area::geography, p_point::geography, v_tol);

  -- Gefahrenzonen: gleiche Regel wie beim Verlassen des Spielfelds, mit eigener Zählung.
  -- 1. und 2. Mal: Alarm und Countdown, danach live. Ab dem 3. Mal: sofort live. Zu lange drin: Folge wie ausserhalb.
  -- Zonen mit "Überqueren erlaubt" (z. B. Brücken) lösen nichts aus, solange man sie in der erlaubten Zeit überquert.
  select * into v_restricted from public.zones where game_id = p_game.id and kind = 'sperrzone' and ST_Covers(geom, p_point) limit 1;
  if v_restricted.id is not null and v_restricted.crossing_allowed then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false where id = p_p.id;
    elsif not p_p.restricted_violated and p_now - p_p.restricted_since > make_interval(secs => v_cross) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.create_violation(p_game, p_p.id, 'sperrzone',
        jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
    end if;
  elsif v_restricted.id is not null then
    if p_p.restricted_zone_id is distinct from v_restricted.id then
      update public.participants set restricted_zone_id = v_restricted.id, restricted_since = p_now, restricted_violated = false,
        danger_exits = danger_exits + 1 where id = p_p.id
      returning danger_exits into v_danger;
      p_p.restricted_since := p_now;
      p_p.restricted_violated := false;
      if v_grace > 0 and v_danger <= 2 then
        perform public.notify(p_game.id, null, p_p.id, 'danger_warning', 'Gefahrenzone! Sofort raus',
          coalesce(nullif(v_restricted.name, ''), 'Gefahrenzone') || ': du hast ' || v_grace || ' Sekunden Zeit, sonst sehen dich die Hunter live ('
          || v_danger || '. Mal von 2 mit Countdown).',
          jsonb_build_object('deadline', p_now + make_interval(secs => v_grace), 'exits', v_danger), 'kritisch');
      else
        p_p.restricted_since := p_now - make_interval(secs => v_grace);
      end if;
    end if;
    if not p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) then
      update public.participants set restricted_violated = true where id = p_p.id;
      perform public.open_live_window(p_game.id, p_p.id, 'gefahrenzone', p_now, null);
      perform public.notify(p_game.id, null, p_p.id, 'danger_live', 'Du bist in einer Gefahrenzone!',
        'Die Hunter sehen dich live. Verlass die Zone sofort. Nach ' || v_max || ' min gilt: ' ||
        case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch') when 'catch' then 'gefangen' when 'disqualify' then 'disqualifiziert' else 'Strafe' end || '.',
        '{}', 'kritisch');
      perform public.notify(p_game.id, 'taskforce', null, 'danger_live', public.pname(p_p.id) || ' ist in einer Gefahrenzone', 'Live-Standort sichtbar.', '{}', 'hoch');
    elsif p_p.restricted_violated and p_now - p_p.restricted_since >= make_interval(secs => v_grace) + make_interval(mins => v_max) then
      update public.participants set restricted_zone_id = null, restricted_since = null, restricted_violated = false where id = p_p.id;
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
        when 'catch' then perform public.auto_catch(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        when 'disqualify' then perform public.disqualify(p_game, p_p.id, 'Zu lange in einer Gefahrenzone', p_now);
        else perform public.create_violation(p_game, p_p.id, 'sperrzone', jsonb_build_object('zone', v_restricted.name, 'lat', ST_Y(p_point), 'lng', ST_X(p_point)), p_now);
      end case;
      return;
    end if;
  elsif p_p.restricted_zone_id is not null then
    if p_p.restricted_violated then
      perform public.close_live_windows(p_p.id, 'gefahrenzone', p_now);
      perform public.notify(p_game.id, 'taskforce', null, 'back_inside', public.pname(p_p.id) || ' hat die Gefahrenzone verlassen', 'Live-Standort beendet.', '{}', 'normal');
    end if;
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
  -- Spielfeld verlassen: kein Countdown mehr. Sofort live für die Hunter und Alarm auf dem Handy.
  update public.participants set state = 'ausserhalb', out_pending_since = coalesce(out_pending_since, p_now), out_exits = out_exits + 1
  where id = p_p.id;
  perform public.open_live_window(p_game.id, p_p.id, 'ausserhalb', p_now, null);
  perform public.notify(p_game.id, null, p_p.id, 'outside', 'Du bist ausserhalb des Spielfelds!',
    'Die Hunter sehen dich jetzt live. Geh sofort zurück ins Spielfeld. Noch ' || greatest(0, v_max - p_p.out_accum_s / 60) || ' min, dann ' ||
    case public.cfg_text(v_cfg, 'out_of_bounds', 'on_timeout', 'catch')
      when 'catch' then 'giltst du als gefangen' when 'disqualify' then 'bist du disqualifiziert' else 'gibt es eine Strafe' end || '.',
    '{}', 'kritisch');
  perform public.notify(p_game.id, 'taskforce', null, 'outside', public.pname(p_p.id) || ' ist ausserhalb', 'Live-Standort sichtbar.', '{}', 'hoch');
end; $$;

-- ---------------------------------------------------------------------------
-- Spieltakt: Texte zum Fluchtpunkt (öffnet am Ende der Spielzeit, Ankunft bis zum Spielende). Zuletzt in 0025.
create or replace function public.tick_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.games;
  v_cfg jsonb;
  v_now timestamptz;
  v_open timestamptz;
  v_name text;
  v_p public.participants;
  v_pos public.positions;
  v_grace int;
begin
  select * into g from public.games where id = p_game_id;
  if g.id is null or g.status not in ('laeuft', 'finale') or g.paused_at is not null then
    perform public.tick_game_basis(p_game_id);
    return;
  end if;
  v_cfg := g.config_json;
  v_now := now() + g.clock_offset;
  v_open := g.ends_at - make_interval(mins => public.exit_usable_minutes(v_cfg));

  -- Bekanntgabe (vor dem Basis-Tick, damit dort nichts doppelt passiert).
  if public.cfg_bool(v_cfg, 'exit', 'enabled', true) and not g.exit_revealed and g.exit_reveal_at is not null and g.exit_reveal_at <= v_now then
    select * into g from public.games where id = p_game_id for update;
    if not g.exit_revealed then
      if g.exit_zone_id is null then
        update public.games set exit_zone_id = (
          select z.id from public.zones z where z.game_id = g.id and z.kind = 'exit'
          order by case when ST_Covers(coalesce(public.spielfeld_day(g.id, public.phase_count(v_cfg)), z.geom), z.geom) then 0 else 1 end, random()
          limit 1)
        where id = g.id returning * into g;
      end if;
      update public.zones set visible_from = v_now, visible_to = 'spieler' where id = g.exit_zone_id;
      update public.games set exit_revealed = true, status = 'finale', map_version = map_version + 1 where id = g.id returning * into g;
      select coalesce(nullif(name, ''), 'siehe Karte') into v_name from public.zones where id = g.exit_zone_id;
      perform public.notify(g.id, 'spieler', null, 'exit_reveal', 'Fluchtpunkt bekannt: ' || coalesce(v_name, 'siehe Karte'),
        'Er öffnet um ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || ' (Ende der Spielzeit). Dann habt ihr bis '
        || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' Zeit, in den Kreis zu kommen.', jsonb_build_object('open_at', v_open), 'kritisch');
      perform public.notify(g.id, 'taskforce', null, 'exit_reveal', 'Die Spieler kennen jetzt den Fluchtpunkt',
        'Ihr erfahrt ihn nicht. Er öffnet um ' || to_char(v_open at time zone g.timezone, 'HH24:MI') || '. Gejagt wird bis '
        || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' oder bis alle gefangen oder angekommen sind.', '{}', 'hoch');
    end if;
  end if;

  perform public.tick_game_basis(p_game_id);

  select * into g from public.games where id = p_game_id;
  if g.status not in ('laeuft', 'finale') or g.paused_at is not null then return; end if;

  -- Freigabe: ab jetzt zählt, wer im Kreis steht.
  if g.exit_revealed and g.exit_zone_id is not null and v_now >= v_open and not coalesce((g.state_json ->> 'exit_open')::boolean, false) then
    update public.games set state_json = state_json || '{"exit_open": true}' where id = g.id returning * into g;
    perform public.notify(g.id, 'spieler', null, 'exit_open', 'Fluchtpunkt ist jetzt offen!',
      'Wer bis ' || to_char(g.deadline_at at time zone g.timezone, 'HH24:MI') || ' in den Kreis kommt, ist gerettet.', '{}', 'kritisch');
    perform public.recheck_exit(g, v_now);
    select * into g from public.games where id = p_game_id;
    if g.status not in ('laeuft', 'finale') then perform public.bump(g.id); return; end if;
  end if;

  -- Countdown abgelaufen, aber kein neuer Standort: mit dem letzten bekannten Standort weiterprüfen.
  v_grace := public.cfg_int(v_cfg, 'out_of_bounds', 'grace_seconds', 60);
  for v_p in select * from public.participants
             where game_id = g.id and role = 'spieler' and state = 'aktiv'
               and ((out_pending_since is not null and out_pending_since <= v_now - make_interval(secs => v_grace))
                 or (restricted_zone_id is not null and not restricted_violated and restricted_since <= v_now - make_interval(secs => v_grace))) loop
    select * into v_pos from public.positions where participant_id = v_p.id;
    if v_pos.participant_id is not null then
      perform public.check_player_zone(g, v_p, v_pos.geom, v_now);
    end if;
  end loop;
  perform public.bump(g.id);
end; $$;
revoke execute on function public.tick_game(uuid) from public, anon, authenticated;

-- ===== 0028_hunter_zeichnungen.sql =====

-- Runde 18: Hunter zeichnen auf der Karte (Punkte, Striche, Kreise, Flächen, mit Farbe und Text).
-- Alles, was ein Hunter zeichnet, sehen alle Hunter des Spiels sofort, und jeder Hunter kann es ändern oder löschen.
-- Spieler und Zuschauer sehen es nie.

create table if not exists public.hunter_drawings (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games (id) on delete cascade,
  kind text not null check (kind in ('punkt', 'strich', 'kreis', 'flaeche')),
  -- GeoJSON-Geometrie: Punkt (auch Mitte des Kreises), Linie oder Polygon.
  geom jsonb not null,
  radius_m real,
  color text not null default '#ff3b30',
  label text not null default '',
  created_by uuid references public.participants (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hunter_drawings_game_idx on public.hunter_drawings (game_id);

-- Ist die angemeldete Person Hunter in diesem Spiel?
create or replace function public.is_game_hunter(p_game_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.participants where game_id = p_game_id and user_id = auth.uid() and role = 'hunter');
$$;
revoke execute on function public.is_game_hunter(uuid) from public, anon;
grant execute on function public.is_game_hunter(uuid) to authenticated;

alter table public.hunter_drawings enable row level security;
drop policy if exists "Hunter-Zeichnungen: lesen" on public.hunter_drawings;
drop policy if exists "Hunter-Zeichnungen: neu" on public.hunter_drawings;
drop policy if exists "Hunter-Zeichnungen: ändern" on public.hunter_drawings;
drop policy if exists "Hunter-Zeichnungen: löschen" on public.hunter_drawings;
create policy "Hunter-Zeichnungen: lesen" on public.hunter_drawings for select to authenticated using (public.is_game_hunter(game_id));
create policy "Hunter-Zeichnungen: neu" on public.hunter_drawings for insert to authenticated with check (public.is_game_hunter(game_id));
create policy "Hunter-Zeichnungen: ändern" on public.hunter_drawings for update to authenticated using (public.is_game_hunter(game_id)) with check (public.is_game_hunter(game_id));
create policy "Hunter-Zeichnungen: löschen" on public.hunter_drawings for delete to authenticated using (public.is_game_hunter(game_id));
grant select, insert, update, delete on public.hunter_drawings to authenticated;

-- Wer zeichnet, wird selbst eingetragen; Zeit der letzten Änderung.
create or replace function public.hunter_drawings_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := (select id from public.participants where game_id = new.game_id and user_id = auth.uid() limit 1);
  end if;
  new.updated_at := now();
  return new;
end; $$;
drop trigger if exists hunter_drawings_stamp on public.hunter_drawings;
create trigger hunter_drawings_stamp before insert or update on public.hunter_drawings
for each row execute function public.hunter_drawings_stamp();

-- Sofort bei allen Huntern (Live-Verbindung). Bei Löschungen braucht die Live-Verbindung die ganze Zeile.
alter table public.hunter_drawings replica identity full;
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'hunter_drawings') then
    alter publication supabase_realtime add table public.hunter_drawings;
  end if;
end $$;
