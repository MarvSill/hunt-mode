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
