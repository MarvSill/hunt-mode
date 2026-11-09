/**
 * Zeitlogik: keine Zeitangabe darf einer anderen widersprechen.
 * Alles, was während der Jagd passiert (Verkleinerung, Pings, Blitzjagden,
 * Joker, Meldungen …), muss in die Spieldauer passen. Das Spiel läuft am Stück.
 *
 * `timeLimits` liefert die erlaubten Höchstwerte (für Eingabefelder),
 * `fitTimes` passt eine Konfiguration daran an und sagt, was geändert wurde.
 */
import type { GameConfig } from './config';

const JOKER_NAMES: Record<string, string> = { regeneration: 'Regeneration', hunter_erfragen: 'Hunter-Standorte', catch_free: 'Schutzschild' };

export interface TimeFix {
  path: string;
  from: number;
  to: number;
  message: string;
}

export interface TimeLimit {
  max: number;
  min?: number;
  reason: string;
}

/** Spieldauer als Text, z. B. "90 min" oder "3 h" oder "2 Tage". */
export function durationText(min: number): string {
  if (min < 120) return `${min} min`;
  if (min < 2880) return min % 60 === 0 ? `${min / 60} h` : `${Math.floor(min / 60)} h ${min % 60} min`;
  return min % 1440 === 0 ? `${min / 1440} Tage` : `${Math.round(min / 60)} h`;
}

/** Dauer einer Verkleinerungs-Phase (0 = es wird nie kleiner). */
export function phaseLength(c: GameConfig): number {
  if (c.zone.shrink_mode === 'aus') return 0;
  return c.zone.shrink_every_minutes;
}

const LABELS: Record<string, string> = {
  'zone.shrink_every_minutes': 'Verkleinerung alle',
  'zone.shrink_announce_minutes': 'Ankündigung der Verkleinerung',
  'zone.shrink_grace_minutes': 'Zeit zum Rauslaufen',
  'ping.interval_minutes': 'Ping-Intervall',
  'ping.first_ping_delay_minutes': 'Erster Ping nach',
  'ping.offset_minutes': 'Ping-Versatz',
  'ping.jitter_minutes': 'Ping-Zufallsversatz',
  'speedhunt.max_duration_minutes': 'Dauer einer Blitzjagd',
  'speedhunt.query_min_gap_minutes': 'Abstand der Abfragen einer Blitzjagd',
  'speedhunt.min_minutes_after_silent_ping': 'Abstand der Blitzjagd zum Ping',
  'out_of_bounds.max_minutes': 'Limit ausserhalb',
  'hideout.max_minutes': 'Verschanzen-Limit',
  'hideout.stationary_minutes': 'Verschanzen-Erkennung',
  'hideout.lockout_after_first_entry_minutes': 'Ort gesperrt nach',
  'transport.live_after_base_minutes': 'Live-Nachlauf nach Fahrt',
  'proximity.active_after_minutes': 'Teambildungs-Alarm aktiv ab',
  'exit.reveal_minutes_before_end': 'Bekanntgabe des Fluchtpunkts vor Ende',
  'spectator.delay_minutes': 'Zuschauer-Verzögerung',
};

function get(c: GameConfig, path: string): number {
  const [s, k] = path.split('.');
  return (c as unknown as Record<string, Record<string, number>>)[s][k];
}

function set(c: GameConfig, path: string, v: number) {
  const [s, k] = path.split('.');
  (c as unknown as Record<string, Record<string, number>>)[s][k] = v;
}

