-- Beim Einsetzen der Regeneration erfahren die Hunter nicht mehr, wie lange sie dauert.
-- Vorher: „Ein Spieler ist für 15 min nicht ortbar.“ Jetzt: „Ein Spieler ist gerade nicht ortbar.“
-- (Die Meldung entsteht in use_item_basis, zuletzt in 0020_nummern.sql; statt die ganze Funktion zu kopieren, wird der Text beim Speichern ersetzt.)

create or replace function public.notifications_ohne_joker_dauer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'joker' and new.title = 'Joker: Regeneration' and new.body ~ '^Ein Spieler ist für \d+ min nicht ortbar\.$' then
    new.body := 'Ein Spieler ist gerade nicht ortbar.';
  end if;
  return new;
end; $$;

drop trigger if exists notifications_ohne_joker_dauer on public.notifications;
create trigger notifications_ohne_joker_dauer before insert on public.notifications
for each row execute function public.notifications_ohne_joker_dauer();

-- Schon vorhandene Meldungen ebenso.
update public.notifications set body = 'Ein Spieler ist gerade nicht ortbar.'
where kind = 'joker' and title = 'Joker: Regeneration' and body ~ '^Ein Spieler ist für \d+ min nicht ortbar\.$';
