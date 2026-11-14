-- Runde 20:
-- 1. Verschanzen ganz entfernt (Frage, Zeitzählung, Selbstmeldung).
-- 2. Fangen nur noch über "Fang melden" (der Spieler bestätigt oder lehnt ab). Den Fang-Code gibt es nicht mehr.

-- Meldung beim Ablehnen ohne Hinweis auf den Code (zuletzt in 0023_pause_sicherheit_fang.sql).
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
      public.pname(v_c.runner_id) || ' sagt, es war kein Fang.', '{}', 'hoch');
  end if;
  perform public.bump(g.id);
end; $$;

-- Fang-Code: Funktionen entfernen (die App nutzt sie nicht mehr).
drop function if exists public.my_catch_code(uuid);
drop function if exists public.catch_by_code(uuid, text, double precision, double precision);

-- Gespeicherte Einstellungen: nur noch "Fang melden".
update public.games set config_json = jsonb_set(config_json, '{catch,method}', '["touch_confirm"]'::jsonb, true)
where config_json ? 'catch';
update public.config_templates set config_json = jsonb_set(config_json, '{catch,method}', '["touch_confirm"]'::jsonb, true)
where config_json ? 'catch';


-- ---------------------------------------------------------------------------
-- Verschanzen gibt es nicht mehr: keine Frage "Bist du verschanzt?", keine Zeitzählung, keine Meldungen.
update public.games set config_json = jsonb_set(config_json, '{hideout,enabled}', 'false'::jsonb, true);
update public.config_templates set config_json = jsonb_set(config_json, '{hideout,enabled}', 'false'::jsonb, true);
update public.hideouts set status = 'abgelaufen', inside = false, left_at = now() where status = 'aktiv';
update public.participants set hideout_prompted_at = null where hideout_prompted_at is not null;

-- Erkennung abgeschaltet (zuletzt in 0004_engine_logik.sql): tut nichts mehr.
create or replace function public.check_hideout(p_game public.games, p_p public.participants, p_point extensions.geometry, p_now timestamptz)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  return;
end; $$;

-- Selbst melden gibt es nicht mehr.
drop function if exists public.hideout_report(uuid, boolean);
