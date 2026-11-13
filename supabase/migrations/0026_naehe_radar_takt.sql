-- Nähe-Radar schneller: Solange in einem Spiel ein Nähe-Radar läuft, senden alle Hunter und der Spieler
-- mit dem Radar ihren Standort alle 5 s statt im normalen Takt. So kommt der Alarm wenige Sekunden,
-- nachdem ein Hunter nah kommt, und die Anzeige wechselt schnell zurück, sobald er wieder weg ist.

alter function public.report_location(uuid, jsonb) rename to report_location_basis;
revoke execute on function public.report_location_basis(uuid, jsonb) from public, anon, authenticated;

create or replace function public.report_location(p_game_id uuid, p_samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
  v_p public.participants;
  v_now timestamptz;
begin
  v_res := public.report_location_basis(p_game_id, p_samples);
  if v_res ? 'interval_s' and coalesce((v_res ->> 'interval_s')::int, 15) > 5 then
    select * into v_p from public.participants where game_id = p_game_id and user_id = auth.uid() limit 1;
    v_now := public.engine_now(p_game_id);
    if v_p.id is not null and exists (
      select 1 from public.active_effects e
      where e.game_id = p_game_id and e.type = 'naehe_radar' and e.starts_at <= v_now and e.ends_at > v_now
        and (v_p.role = 'hunter' or e.participant_id = v_p.id)
    ) then
      v_res := v_res || jsonb_build_object('interval_s', 5);
    end if;
  end if;
  return v_res;
end; $$;
revoke execute on function public.report_location(uuid, jsonb) from public, anon;
grant execute on function public.report_location(uuid, jsonb) to authenticated;
