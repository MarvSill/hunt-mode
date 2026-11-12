import { useMemo, useState } from 'react';
import type { GameConfig } from '../shared/config';
import { configSections, optionLabel, type FieldMeta } from '../shared/schemaMeta';
import { timeLimits } from '../shared/timeRules';
import { t } from '../i18n';

/** Felder, die nicht mehr einstellbar sind (fest geregelt). */
const HIDDEN = new Set([
  'out_of_bounds.live_visible',
  // Das Spiel läuft am Stück: diese Werte setzt die App selbst.
  'game.days', 'game.day_length_minutes',
  // Joker-Liste hat eine eigene Eingabe in den Schnell-Einstellungen.
  'joker.types',
  // Ohne Strafen und ohne Live bei Fahrten: diese Werte setzt die App selbst.
  'speedhunt.vehicle_live_seconds', 'out_of_bounds.on_timeout', 'hideout.on_timeout', 'hideout.lockout_after_first_entry_minutes',
  'transport.checkin_required', 'transport.live_during',
  // Fest geregelt: sofort ein Ping nach dem Vorsprung, pünktliches Ende, nie zweimal dasselbe Ziel,
  // Anzahl sichtbarer Pings wählt jeder auf der Karte.
  'ping.first_ping_delay_minutes', 'exit.arrival_deadline_offset_minutes',
  'speedhunt.no_consecutive_same_target', 'catch.method', 'speedhunt.consecutive_allowed_when_players_left_le', 'ping.history_per_player',
  // Nähe-Alarm gilt immer ab Ende des Vorsprungs.
  'proximity.active_after_minutes',
]);

interface Props {
  config: GameConfig;
  /** Werte des gewählten Presets; Abweichungen werden markiert. */
  baseline?: GameConfig;
  readOnly?: boolean;
  /** Parameter mit Fehler oder Warnung. */
  problemPaths?: Set<string>;
  onChange?: (config: GameConfig) => void;
}

function getValue(config: GameConfig, f: FieldMeta): unknown {
  return (config[f.section] as Record<string, unknown>)[f.key];
}

export default function ConfigEditor({ config, baseline, readOnly, problemPaths, onChange }: Props) {
  const sections = useMemo(
    () => configSections().filter((s) => s.section !== 'extras').map((s) => ({ ...s, fields: s.fields.filter((f) => !HIDDEN.has(f.path)) })).filter((s) => s.fields.length > 0),
    [],
  );
  const limits = useMemo(() => timeLimits(config), [config]);
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase();

  function set(f: FieldMeta, value: unknown) {
    if (!onChange) return;
    const next = structuredClone(config) as Record<string, Record<string, unknown>>;
    next[f.section][f.key] = value;
    onChange(next as unknown as GameConfig);
  }

  return (
    <div>
      <input
        type="search"
        placeholder={t('Regel suchen, z. B. Ping, Blitzjagd, Joker')}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        style={{ marginBottom: 12 }}
      />
      {sections.map((s) => {
        const fields = s.fields.filter(
          (f) => !q || t(f.label).toLowerCase().includes(q) || f.label.toLowerCase().includes(q) || f.path.includes(q) || t(s.label).toLowerCase().includes(q),
        );
        if (fields.length === 0) return null;
        const changed = baseline
          ? fields.filter((f) => JSON.stringify(getValue(config, f)) !== JSON.stringify(getValue(baseline, f))).length
          : 0;
        const problems = fields.filter((f) => problemPaths?.has(f.path)).length;
        return (
          <details key={s.section} className="section" open={!!q}>
            <summary>
              <span className="spacer">{t(s.label)}</span>
              {problems > 0 && <span className="badge red">{problems} {t('prüfen')}</span>}
              {changed > 0 && <span className="badge yellow">{changed} {t('geändert')}</span>}
            </summary>
            <div>
              {fields.map((f) => (
                <Field
                  key={f.path}
                  field={limits[f.path] ? { ...f, max: Math.min(f.max ?? Infinity, limits[f.path].max), hint: limits[f.path].reason } : f}
                  value={getValue(config, f)}
                  changed={!!baseline && JSON.stringify(getValue(config, f)) !== JSON.stringify(getValue(baseline, f))}
                  problem={!!problemPaths?.has(f.path)}
                  readOnly={readOnly}
                  onChange={(v) => set(f, v)}
                />
              ))}
            </div>
          </details>
        );
      })}
    </div>
  );
}

