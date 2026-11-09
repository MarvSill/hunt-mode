import type { GameConfig } from '../shared/config';
import { formatMinutes } from '../shared/format';

const JOKER_NAMES: Record<string, string> = {
  regeneration: 'Regeneration',
  hunter_erfragen: 'Hunter-Standorte',
};

/** Die Regeln in normalen Sätzen, für alle verständlich. */
export function rulesInWords(c: GameConfig): [string, string][] {
  const out: [string, string][] = [];
  out.push(['⏱️', `Das Spiel dauert ${formatMinutes(c.game.duration_minutes)} am Stück, ohne Pause. Die Spieler haben ${formatMinutes(c.start.head_start_minutes)} Vorsprung.`]);
  out.push(['📍', `Alle ${formatMinutes(c.ping.interval_minutes)} sehen die Hunter, wo die Spieler gerade sind. Bei jedem Ping und jeder Blitzjagd klingelt das Handy aller Spieler.`]);
  if (c.speedhunt.enabled) {
    out.push(['⚡', `Blitzjagd: Die Hunter dürfen ${c.speedhunt.quota_per_day[0] ?? 0}-mal im Spiel eine Blitzjagd starten, mit ${c.speedhunt.queries} Standort-Abfragen auf einen Spieler, ohne Zeitlimit.`]);
  }
  const how = c.catch.method.includes('qr') ? 'den Fang-Code des Spielers scannt' : 'den Spieler berührt und beide bestätigen';
  out.push(['🤚', `Gefangen ist, wer erwischt wird: der Hunter ${how}.`]);
  out.push(['🗺️', `Wer das Spielfeld verlässt, bekommt einen Alarm und ${c.out_of_bounds.grace_seconds} Sekunden Zeit zurückzukommen, sonst sehen ihn die Hunter live. Ab dem 3. Verlassen sofort live. Nach ${formatMinutes(c.out_of_bounds.max_minutes)} draussen ${c.out_of_bounds.on_timeout === 'disqualify' ? 'ist man raus' : c.out_of_bounds.on_timeout === 'catch' ? 'gilt man als gefangen' : 'gibt es eine Strafe'}.`]);
  out.push(['⚠️', `Gefahrenzonen (z. B. Gleise, Strassen) nie betreten. Sonst gilt dasselbe: Alarm, ${c.out_of_bounds.grace_seconds} Sekunden Zeit, dann live; ab dem 3. Mal sofort live.`]);
  if (c.exit.enabled) out.push(['🏁', `${formatMinutes(c.exit.reveal_minutes_before_end)} vor Schluss erfahren nur die Spieler den Fluchtpunkt (zufällig gewählt). Wer frei dort ankommt, gewinnt. Ab dann dürfen Spieler zusammen sein.`]);
  if (c.joker.enabled && c.joker.types.length) {
    const list = c.joker.types.map((t) => `${JOKER_NAMES[t.type] ?? t.type} nach ${formatMinutes(t.after_minutes)}`).join(', ');
    out.push(['🃏', `Joker für jeden Spieler: ${list}. Freigeschaltete Joker wirken erst, wenn der Spieler sie einsetzt.`]);
  }
  const moves = [c.transport.motorized_allowed && 'ÖV, Taxi und Auto', c.transport.bikes_allowed && 'Velo und Trottinett'].filter(Boolean);
  out.push(['🚌', moves.length ? `Erlaubt sind zu Fuss sowie ${moves.join(' und ')}.` : 'Nur zu Fuss: keine Fahrzeuge, kein ÖV.']);
  if (c.proximity.enabled) out.push(['👥', `Nähe-Alarm: Kommen sich zwei Spieler näher als ${c.proximity.distance_m} m, werden beide gewarnt und haben ${formatMinutes(c.proximity.warn_minutes)} Zeit, sich zu trennen. Sonst bekommen die Hunter ihren Ping.`]);
  out.push(['🚨', 'Notfall (SOS): Das Spiel wird unterbrochen, und alle werden alarmiert und helfen. Danach geht es weiter, die Zeit wird angehängt.']);
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
