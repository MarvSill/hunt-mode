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
