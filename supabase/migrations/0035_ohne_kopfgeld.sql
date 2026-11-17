-- Kopfgeld für Hunter gibt es nicht mehr: nirgends angezeigt und nie mehr gezählt.
update public.games
set config_json = case when jsonb_typeof(config_json -> 'taskforce') = 'object'
  then jsonb_set(config_json, '{taskforce,bounty_per_catch}', '0'::jsonb, true)
  else config_json || '{"taskforce": {"bounty_per_catch": 0}}'::jsonb end
where config_json is not null;
update public.participants set bounty = 0 where bounty <> 0;
