import { t } from '../i18n';
/**
 * Rollenverteilung in der Lobby (Kapitel 21.5, Schritt 5).
 */
export type AssignableRole = 'spieler' | 'hunter' | 'zuschauer';

export interface RoleLimits {
  players_max: number;
  hunters_max: number;
}

/**
 * Verteilt Personen zufällig auf Hunter und Spieler. Das Verhältnis folgt
 * players_max zu hunters_max; wer über beide Maxima hinausgeht, wird Zuschauer.
 * `random` ist austauschbar, damit Tests reproduzierbar sind.
 */
export function distributeRoles(
  ids: string[],
  limits: RoleLimits,
  random: () => number = Math.random,
): Record<string, AssignableRole> {
  const shuffled = [...ids];
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  const n = Math.min(shuffled.length, limits.players_max + limits.hunters_max);
  const share = limits.hunters_max / (limits.players_max + limits.hunters_max);
  let hunters = Math.round(n * share);
  hunters = Math.max(n >= 2 ? 1 : 0, Math.min(hunters, limits.hunters_max, n - (n >= 2 ? 1 : 0)));
  hunters = Math.max(hunters, n - limits.players_max);

  const out: Record<string, AssignableRole> = {};
  shuffled.forEach((id, i) => {
    out[id] = i < hunters ? 'hunter' : i < n ? 'spieler' : 'zuschauer';
  });
  return out;
}

export interface RosterCounts {
  players: number;
  hunters: number;
  unassigned: number;
}

export interface LobbyIssue {
  level: 'error' | 'warning';
  code: string;
  message: string;
}

/** Prüfungen der Lobby, die nicht im Regelwerk stehen (Rollen und Bereitschaft). */
export function lobbyIssues(counts: RosterCounts, limits: RoleLimits, notReady: number): LobbyIssue[] {
  const issues: LobbyIssue[] = [];
  if (counts.unassigned > 0) {
    issues.push({ level: 'error', code: 'unassigned', message: t('{0} Person(en) haben noch keine Rolle.', { 0: counts.unassigned }) });
  }
  if (counts.players > limits.players_max) {
    issues.push({ level: 'error', code: 'too_many_players', message: t('Zu viele Spieler: {0} von max. {1}.', { 0: counts.players, 1: limits.players_max }) });
  }
  if (counts.hunters > limits.hunters_max) {
    issues.push({ level: 'error', code: 'too_many_hunters', message: t('Zu viele Hunter: {0} von max. {1}.', { 0: counts.hunters, 1: limits.hunters_max }) });
  }
  if (notReady > 0) {
    issues.push({ level: 'warning', code: 'not_ready', message: t('{0} Person(en) sind noch nicht bereit.', { 0: notReady }) });
  }
  return issues;
}
