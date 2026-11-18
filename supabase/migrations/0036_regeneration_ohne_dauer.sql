-- Hunter erfahren nie, dass ein Spieler einen Joker einsetzt.
-- Vorher bekamen sie beim Einsetzen der Regeneration „Joker: Regeneration – Ein Spieler ist für 15 min nicht ortbar.“
-- Jetzt fällt diese Meldung ganz weg. Die Hunter erfahren es nur noch, wenn ihr regulärer Ping wegen der
-- Regeneration ausfällt („Kein Ping: Spieler A“, aus 0033/0034, Art 'ping_regeneration').
-- (Die Meldung entsteht in use_item_basis, zuletzt in 0020_nummern.sql; statt die ganze Funktion zu kopieren,
--  wird sie beim Speichern verworfen.)

create or replace function public.notifications_ohne_joker_dauer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'joker' and new.audience = 'taskforce' then
    return null;
  end if;
  return new;
end; $$;

drop trigger if exists notifications_ohne_joker_dauer on public.notifications;
create trigger notifications_ohne_joker_dauer before insert on public.notifications
for each row execute function public.notifications_ohne_joker_dauer();

-- Schon vorhandene Meldungen dieser Art an die Hunter löschen.
delete from public.notifications where kind = 'joker' and audience = 'taskforce';
