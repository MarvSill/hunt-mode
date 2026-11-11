import NumberField from './NumberField';
import type { ReactNode } from 'react';
import { JOKER_TYPES, type GameConfig } from '../shared/config';
import { QUICK_HELP, SETTING_HELP } from '../shared/help';
import { optionLabel } from '../shared/schemaMeta';
import { huntMinutes, timeLimits } from '../shared/timeRules';
import Icon from './Icon';
import Info from './Info';
import { formatMinutes } from '../shared/format';
import { t, lazy } from '../i18n';

export const JOKER_LABELS: Record<string, string> = lazy({
  regeneration: 'Regeneration (keine Pings, keine Blitzjagd auf ihn)',
  hunter_erfragen: 'Hunter-Standorte (einmaliger Ping aller Hunter)',
});

/**
 * Die wichtigsten Regeln auf einen Blick, mit grossen Knöpfen statt Zahlenfeldern.
 * Alles Weitere steht im vollständigen Regel-Editor darunter.
 */
interface Props {
  config: GameConfig;
  onChange: (config: GameConfig) => void;
}

type Sections = Record<string, Record<string, unknown>>;
type JokerEntry = GameConfig['joker']['types'][number];

export default function QuickSettings({ config, onChange }: Props) {
  function set(section: keyof GameConfig, key: string, value: unknown) {
    const next = structuredClone(config) as unknown as Sections;
    next[section][key] = value;
    onChange(next as unknown as GameConfig);
  }

  const g = config.game;
  const limits = timeLimits(config);
  /** Höchstwert: Schema-Grenze oder, falls kleiner, was die Spieldauer erlaubt. */
  const lim = (path: string, max: number) => Math.min(max, limits[path]?.max ?? max);
  const j = config.joker;
  const hunt = huntMinutes(config);
  const latestJoker = Math.max(0, hunt - 5);

  function setJokers(list: JokerEntry[]) {
    const next = structuredClone(config);
    // Reihenfolge bleibt, wie sie ist: sonst springt beim Tippen die Zeile weg.
    next.joker.types = list;
    onChange(next);
  }
  function addJoker() {
    const last = j.types.reduce((m, x) => Math.max(m, x.after_minutes), 0);
    const after = Math.min(latestJoker, j.types.length ? last + Math.max(5, Math.round(hunt / 4 / 5) * 5) : Math.round(hunt / 6 / 5) * 5);
    setJokers([...j.types, { type: 'regeneration', minutes: Math.min(hunt, 15), after_minutes: after }]);
  }

  function setDuration(min: number) {
    const next = structuredClone(config);
    next.game.duration_minutes = min;
    next.game.day_length_minutes = Math.min(1440, min);
    onChange(next);
  }

  const firstJoker = j.types.length ? Math.min(...j.types.map((x) => x.after_minutes)) : 0;

  return (
    <div>
      <Box title={t('Spieler und Hunter')} icon="👥" summary={t('{0} Spieler · {1} Hunter', { 0: config.roles.players_max, 1: config.roles.hunters_max })} info={SETTING_HELP.roles}>
        <Stepper label={t('Spieler')} value={config.roles.players_max} min={1} max={100} onChange={(v) => set('roles', 'players_max', v)} />
        <Stepper label={t('Hunter')} value={config.roles.hunters_max} min={1} max={50} onChange={(v) => set('roles', 'hunters_max', v)} />
        <Choice
          label={t('Wer bestimmt die Rollen?')}
          value={config.roles.assignment}
          options={[['host', t('Ich als Host')], ['zufall', t('Zufall')], ['selbst', t('Jeder selbst')]]}
          onChange={(v) => set('roles', 'assignment', v)}
        />
      </Box>

      <Box title={t('Zeit')} icon="⏱️" summary={t('{0} am Stück · {1} Vorsprung', { 0: formatMinutes(g.duration_minutes), 1: formatMinutes(config.start.head_start_minutes) })} info={SETTING_HELP.times}>
        <Duration label={t('Spielzeit (alles inklusive)')} value={g.duration_minutes} min={15} max={20160} onChange={setDuration} />
        <Duration label={t('Vorsprung der Spieler')} value={config.start.head_start_minutes} min={0} max={Math.min(600, Math.max(0, g.duration_minutes - 5))}
          onChange={(v) => set('start', 'head_start_minutes', v)} />
        <div className="muted small">{t('Die Spielzeit zählt ab dem Start und enthält den Vorsprung. Gejagt wird danach noch {0}. Das Spiel endet pünktlich, ohne Nachspielzeit.', { 0: formatMinutes(hunt) })}</div>
        <Toggle label={t('Hunter warten am Startpunkt während des Vorsprungs')} value={config.start.hunters_must_stay_in_hq}
          onChange={(v) => set('start', 'hunters_must_stay_in_hq', v)} />
      </Box>

      <Box title={t('Pings')} icon="📍" summary={t('alle {0}', { 0: formatMinutes(config.ping.interval_minutes) })} info={SETTING_HELP.pings}>
        <Duration label={t('Ping alle')} value={config.ping.interval_minutes} min={1} max={lim('ping.interval_minutes', 720)}
          onChange={(v) => set('ping', 'interval_minutes', v)} />
        <div className="muted small">{t('Sobald der Vorsprung vorbei ist, kommt sofort der erste Ping. Danach im eingestellten Abstand.')}</div>
        <Toggle label={t('Hunter sehen, wann der nächste Ping kommt')} value={config.ping.reveal_schedule_to_taskforce}
          onChange={(v) => set('ping', 'reveal_schedule_to_taskforce', v)} />
      </Box>

      <Box title={t('Blitzjagd')} icon="⚡" summary={config.speedhunt.enabled ? t('{0} im Spiel · {1} Abfragen', { 0: config.speedhunt.quota_per_day[0] ?? 0, 1: config.speedhunt.queries }) : t('aus')} info={SETTING_HELP.speedhunt}>
        <Toggle label={t('Blitzjagden erlaubt')} value={config.speedhunt.enabled} onChange={(v) => set('speedhunt', 'enabled', v)} />
        {config.speedhunt.enabled && (
          <>
            <Stepper label={t('Blitzjagden im ganzen Spiel')} value={config.speedhunt.quota_per_day[0] ?? 0} min={0} max={20}
              onChange={(v) => set('speedhunt', 'quota_per_day', [v])} />
            <Stepper label={t('Standort-Abfragen pro Blitzjagd')} value={config.speedhunt.queries} min={1} max={20}
              onChange={(v) => set('speedhunt', 'queries', v)} />
            <div className="muted small">{t('Blitzjagden starten nur die Hunter. Eine Blitzjagd hat kein Zeitlimit: sie endet, wenn alle Abfragen gemacht sind oder das Ziel gefangen ist.')}</div>
          </>
        )}
      </Box>

      <Box title={t('Fangen und Gewinnen')} icon="🏁" summary={`${t('Code oder Bestätigung')}${config.exit.enabled ? t(' · mit Fluchtpunkt') : ''}`} info={SETTING_HELP.catch}>
        <div className="field">
          <span>{t('Wie wird gefangen?')} <Hint label={t('Wie wird gefangen?')} /></span>
          <span className="muted small">{t('Immer beide Wege: Zahlencode eingeben oder Fang melden und der Spieler bestätigt.')}</span>
        </div>
        <Toggle label={t('Fluchtpunkt am Schluss (Spieler müssen hin)')} value={config.exit.enabled} onChange={(v) => set('exit', 'enabled', v)} />
        {config.exit.enabled && (
          <>
            <Duration label={t('Fluchtpunkt bekannt ab (vor Schluss)')} value={config.exit.reveal_minutes_before_end} min={0} max={lim('exit.reveal_minutes_before_end', 1440)}
              onChange={(v) => {
                const next = structuredClone(config);
                next.exit.reveal_minutes_before_end = v;
                next.exit.usable_minutes_before_end = Math.min(next.exit.usable_minutes_before_end, v);
                onChange(next);
              }} />
            <Duration label={t('Fluchtpunkt nutzbar ab (vor Schluss)')} value={config.exit.usable_minutes_before_end} min={0} max={config.exit.reveal_minutes_before_end}
              onChange={(v) => set('exit', 'usable_minutes_before_end', v)} />
            <div className="muted small">{t('Beispiel: bekannt {0} vor Schluss, nutzbar {1} vor Schluss. Die Spieler sehen den Fluchtpunkt dann schon, gerettet ist aber nur, wer zwischen der Freigabe und dem Spielende im Kreis ist.', { 0: formatMinutes(config.exit.reveal_minutes_before_end), 1: formatMinutes(config.exit.usable_minutes_before_end) })}</div>
          </>
        )}
      </Box>

      <Box title={t('Joker')} icon="🃏" summary={j.enabled && j.types.length ? t('{0} Joker · erster nach {1}', { 0: j.types.length, 1: formatMinutes(firstJoker) }) : t('aus')} info={SETTING_HELP.joker}>
        <Toggle label={t('Joker im Spiel')} value={j.enabled} onChange={(v) => set('joker', 'enabled', v)} />
        {j.enabled && (
          <>
            <div className="muted small">{t('Jeder Joker wird nach der eingestellten Spielzeit für alle Spieler freigeschaltet. Wirken tut er erst, wenn der Spieler ihn einsetzt.')}</div>
            {j.types.map((x, i) => (
              <div key={i} className="sub stack" style={{ gap: 4 }}>
                <div className="row" style={{ flexWrap: 'nowrap' }}>
                  <select aria-label={t('Joker {0}', { 0: i + 1 })} value={x.type} style={{ flex: 1 }}
                    onChange={(e) => {
                      const type = e.target.value as JokerEntry['type'];
                      setJokers(j.types.map((y, k) => (k === i ? { type, after_minutes: y.after_minutes, ...(type === 'hunter_erfragen' ? {} : { minutes: y.minutes ?? 15 }) } : y)));
                    }}>
                    {JOKER_TYPES.map((t) => <option key={t} value={t}>{JOKER_LABELS[t]}</option>)}
                  </select>
                  <button type="button" className="ghost small" aria-label={t('Joker {0} entfernen', { 0: i + 1 })} onClick={() => setJokers(j.types.filter((_, k) => k !== i))}>✕</button>
                </div>
                <Duration label={t('Freigeschaltet nach (ab Jagdbeginn)')} value={x.after_minutes} min={0} max={latestJoker}
                  onChange={(v) => setJokers(j.types.map((y, k) => (k === i ? { ...y, after_minutes: v } : y)))} />
                {x.type !== 'hunter_erfragen' && (
                  <Duration label={t('Wirkt so lange')} value={x.minutes ?? 15} min={1} max={Math.min(1440, hunt)}
                    onChange={(v) => setJokers(j.types.map((y, k) => (k === i ? { ...y, minutes: v } : y)))} />
                )}
              </div>
            ))}
            <button type="button" className="small" onClick={addJoker}>{t('+ Joker hinzufügen')}</button>
          </>
        )}
      </Box>

      <Box title={t('Fortbewegung')} icon="🚌" summary={[config.transport.motorized_allowed && t('ÖV/Taxi/Auto'), config.transport.bikes_allowed && t('Velo/Trottinett')].filter(Boolean).join(' · ') || t('nur zu Fuss')}>
        <Toggle label={t('ÖV, Taxi und Auto erlaubt')} value={config.transport.motorized_allowed} onChange={(v) => set('transport', 'motorized_allowed', v)} />
        <Toggle label={t('Velo und Trottinett erlaubt')} value={config.transport.bikes_allowed} onChange={(v) => set('transport', 'bikes_allowed', v)} />
        <div className="muted small">{t('Zu Fuss geht immer. Fahrten muss man nicht anmelden, und niemand wird dabei live gezeigt.')}</div>
      </Box>

      <Box title={t('Extras')} icon="✨" summary={[config.hideout.enabled && t('Verschanzen'), config.proximity.enabled && t('Nähe-Alarm'), config.spectator.enabled && t('Zuschauer')].filter(Boolean).join(' · ') || t('keine')} info={SETTING_HELP.extras}>
        <Toggle label={t('Verschanzen-Regel (nicht zu lange am selben Ort)')} value={config.hideout.enabled} onChange={(v) => set('hideout', 'enabled', v)} />
        <Toggle label={t('Alarm, wenn Spieler zusammen laufen')} value={config.proximity.enabled} onChange={(v) => set('proximity', 'enabled', v)} />
        {config.proximity.enabled && (
          <>
            <Stepper label={t('Abstand für den Nähe-Alarm (m)')} value={config.proximity.distance_m} min={10} max={2000} step={10} onChange={(v) => set('proximity', 'distance_m', v)} />
            <Duration label={t('Zeit zum Auseinandergehen')} value={config.proximity.warn_minutes} min={0} max={30} onChange={(v) => set('proximity', 'warn_minutes', v)} />
          </>
        )}
        <Toggle label={t('Zuschauer erlaubt')} value={config.spectator.enabled} onChange={(v) => set('spectator', 'enabled', v)} />
      </Box>
    </div>
  );
}

