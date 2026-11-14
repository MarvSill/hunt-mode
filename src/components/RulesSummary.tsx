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
  out.push(['⏱️', t('Das Spiel dauert {0} am Stück und endet pünktlich (eine Pause des Hosts wird angehängt). Davon sind die ersten {1} Vorsprung der Spieler. Direkt danach kommt der erste Ping.', { 0: formatMinutes(c.game.duration_minutes), 1: formatMinutes(c.start.head_start_minutes) })]);
  out.push(['📍', t('Alle {0} sehen die Hunter, wo die Spieler gerade sind. Die Spieler sehen diese Pings auch (ausser bei Blitzjagden). Bei jedem Ping und jeder Blitzjagd klingelt das Handy aller Spieler.', { 0: formatMinutes(c.ping.interval_minutes) })]);
  if (c.speedhunt.enabled) {
    out.push(['⚡', t('Blitzjagd: Die Hunter dürfen {0}-mal im Spiel eine Blitzjagd starten, mit {1} Standort-Abfragen auf einen Spieler, ohne Zeitlimit.', { 0: c.speedhunt.quota_per_day[0] ?? 0, 1: c.speedhunt.queries })]);
  }
  out.push(['🤚', t('Gefangen ist, wer erwischt wird: der Hunter meldet den Fang in der App, und der Spieler bestätigt. Lehnt der Spieler ab, gilt der Fang nicht.')]);
  out.push(['🗺️', t('Wer das Spielfeld verlässt, wird sofort live für die Hunter, und das Handy schlägt Alarm, bis er zurück ist. Nach {0} draussen {1}.', { 0: formatMinutes(c.out_of_bounds.max_minutes), 1: t('gilt man als gefangen') })]);
  out.push(['⚠️', t('Gefahrenzonen (Autobahn, Gleise, grosse Gewässer) nie betreten. Sonst: Alarm, {0} Sekunden Zeit, dann live; ab dem 3. Mal sofort live. Sonst passt jeder selbst auf sich auf.', { 0: c.out_of_bounds.grace_seconds })]);
  if (c.exit.enabled) out.push(['🏁', t('{0} vor Ende der Spielzeit erfahren nur die Spieler den Fluchtpunkt (zufällig gewählt). Er öffnet, wenn die Spielzeit abgelaufen ist. Gerettet ist, wer frei in den Kreis kommt. Das Spiel endet, wenn alle gefangen oder angekommen sind, spätestens {1} nach der Spielzeit.', { 0: formatMinutes(c.exit.reveal_minutes_before_end), 1: formatMinutes(c.exit.arrival_deadline_offset_minutes) })]);
  else out.push(['⏱', t('Ohne Fluchtpunkt endet das Spiel mit der Spielzeit. Ist dann noch ein Spieler frei, gewinnen die Spieler, sonst die Hunter.')]);
  if (c.joker.enabled && c.joker.types.length) {
    const list = c.joker.types.map((j) => t('{0} nach {1}', { 0: JOKER_NAMES[j.type] ?? j.type, 1: formatMinutes(j.after_minutes) })).join(', ');
    out.push(['🃏', t('Joker für jeden Spieler: {0}. Freigeschaltete Joker wirken erst, wenn der Spieler sie einsetzt.', { 0: list })]);
  }
  const moves = [c.transport.motorized_allowed && t('ÖV, Taxi und Auto'), c.transport.bikes_allowed && t('Velo und Trottinett')].filter(Boolean);
  out.push(['🚌', moves.length ? t('Erlaubt sind zu Fuss sowie {0}.', { 0: moves.join(t(' und ')) }) : t('Nur zu Fuss: keine Fahrzeuge, kein ÖV.')]);
  out.push(['🚨', t('Notfall (SOS): Das Spiel wird unterbrochen, und alle werden alarmiert und helfen. Danach geht es weiter, die Zeit wird angehängt.')]);
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