/** Höchstwerte, die sich aus den anderen Zeiten ergeben. */
export function timeLimits(c: GameConfig): Record<string, TimeLimit> {
  const d = c.game.duration_minutes;
  const game = `das Spiel nur ${durationText(d)} dauert`;
  const out: Record<string, TimeLimit> = {
    'ping.interval_minutes': { max: Math.max(1, d - 1 - Math.min(c.ping.first_ping_delay_minutes, d - 2)), reason: `sonst kein Ping kommt und ${game}` },
    'ping.first_ping_delay_minutes': { max: Math.max(0, d - 2), reason: game },
    'ping.offset_minutes': { max: Math.max(0, c.ping.interval_minutes - 1), reason: `der Ping alle ${c.ping.interval_minutes} min kommt` },
    'ping.jitter_minutes': { max: Math.floor(c.ping.interval_minutes / 2), reason: `der Ping alle ${c.ping.interval_minutes} min kommt` },
    'out_of_bounds.max_minutes': { max: d, reason: game },
    'hideout.max_minutes': { max: Math.max(5, d), reason: game },
    'hideout.stationary_minutes': { max: Math.max(5, c.hideout.max_minutes), reason: `das Verschanzen-Limit nur ${c.hideout.max_minutes} min ist` },
    'hideout.lockout_after_first_entry_minutes': { max: d, reason: game },
    'transport.live_after_base_minutes': { max: d, reason: game },
    'proximity.active_after_minutes': { max: Math.max(0, d - 5), reason: `der Alarm sonst nie aktiv wäre` },
    'exit.reveal_minutes_before_end': { max: d, reason: game },
    'spectator.delay_minutes': { max: Math.max(0, d - 5), reason: `Zuschauer sonst nichts sähen` },
  };
  // Nur Regeln prüfen, die im Spiel auch aktiv sind.
  const off: [boolean, string][] = [
    [c.hideout.enabled, 'hideout.'],
    [c.proximity.enabled, 'proximity.'], [c.exit.enabled, 'exit.'], [c.spectator.enabled, 'spectator.'],
  ];
  for (const [on, prefix] of off) if (!on) for (const k of Object.keys(out)) if (k.startsWith(prefix)) delete out[k];
  if (c.speedhunt.enabled) {
    const sd = Math.max(5, d);
    out['speedhunt.max_duration_minutes'] = { max: sd, reason: game };
    const gaps = Math.max(1, c.speedhunt.queries - 1);
    out['speedhunt.query_min_gap_minutes'] = {
      max: Math.floor(Math.min(c.speedhunt.max_duration_minutes, sd) / gaps),
      reason: `${c.speedhunt.queries} Abfragen in ${Math.min(c.speedhunt.max_duration_minutes, sd)} min passen müssen`,
    };
    out['speedhunt.min_minutes_after_silent_ping'] = { max: Math.max(0, c.ping.interval_minutes - 1), reason: `der Ping alle ${c.ping.interval_minutes} min kommt` };
  }
  if (c.zone.shrink_mode !== 'aus') {
    if (c.zone.shrink_every_minutes > 0) {
      out['zone.shrink_every_minutes'] = { min: 5, max: Math.max(5, Math.floor(d / 2)), reason: `das Spielfeld in ${durationText(d)} mindestens einmal kleiner werden soll` };
    }
    const ph = phaseLength(c) || d;
    out['zone.shrink_announce_minutes'] = { max: ph, reason: `eine Phase nur ${durationText(ph)} dauert` };
    out['zone.shrink_grace_minutes'] = { max: Math.min(120, ph), reason: `eine Phase nur ${durationText(ph)} dauert` };
  }
  return out;
}

/** Passt alle Zeiten an, damit nichts ausserhalb der Spieldauer liegt. */
export function fitTimes(input: GameConfig): { config: GameConfig; fixes: TimeFix[] } {
  const c = structuredClone(input);
  const fixes: TimeFix[] = [];
  const d = c.game.duration_minutes;

  // Verkleinerung braucht einen Abstand: ohne Angabe viermal im Spiel.
  if (c.zone.shrink_mode !== 'aus' && c.zone.shrink_every_minutes === 0) {
    const every = Math.max(5, Math.round(d / 4 / 5) * 5);
    c.zone.shrink_every_minutes = every;
    fixes.push({
      path: 'zone.shrink_every_minutes', from: 0, to: every,
      message: `Das Spielfeld wird alle ${every} min kleiner, damit es in ${durationText(d)} passt.`,
    });
  }

  // Mehrere Runden, weil Grenzen voneinander abhängen.
  for (let round = 0; round < 3; round++) {
    const limits = timeLimits(c);
    let changed = false;
    for (const [path, lim] of Object.entries(limits)) {
      const v = get(c, path);
      let to = v;
      if (v > lim.max) to = lim.max;
      if (lim.min !== undefined && v < lim.min && v !== 0) to = lim.min;
      if (to === v) continue;
      set(c, path, to);
      changed = true;
      const prev = fixes.find((f) => f.path === path);
      const message = `${LABELS[path] ?? path}: ${to} statt ${prev?.from ?? v} min, weil ${lim.reason}.`;
      if (prev) Object.assign(prev, { to, message });
      else fixes.push({ path, from: v, to, message });
    }
    if (!changed) break;
  }

  // Joker-Dauern und Freischaltzeiten
  const latest = Math.max(0, d - 5);
  for (const j of c.joker.enabled ? c.joker.types : []) {
    const name = JOKER_NAMES[j.type] ?? j.type;
    if (j.minutes !== undefined && j.minutes > d) {
      fixes.push({ path: 'joker.types', from: j.minutes, to: d, message: `Joker "${name}": wirkt ${d} statt ${j.minutes} min, weil das Spiel nur ${durationText(d)} dauert.` });
      j.minutes = d;
    }
    if (j.after_minutes > latest) {
      fixes.push({ path: 'joker.types', from: j.after_minutes, to: latest, message: `Joker "${name}": kommt nach ${latest} statt ${j.after_minutes} min, weil das Spiel nur ${durationText(d)} dauert.` });
      j.after_minutes = latest;
    }
  }
  return { config: c, fixes };
}
