-- Runde 21: Fällt ein normaler Ping aus, weil der Spieler den Joker Regeneration einsetzt,
-- bekommen alle Hunter genau zum Zeitpunkt dieses Pings eine Meldung. So wissen sie, dass es kein Fehler der App ist.

alter function public.process_ping_due(public.games, public.participants, timestamptz) rename to process_ping_due_basis;
revoke execute on function public.process_ping_due_basis(public.games, public.participants, timestamptz) from public, anon, authenticated;

create or replace function public.process_ping_due(p_game public.games, p_p public.participants, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_end timestamptz;
  v_min int;
begin
  if p_p.next_ping_at is not null and p_p.next_ping_at <= p_now and p_p.state in ('aktiv', 'ausserhalb')
     and public.has_effect(p_p.id, 'regeneration', p_now) then
    select max(ends_at) into v_end from public.active_effects
    where participant_id = p_p.id and type = 'regeneration' and starts_at <= p_now and (ends_at is null or ends_at > p_now);
    v_min := greatest(1, ceil(extract(epoch from (v_end - p_now)) / 60))::int;
    perform public.notify(p_game.id, 'taskforce', null, 'ping_regeneration', 'Kein Ping: ' || public.pname(p_p.id),
      case when v_end is null then 'Regeneration-Joker aktiv – kein Fehler der App.'
        else 'Regeneration-Joker aktiv, noch ' || v_min || ' min – kein Fehler der App.' end,
      '{}', 'normal');
  end if;
  perform public.process_ping_due_basis(p_game, p_p, p_now);
end; $$;
revoke execute on function public.process_ping_due(public.games, public.participants, timestamptz) from public, anon, authenticated;
