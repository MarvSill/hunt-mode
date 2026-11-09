import type { ReactNode } from 'react';
import { CATCH_METHODS, JOKER_TYPES, type GameConfig } from '../shared/config';
import { QUICK_HELP, SETTING_HELP } from '../shared/help';
import { optionLabel } from '../shared/schemaMeta';
import { timeLimits } from '../shared/timeRules';
import Icon from './Icon';
import Info from './Info';
import { formatMinutes } from '../shared/format';

export const JOKER_LABELS: Record<string, string> = {
  regeneration: 'Regeneration (keine Pings)',
  hunter_erfragen: 'Hunter-Standorte sehen (5 min)',
};

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
  const latestJoker = Math.max(0, g.duration_minutes - 5);

  function setJokers(list: JokerEntry[]) {
    const next = structuredClone(config);
    // Nach Freischaltzeit sortiert, damit die Liste der Reihenfolge im Spiel entspricht.
    next.joker.types = [...list].sort((a, b) => a.after_minutes - b.after_minutes);
    onChange(next);
  }
  function addJoker() {
    const last = j.types.reduce((m, x) => Math.max(m, x.after_minutes), 0);
    const after = Math.min(latestJoker, j.types.length ? last + Math.max(5, Math.round(g.duration_minutes / 4 / 5) * 5) : Math.round(g.duration_minutes / 6 / 5) * 5);
    setJokers([...j.types, { type: 'regeneration', minutes: Math.min(g.duration_minutes, 15), after_minutes: after }]);
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
      <Box title="Spieler und Hunter" icon="👥" summary={`${config.roles.players_max} Spieler · ${config.roles.hunters_max} Hunter`} info={SETTING_HELP.roles}>
        <Stepper label="Spieler" value={config.roles.players_max} min={1} max={100} onChange={(v) => set('roles', 'players_max', v)} />
        <Stepper label="Hunter" value={config.roles.hunters_max} min={1} max={50} onChange={(v) => set('roles', 'hunters_max', v)} />
        <Choice
          label="Wer bestimmt die Rollen?"
          value={config.roles.assignment}
          options={[['host', 'Ich als Host'], ['zufall', 'Zufall'], ['selbst', 'Jeder selbst']]}
          onChange={(v) => set('roles', 'assignment', v)}
        />
      </Box>

      <Box title="Zeit" icon="⏱️" summary={`${formatMinutes(g.duration_minutes)} am Stück · ${formatMinutes(config.start.head_start_minutes)} Vorsprung`} info={SETTING_HELP.times}>
        <Duration label="Spieldauer (am Stück)" value={g.duration_minutes} min={15} max={20160} onChange={setDuration} />
        <Duration label="Vorsprung der Spieler" value={config.start.head_start_minutes} min={0} max={600}
          onChange={(v) => set('start', 'head_start_minutes', v)} />
        <Toggle label="Hunter warten im HQ während des Vorsprungs" value={config.start.hunters_must_stay_in_hq}
          onChange={(v) => set('start', 'hunters_must_stay_in_hq', v)} />
      </Box>

      <Box title="Pings" icon="📍" summary={`alle ${formatMinutes(config.ping.interval_minutes)}`} info={SETTING_HELP.pings}>
        <Duration label="Ping alle" value={config.ping.interval_minutes} min={1} max={lim('ping.interval_minutes', 720)}
          onChange={(v) => set('ping', 'interval_minutes', v)} />
        <Duration label="Erster Ping nach dem Vorsprung" value={config.ping.first_ping_delay_minutes} min={0} max={lim('ping.first_ping_delay_minutes', 600)}
          onChange={(v) => set('ping', 'first_ping_delay_minutes', v)} />
        <Stepper label="Ungenauigkeit (m)" value={config.ping.precision_blur_m} min={0} max={1000} step={25}
          onChange={(v) => set('ping', 'precision_blur_m', v)} />
        <Toggle label="Hunter sehen, wann der nächste Ping kommt" value={config.ping.reveal_schedule_to_taskforce}
          onChange={(v) => set('ping', 'reveal_schedule_to_taskforce', v)} />
      </Box>

      <Box title="Blitzjagd" icon="⚡" summary={config.speedhunt.enabled ? `${config.speedhunt.quota_per_day[0] ?? 0} im Spiel · ${config.speedhunt.queries} Abfragen` : 'aus'} info={SETTING_HELP.speedhunt}>
        <Toggle label="Blitzjagden erlaubt" value={config.speedhunt.enabled} onChange={(v) => set('speedhunt', 'enabled', v)} />
        {config.speedhunt.enabled && (
          <>
            <Stepper label="Blitzjagden im ganzen Spiel" value={config.speedhunt.quota_per_day[0] ?? 0} min={0} max={20}
              onChange={(v) => set('speedhunt', 'quota_per_day', [v])} />
            <Stepper label="Standort-Abfragen pro Blitzjagd" value={config.speedhunt.queries} min={1} max={20}
              onChange={(v) => set('speedhunt', 'queries', v)} />
            <div className="muted small">Blitzjagden starten nur die Hunter. Eine Blitzjagd hat kein Zeitlimit: sie endet, wenn alle Abfragen gemacht sind oder das Ziel gefangen ist.</div>
          </>
        )}
      </Box>

      <Box title="Fangen und Gewinnen" icon="🏁" summary={`${config.catch.method.includes('qr') ? 'QR-Code' : 'Berühren'}${config.exit.enabled ? ' · mit Fluchtpunkt' : ''}`} info={SETTING_HELP.catch}>
        <div className="field">
          <span>Wie wird gefangen? <Hint label="Wie wird gefangen?" /></span>
          <div className="chips">
            {CATCH_METHODS.filter((m) => m === 'qr' || m === 'touch_confirm').map((m) => {
              const on = config.catch.method.includes(m);
              return (
                <button key={m} type="button" className={`chip${on ? ' on' : ''}`} aria-pressed={on}
                  onClick={() => {
                    const list = on ? config.catch.method.filter((x) => x !== m) : [...config.catch.method, m];
                    if (list.length) set('catch', 'method', list);
                  }}>
                  {m === 'qr' ? 'QR-Code scannen' : 'Berühren + bestätigen'}
                </button>
              );
            })}
          </div>
        </div>
        <Toggle label="Fluchtpunkt am Schluss (Spieler müssen hin)" value={config.exit.enabled} onChange={(v) => set('exit', 'enabled', v)} />
      </Box>

      <Box title="Joker" icon="🃏" summary={j.enabled && j.types.length ? `${j.types.length} Joker · erster nach ${formatMinutes(firstJoker)}` : 'aus'} info={SETTING_HELP.joker}>
        <Toggle label="Joker im Spiel" value={j.enabled} onChange={(v) => set('joker', 'enabled', v)} />
        {j.enabled && (
          <>
            <div className="muted small">Jeder Joker wird nach der eingestellten Spielzeit für alle Spieler freigeschaltet. Wirken tut er erst, wenn der Spieler ihn einsetzt.</div>
            {j.types.map((x, i) => (
              <div key={i} className="sub stack" style={{ gap: 4 }}>
                <div className="row" style={{ flexWrap: 'nowrap' }}>
                  <select aria-label={`Joker ${i + 1}`} value={x.type} style={{ flex: 1 }}
                    onChange={(e) => {
                      const type = e.target.value as JokerEntry['type'];
                      setJokers(j.types.map((y, k) => (k === i ? { type, after_minutes: y.after_minutes, ...(type === 'hunter_erfragen' ? {} : { minutes: y.minutes ?? 15 }) } : y)));
                    }}>
                    {JOKER_TYPES.map((t) => <option key={t} value={t}>{JOKER_LABELS[t]}</option>)}
                  </select>
                  <button type="button" className="ghost small" aria-label={`Joker ${i + 1} entfernen`} onClick={() => setJokers(j.types.filter((_, k) => k !== i))}>✕</button>
                </div>
                <Duration label="Freigeschaltet nach" value={x.after_minutes} min={0} max={latestJoker}
                  onChange={(v) => setJokers(j.types.map((y, k) => (k === i ? { ...y, after_minutes: v } : y)))} />
                {x.type !== 'hunter_erfragen' && (
                  <Duration label="Wirkt so lange" value={x.minutes ?? 15} min={1} max={Math.min(1440, g.duration_minutes)}
                    onChange={(v) => setJokers(j.types.map((y, k) => (k === i ? { ...y, minutes: v } : y)))} />
                )}
              </div>
            ))}
            <button type="button" className="small" onClick={addJoker}>+ Joker hinzufügen</button>
          </>
        )}
      </Box>

      <Box title="Extras" icon="✨" summary={[config.hideout.enabled && 'Verschanzen', config.proximity.enabled && 'Nähe-Alarm', config.spectator.enabled && 'Zuschauer'].filter(Boolean).join(' · ') || 'keine'} info={SETTING_HELP.extras}>
        <Toggle label="Verschanzen-Regel (nicht zu lange am selben Ort)" value={config.hideout.enabled} onChange={(v) => set('hideout', 'enabled', v)} />
        <Toggle label="Alarm, wenn Spieler zusammen laufen" value={config.proximity.enabled} onChange={(v) => set('proximity', 'enabled', v)} />
        <Toggle label="Zuschauer erlaubt" value={config.spectator.enabled} onChange={(v) => set('spectator', 'enabled', v)} />
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
        <button type="button" aria-label={`${label} weniger`} disabled={value <= min} onClick={() => onChange(clamp(value - step, min, max))}>−</button>
        <input type="number" inputMode="numeric" aria-label={label} value={value} min={min} max={max}
          onChange={(e) => { const n = Number(e.target.value); if (Number.isFinite(n)) onChange(clamp(Math.round(n), min, max)); }} />
        <button type="button" aria-label={`${label} mehr`} disabled={value >= max} onClick={() => onChange(clamp(value + step, min, max))}>+</button>
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
        <input type="number" inputMode="numeric" aria-label={`${label} Stunden`} min={0} value={h}
          onChange={(e) => put(Math.max(0, Math.round(Number(e.target.value) || 0)), m)} />
        <span>h</span>
        <input type="number" inputMode="numeric" aria-label={`${label} Minuten`} min={0} max={59} step={5} value={m}
          onChange={(e) => put(h, clamp(Math.round(Number(e.target.value) || 0), 0, 59))} />
        <span>min</span>
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
  const text = QUICK_HELP[label];
  return text ? <Info title={label} text={text} /> : null;
}
