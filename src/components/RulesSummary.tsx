import type { GameConfig } from '../shared/config';
import { formatMinutes } from '../shared/format';
import { t, lazy } from '../i18n';

const JOKER_NAMES: Record<string, string> = lazy({
  regeneration: 'Regeneration',
  hunter_erfragen: 'Hunter-Standorte',
  naehe_radar: 'Nähe-Radar',
});

/** Die Regeln in normalen Sätzen, für alle verständlich. */
export function rulesInWords(c: GameConfig): [string, string][] {
  const out: [string, string][] = [];
  out.push(['⏱️', t('Das Spiel dauert {0} am Stück, ohne Pause, und endet pünktlich. Davon sind die ersten {1} Vorsprung der Spieler. Direkt danach kommt der erste Ping.', { 0: formatMinutes(c.game.duration_minutes), 1: formatMinutes(c.start.head_start_minutes) })]);
  out.push(['📍', t('Alle {0} sehen die Hunter, wo die Spieler gerade sind. Die Spieler sehen diese Pings auch (ausser bei Blitzjagden). Bei jedem Ping und jeder Blitzjagd klingelt das Handy aller Spieler.', { 0: formatMinutes(c.ping.interval_minutes) })]);
  if (c.speedhunt.enabled) {
    out.push(['⚡', t('Blitzjagd: Die Hunter dürfen {0}-mal im Spiel eine Blitzjagd starten, mit {1} Standort-Abfragen auf einen Spieler, ohne Zeitlimit.', { 0: c.speedhunt.quota_per_day[0] ?? 0, 1: c.speedhunt.queries })]);
  }
  out.push(['🤚', t('Gefangen ist, wer erwischt wird: der Hunter gibt den Fang-Code des Spielers ein, oder er meldet den Fang und der Spieler bestätigt. Lehnt der Spieler ab, gilt der Fang nicht.')]);
  out.push(['🗺️', t('Wer das Spielfeld verlässt, bekommt einen Alarm und {0} Sekunden Zeit zurückzukommen, sonst sehen ihn die Hunter live. Ab dem 3. Verlassen sofort live. Nach {1} draussen {2}.', { 0: c.out_of_bounds.grace_seconds, 1: formatMinutes(c.out_of_bounds.max_minutes), 2: t('gilt man als gefangen') })]);
  out.push(['⚠️', t('Gefahrenzonen (Autobahn, Gleise, grosse Gewässer) nie betreten. Sonst gilt dasselbe: Alarm, {0} Sekunden Zeit, dann live; ab dem 3. Mal sofort live. Sonst passt jeder selbst auf sich auf.', { 0: c.out_of_bounds.grace_seconds })]);
  if (c.exit.enabled) out.push(['🏁', t('{0} vor Schluss erfahren nur die Spieler den Fluchtpunkt (zufällig gewählt). Ab dann dürfen Spieler zusammen sein. Offen ist er erst {1} vor Schluss: gerettet ist, wer zwischen der Freigabe und dem Spielende frei im Kreis ist.', { 0: formatMinutes(c.exit.reveal_minutes_before_end), 1: formatMinutes(c.exit.usable_minutes_before_end) })]);
  if (c.joker.enabled && c.joker.types.length) {
    const list = c.joker.types.map((j) => t('{0} nach {1}', { 0: JOKER_NAMES[j.type] ?? j.type, 1: formatMinutes(j.after_minutes) })).join(', ');
    out.push(['🃏', t('Joker für jeden Spieler: {0}. Freigeschaltete Joker wirken erst, wenn der Spieler sie einsetzt.', { 0: list })]);
  }
  const moves = [c.transport.motorized_allowed && t('ÖV, Taxi und Auto'), c.transport.bikes_allowed && t('Velo und Trottinett')].filter(Boolean);
  out.push(['🚌', moves.length ? t('Erlaubt sind zu Fuss sowie {0}.', { 0: moves.join(t(' und ')) }) : t('Nur zu Fuss: keine Fahrzeuge, kein ÖV.')]);
  if (c.proximity.enabled) out.push(['👥', t('Nähe-Alarm: Kommen sich zwei Spieler näher als {0} m, werden beide gewarnt und haben {1} Zeit, sich zu trennen. Sonst bekommen die Hunter ihren Ping.', { 0: c.proximity.distance_m, 1: formatMinutes(c.proximity.warn_minutes) })]);
  out.push(['🚨', t('Notfall (SOS): Das Spiel wird unterbrochen, und alle werden alarmiert und helfen. Danach geht es weiter, die Zeit wird angehängt.')]);
  if (c.hideout.enabled) out.push(['🏠', t('Verschanzen: höchstens {0} am selben Ort.', { 0: formatMinutes(c.hideout.max_minutes) })]);
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
