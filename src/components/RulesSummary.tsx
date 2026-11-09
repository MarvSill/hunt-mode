import type { GameConfig } from '../shared/config';
import { formatMinutes } from '../shared/format';

const JOKER_NAMES: Record<string, string> = {
  regeneration: 'Regeneration',
  hunter_erfragen: 'Hunter-Standorte',
  catch_free: 'Schutzschild',
};

/** Die Regeln in normalen Sätzen, für alle verständlich. */
export function rulesInWords(c: GameConfig): [string, string][] {
  const out: [string, string][] = [];
  out.push(['⏱️', `Das Spiel dauert ${formatMinutes(c.game.duration_minutes)} am Stück, ohne Pause. Die Spieler haben ${formatMinutes(c.start.head_start_minutes)} Vorsprung.`]);
  out.push(['📍', `Alle ${formatMinutes(c.ping.interval_minutes)} sehen die Hunter, wo die Spieler gerade sind.`]);
  if (c.speedhunt.enabled) {
    out.push(['⚡', `Blitzjagd: ${c.speedhunt.quota_per_day[0] ?? 0} im ganzen Spiel, dabei ${c.speedhunt.queries} Standort-Abfragen auf einen Spieler, höchstens ${formatMinutes(c.speedhunt.max_duration_minutes)}.`]);
  }
  const how = c.catch.method.includes('qr') ? 'den Fang-Code des Spielers scannt' : 'den Spieler berührt und beide bestätigen';
  out.push(['🤚', `Gefangen ist, wer erwischt wird: der Hunter ${how}.`]);
  out.push(['🗺️', `Wer das Spielfeld verlässt, wird live an die Hunter gezeigt. Nach ${formatMinutes(c.out_of_bounds.max_minutes)} draussen ${c.out_of_bounds.on_timeout === 'disqualify' ? 'ist man raus' : c.out_of_bounds.on_timeout === 'catch' ? 'gilt man als gefangen' : 'gibt es eine Strafe'}.`]);
  if (c.exit.enabled) out.push(['🏁', `${formatMinutes(c.exit.reveal_minutes_before_end)} vor Schluss wird der Fluchtpunkt verraten. Wer frei dort ankommt, gewinnt.`]);
  if (c.joker.enabled && c.joker.types.length) {
    const list = c.joker.types.map((t) => `${JOKER_NAMES[t.type] ?? t.type} nach ${formatMinutes(t.after_minutes)}`).join(', ');
    out.push(['🃏', `Joker für jeden Spieler: ${list}.`]);
  }
  if (c.hideout.enabled) out.push(['🏠', `Verschanzen: höchstens ${formatMinutes(c.hideout.max_minutes)} am selben Ort.`]);
  return out;
}

export default function RulesSummary({ config }: { config: GameConfig }) {
  return (
    <ul className="list">
      {rulesInWords(config).map(([icon, text]) => (
        <li key={text} style={{ alignItems: 'flex-start' }}>
          <span style={{ fontSize: 20, width: 26, textAlign: 'center' }} aria-hidden="true">{icon}</span>
          <span className="small">{text}</span>
        </li>
      ))}
      {config.extras.rules.map((r, i) => (
        <li key={`x${i}`} style={{ alignItems: 'flex-start' }}>
          <span style={{ fontSize: 20, width: 26, textAlign: 'center' }} aria-hidden="true">📌</span>
          <span className="small">{r}</span>
        </li>
      ))}
    </ul>
  );
}
