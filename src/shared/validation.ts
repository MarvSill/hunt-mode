/**
 * Konfigurations-Validierung.
 * Fehler blockieren den Start, Warnungen nicht. Manche Fehler werden
 * automatisch korrigiert (autoFixes) und dem Host als Hinweis gezeigt.
 */
import type { GameConfig } from './config';
import { fitTimes } from './timeRules';

export type IssueLevel = 'error' | 'warning' | 'autofix';

export interface ConfigIssue {
  level: IssueLevel;
  code: string;
  message: string;
  /** Betroffene Parameter, z. B. "ping.interval_minutes". */
  paths: string[];
}

/** Angaben, die nicht in der Konfiguration stehen (Teilnehmende, Karte). */
export interface ValidationContext {
  players?: number;
  hunters?: number;
  /** Mindestens eine teilnehmende Person ist unter 18. */
  hasMinors?: boolean;
  /** Breite des Spielfelds in Metern (Karte, ab Schritt 2). */
  fieldWidthM?: number;
}

export interface ValidationResult {
  /** Konfiguration nach automatischen Korrekturen. */
  config: GameConfig;
  issues: ConfigIssue[];
  /** true, wenn kein Fehler den Start blockiert. */
  canStart: boolean;
}

export function validateConfig(input: GameConfig, ctx: ValidationContext = {}): ValidationResult {
  // Zeiten zuerst stimmig machen: nichts darf ausserhalb der Spieldauer liegen.
  const fit = fitTimes(input);
  const config = fit.config;
  const issues: ConfigIssue[] = [];
  const add = (level: IssueLevel, code: string, message: string, ...paths: string[]) =>
    issues.push({ level, code, message, paths });
  fit.fixes.forEach((f, n) => add('autofix', `time:${f.path}:${n}`, f.message, f.path));

  const duration = config.game.duration_minutes;

  if (ctx.players !== undefined && ctx.hunters !== undefined && (ctx.players < 1 || ctx.hunters < 1)) {
    add('error', 'min_participants', 'Es braucht mindestens einen Spieler und einen Hunter.');
  }

  if (config.ping.interval_minutes >= duration) {
    add('error', 'no_ping', 'Bei diesem Intervall gibt es keinen einzigen Ping.', 'ping.interval_minutes', 'game.duration_minutes');
  } else if (config.ping.interval_minutes * 3 > duration) {
    add('warning', 'few_pings', 'Es gibt weniger als drei Pings im ganzen Spiel.', 'ping.interval_minutes', 'game.duration_minutes');
  }

  if (config.joker.enabled && config.joker.types.some((j) => (j.minutes ?? 0) >= duration)) {
    add('warning', 'joker_whole_game', 'Ein Joker wirkt das ganze Spiel.', 'joker.types');
  }
  if (config.joker.enabled && config.joker.types.length === 0) {
    add('warning', 'joker_empty', 'Joker sind aktiv, aber es ist kein Joker eingestellt.', 'joker.types');
  }

  if (config.hideout.enabled && config.hideout.max_minutes >= duration) {
    add('warning', 'hideout_unlimited', 'Verschanzen ist praktisch unbegrenzt.', 'hideout.max_minutes');
  }

  if (config.out_of_bounds.max_minutes >= duration) {
    add('warning', 'out_of_bounds_unlimited', 'Ausserhalb-Limit ist länger als das Spiel.', 'out_of_bounds.max_minutes');
  }

  if (config.exit.enabled && config.exit.reveal_minutes_before_end > duration) {
    add(
      'error',
      'exit_reveal_before_start',
      'Der Fluchtpunkt würde vor Spielbeginn bekanntgegeben.',
      'exit.reveal_minutes_before_end',
    );
  }

  if (config.time.align_to_full_hour && duration < 120) {
    add('warning', 'align_short_game', 'Bei kurzen Spielen besser ab Spielstart zählen.', 'time.align_to_full_hour');
  }

  if (config.speedhunt.enabled) {
    const players = Math.max(ctx.players ?? config.roles.players_max, 1);
    const hours = Math.max(1, duration / 60);
    if ((config.speedhunt.quota_per_day[0] ?? 0) > players * Math.ceil(hours / 3)) {
      add(
        'warning',
        'hunter_advantage',
        'Die Hunter sind stark im Vorteil (sehr viele Blitzjagden pro Spieler).',
        'speedhunt.quota_per_day',
      );
    }
  }

  if (ctx.hasMinors && config.catch.method.includes('handcuffs')) {
    add('error', 'handcuffs_minors', 'Fangmethode Handschellen ist mit Teilnehmenden unter 18 nicht erlaubt.', 'catch.method');
  }


  if (config.proximity.enabled && ctx.fieldWidthM !== undefined && config.proximity.distance_m > ctx.fieldWidthM / 2) {
    add('warning', 'proximity_always', 'Alarm wird fast dauernd ausgelöst.', 'proximity.distance_m');
  }

  if (config.win.mode === 'letzter_ueberlebender' && config.exit.enabled) {
    add('warning', 'exit_ignored', 'Der Fluchtpunkt wird ignoriert.', 'win.mode', 'exit.enabled');
  }

  return { config, issues, canStart: !issues.some((i) => i.level === 'error') };
}
