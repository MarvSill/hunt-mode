-- Runde 21 (Korrektur): Beim ausgefallenen Ping sehen die Hunter nur, dass der Spieler gerade Regeneration hat,
-- nicht, wie lange der Joker noch läuft (ersetzt die Meldung aus 0033_regeneration_meldung.sql).

create or replace function public.process_ping_due(p_game public.games, p_p public.participants, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_p.next_ping_at is not null and p_p.next_ping_at <= p_now and p_p.state in ('aktiv', 'ausserhalb')
     and public.has_effect(p_p.id, 'regeneration', p_now) then
    perform public.notify(p_game.id, 'taskforce', null, 'ping_regeneration', 'Kein Ping: ' || public.pname(p_p.id),
      'Hat gerade den Regeneration-Joker – kein Fehler der App.', '{}', 'normal');
  end if;
  perform public.process_ping_due_basis(p_game, p_p, p_now);
end; $$;
revoke execute on function public.process_ping_due(public.games, public.participants, timestamptz) from public, anon, authenticated;
