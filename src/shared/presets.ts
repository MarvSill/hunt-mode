/**
 * Vorlagen. Jede Vorlage setzt alle Parameter auf einmal; danach kann der
 * Host jeden Wert ändern. Basis ist immer die Standardkonfiguration, die
 * Vorlage überschreibt nur, was abweicht. Alle Spiele laufen am Stück.
 */
import { defaultConfig, mergeConfig, type DeepPartial, type GameConfig } from './config';

export interface Preset {
  id: string;
  name: string;
  description: string;
  /** Vorgeschlagene Anzahl Spieler / Hunter. */
  suggested: { players: number; hunters: number };
  patch: DeepPartial<GameConfig>;
}

export const PRESETS: Preset[] = [
  {
    id: 'wochenende_24h',
    name: 'Wochenende 24 h',
    description: '24 h am Stück, Budget 30 CHF, Joker, Spielfeld wird alle 6 h kleiner.',
    suggested: { players: 6, hunters: 3 },
    patch: {
      game: { duration_minutes: 1440 },
      roles: { players_max: 6, hunters_max: 3 },
      start: { head_start_minutes: 30 },
      time: { align_to_full_hour: false },
      zone: { shrink_mode: 'auto', auto_shrink_percent: 20, shrink_every_minutes: 360, shrink_announce_minutes: 60 },
      ping: { interval_minutes: 45, zone_overrides: { kern: 30 } },
      speedhunt: {
        quota_per_day: [5],
        queries: 4,
        max_duration_minutes: 45,
        no_consecutive_same_target: true,
        max_parallel: 2,
        vehicle_live_seconds: 60,
        catch_removes_one: true,
      },
      out_of_bounds: { max_minutes: 30, on_timeout: 'catch' },
      hideout: {
        max_minutes: 30,
        min_leave_distance_m: 150,
        lockout_after_first_entry_minutes: 120,
        stationary_minutes: 10,
      },
      transport: { live_after_base_minutes: 5, live_after_increment_minutes: 2 },
      budget: { enabled: true, currency: 'CHF', start_amount: 30 },
      joker: {
        enabled: true,
        types: [
          { type: 'regeneration', minutes: 60, after_minutes: 120 },
          { type: 'catch_free', minutes: 45, after_minutes: 480 },
          { type: 'regeneration', minutes: 60, after_minutes: 840 },
          { type: 'catch_free', minutes: 45, after_minutes: 1200 },
        ],
      },
      proximity: { enabled: true, distance_m: 200, active_after_minutes: 30 },
      taskforce: { bounty_per_catch: 0 },
      exit: { enabled: true, reveal_minutes_before_end: 60 },
      win: { prize: 'Punkte' },
    },
  },
  {
    id: 'stadtabend_3h',
    name: 'Stadtabend 3 h',
    description: '3 h am Stück, ein Spielfeld, Pings alle 15 min, Joker nach 30, 75 und 120 min.',
    suggested: { players: 4, hunters: 2 },
    patch: {
      game: { duration_minutes: 180 },
      roles: { players_max: 4, hunters_max: 2 },
      start: { head_start_minutes: 10 },
      time: { align_to_full_hour: false },
      zone: { shrink_mode: 'auto', auto_shrink_percent: 15, shrink_every_minutes: 45, shrink_announce_minutes: 15 },
      ping: { interval_minutes: 15, zone_overrides: {} },
      speedhunt: {
        quota_per_day: [4],
        queries: 3,
        max_duration_minutes: 15,
        no_consecutive_same_target: true,
        max_parallel: 2,
        vehicle_live_seconds: 60,
        catch_removes_one: false,
      },
      out_of_bounds: { max_minutes: 5, on_timeout: 'catch' },
      hideout: {
        max_minutes: 8,
        min_leave_distance_m: 100,
        lockout_after_first_entry_minutes: 30,
        stationary_minutes: 5,
      },
      transport: { live_after_base_minutes: 2, live_after_increment_minutes: 1 },
      budget: { enabled: false },
      joker: {
        enabled: true,
        types: [
          { type: 'regeneration', minutes: 15, after_minutes: 30 },
          { type: 'catch_free', minutes: 10, after_minutes: 75 },
          { type: 'regeneration', minutes: 15, after_minutes: 120 },
        ],
      },
      proximity: { enabled: true, distance_m: 150, active_after_minutes: 10 },
      taskforce: { bounty_per_catch: 0 },
      exit: { enabled: true, reveal_minutes_before_end: 20 },
      win: { prize: 'Punkte' },
    },
  },
  {
    id: 'schnell_90min',
    name: 'Schnell 90 min',
    description: '90 min am Stück, nur zu Fuss, Pings alle 10 min.',
    suggested: { players: 3, hunters: 1 },
    patch: {
      game: { duration_minutes: 90 },
      roles: { players_max: 3, hunters_max: 1 },
      start: { head_start_minutes: 5 },
      time: { align_to_full_hour: false },
      zone: { shrink_mode: 'aus' },
      ping: { interval_minutes: 10, zone_overrides: {} },
      speedhunt: {
        quota_per_day: [3],
        queries: 3,
        max_duration_minutes: 8,
        no_consecutive_same_target: false,
        max_parallel: 1,
        vehicle_live_seconds: 0,
        catch_removes_one: false,
      },
      out_of_bounds: { max_minutes: 3, on_timeout: 'catch' },
      hideout: {
        max_minutes: 5,
        min_leave_distance_m: 75,
        lockout_after_first_entry_minutes: 0,
        stationary_minutes: 5,
      },
      transport: { allowed_modes: ['zu_fuss'], checkin_required: false, live_during: false },
      budget: { enabled: false },
      joker: {
        enabled: true,
        types: [
          { type: 'regeneration', minutes: 8, after_minutes: 20 },
          { type: 'regeneration', minutes: 8, after_minutes: 50 },
        ],
      },
      proximity: { enabled: true, distance_m: 100, active_after_minutes: 5 },
      taskforce: { hq_required: false, bounty_per_catch: 0 },
      exit: { enabled: false },
      win: { prize: 'Punkte' },
    },
  },
];

export function getPreset(id: string): Preset | undefined {
  return PRESETS.find((p) => p.id === id);
}

export function configFromPreset(id: string): GameConfig {
  const preset = getPreset(id);
  if (!preset) throw new Error(`Unbekannte Vorlage: ${id}`);
  return mergeConfig(defaultConfig(), preset.patch);
}