function Box({ title, icon, summary, info, children }: {
  title: string; icon: string; summary: string; info?: { title: string; text: string }; children: ReactNode;
}) {
  return (
    <details className="acc" data-guide={`q-${title}`}>
      <summary>
        <span className="ico" aria-hidden="true">{icon}</span>
        <span className="spacer">
          <span className="t">{title} {info && <Info title={info.title} text={info.text} />}</span>
          <span className="s" style={{ display: 'block' }}>{summary}</span>
        </span>
        <Icon name="chevron" className="chev" />
      </summary>
      <div className="body">{children}</div>
    </details>
  );
}

function clamp(v: number, min: number, max: number) {
  return Math.min(max, Math.max(min, v));
}

function Stepper({ label, value, min, max, step = 1, onChange }: {
  label: string; value: number; min: number; max: number; step?: number; onChange: (v: number) => void;
}) {
  return (
    <div className="quick-row">
      <span className="spacer">{label} <Hint label={label} /></span>
      <div className="stepper">
        <button type="button" aria-label={t('{0} weniger', { 0: label })} disabled={value <= min} onClick={() => onChange(clamp(value - step, min, max))}>−</button>
        <NumberField label={label} value={value} min={min} max={max} onChange={onChange} />
        <button type="button" aria-label={t('{0} mehr', { 0: label })} disabled={value >= max} onClick={() => onChange(clamp(value + step, min, max))}>+</button>
      </div>
    </div>
  );
}