interface FieldProps {
  field: FieldMeta & { hint?: string };
  value: unknown;
  changed: boolean;
  problem: boolean;
  readOnly?: boolean;
  onChange: (value: unknown) => void;
}

function Field({ field: f, value, changed, problem, readOnly, onChange }: FieldProps) {
  const cls = `param${changed ? ' changed' : ''}${problem ? ' problem' : ''}`;

  if (f.kind === 'boolean') {
    return (
      <div className={cls}>
        <label className="check">
          <input type="checkbox" checked={value as boolean} disabled={readOnly} onChange={(e) => onChange(e.target.checked)} />
          <span>{t(f.label)}</span>
        </label>
      </div>
    );
  }

  return (
    <div className={cls}>
      <label className="field">
        <span>
          {t(f.label)}
          {f.kind === 'number' && f.min !== undefined && (
            <span className="muted small">
              {' '}
              ({f.min} {t('bis')} {f.max})
            </span>
          )}
          {f.hint && <span className="muted small"> {t('· höchstens')} {f.max}{t(', weil')} {f.hint}</span>}
        </span>
        {f.kind === 'number' && <NumberInput field={f} value={value as number} readOnly={readOnly} onChange={onChange} />}
        {f.kind === 'text' && (
          <input value={value as string} disabled={readOnly} onChange={(e) => onChange(e.target.value)} />
        )}
        {f.kind === 'enum' && (
          <select value={value as string} disabled={readOnly} onChange={(e) => onChange(e.target.value)}>
            {f.options!.map((o) => (
              <option key={o} value={o}>
                {optionLabel(o)}
              </option>
            ))}
          </select>
        )}
        {f.kind === 'numberList' && (
          <ListInput value={value as number[]} readOnly={readOnly} onChange={onChange} />
        )}
        {f.kind === 'json' && <JsonInput value={value} readOnly={readOnly} onChange={onChange} />}
      </label>
      {f.kind === 'enumList' && (
        <div className="chips">
          {f.options!.map((o) => {
            const list = value as string[];
            const on = list.includes(o);
            return (
              <button
                key={o}
                type="button"
                className={`chip${on ? ' on' : ''}`}
                disabled={readOnly}
                aria-pressed={on}
                onClick={() => onChange(on ? list.filter((x) => x !== o) : [...list, o])}
              >
                {optionLabel(o)}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function NumberInput({ field, value, readOnly, onChange }: { field: FieldMeta; value: number; readOnly?: boolean; onChange: (v: unknown) => void }) {
  const [text, setText] = useState(String(value));
  const [lastValue, setLastValue] = useState(value);
  if (value !== lastValue) {
    setLastValue(value);
    setText(String(value));
  }
  return (
    <input
      type="text"
      inputMode="numeric"
      pattern="-?[0-9]*"
      min={field.min}
      max={field.max}
      value={text}
      disabled={readOnly}
      onChange={(e) => {
        setText(e.target.value);
        const n = Number(e.target.value);
        if (e.target.value !== '' && Number.isInteger(n) && n >= (field.min ?? -Infinity) && n <= (field.max ?? Infinity)) {
          onChange(n);
        }
      }}
      onBlur={() => setText(String(value))}
    />
  );
}

function ListInput({ value, readOnly, onChange }: { value: number[]; readOnly?: boolean; onChange: (v: unknown) => void }) {
  const [text, setText] = useState(value.join(', '));
  return (
    <input
      value={text}
      disabled={readOnly}
      placeholder={t('z. B. 3, 2, 2')}
      onChange={(e) => {
        setText(e.target.value);
        const parts = e.target.value.split(',').map((x) => x.trim()).filter(Boolean).map(Number);
        if (parts.length > 0 && parts.every((n) => Number.isInteger(n) && n >= 0 && n <= 20)) onChange(parts);
      }}
      onBlur={() => setText(value.join(', '))}
    />
  );
}

function JsonInput({ value, readOnly, onChange }: { value: unknown; readOnly?: boolean; onChange: (v: unknown) => void }) {
  const [text, setText] = useState(JSON.stringify(value));
  const [bad, setBad] = useState(false);
  return (
    <textarea
      rows={2}
      value={text}
      disabled={readOnly}
      style={bad ? { borderColor: 'var(--red)' } : undefined}
      onChange={(e) => {
        setText(e.target.value);
        try {
          onChange(JSON.parse(e.target.value));
          setBad(false);
        } catch {
          setBad(true);
        }
      }}
    />
  );
}