/** Minuten als Stunden + Minuten eingeben. */
function Duration({ label, value, min, max, onChange }: {
  label: string; value: number; min: number; max: number; onChange: (v: number) => void;
}) {
  const h = Math.floor(value / 60);
  const m = value % 60;
  const put = (hh: number, mm: number) => onChange(clamp(hh * 60 + mm, min, max));
  return (
    <div className="quick-row">
      <span className="spacer">{label} <Hint label={label} /></span>
      <div className="duration">
        <NumberField label={t('{0} Stunden', { 0: label })} value={h} min={0} max={Math.ceil(max / 60)} onChange={(v) => put(v, m)} />
        <span>h</span>
        <NumberField label={t('{0} Minuten', { 0: label })} value={m} min={0} max={59} onChange={(v) => put(h, v)} />
        <span>{t('min')}</span>
      </div>
    </div>
  );
}

function Toggle({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="check">
      <input type="checkbox" checked={value} onChange={(e) => onChange(e.target.checked)} />
      <span>{label} <Hint label={label} /></span>
    </label>
  );
}

function Choice({ label, value, options, onChange }: {
  label: string; value: string; options: [string, string][]; onChange: (v: string) => void;
}) {
  return (
    <div className="field">
      <span>{label} <Hint label={label} /></span>
      <div className="chips">
        {options.map(([v, text]) => (
          <button key={v} type="button" className={`chip${v === value ? ' on' : ''}`} aria-pressed={v === value} onClick={() => onChange(v)}>
            {text || optionLabel(v)}
          </button>
        ))}
      </div>
    </div>
  );
}

/** ⓘ-Knopf mit der Erklärung zur Einstellung, falls es eine gibt. */
function Hint({ label }: { label: string }) {
  // Die Beschriftung kommt schon übersetzt; die Erklärung ist nach dem deutschen Text abgelegt.
  const key = label in QUICK_HELP ? label : Object.keys(QUICK_HELP).find((k) => t(k) === label);
  return key ? <Info title={label} text={t(QUICK_HELP[key])} /> : null;
}
