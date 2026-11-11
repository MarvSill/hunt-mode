/**
 * Spielkonfiguration (Spezifikation Kapitel 8).
 *
 * Jeder Zahlenwert der Regeln ist hier ein Parameter. Die Beschriftung jedes
 * Feldes steckt in `.describe()`, damit der Regel-Editor direkt aus dem Schema
 * gebaut werden kann.
 *
 * Das Spiel läuft immer am Stück: es gibt nur einen Abschnitt (`game.days` = 1),
 * keine jagdfreien Zeiten und keine Pause. Die App regelt alles selbst.
 */
import { z } from 'zod';

const int = (def: number, min: number, max: number, label: string) =>
  z.number().int().min(min).max(max).default(def).describe(label);

const bool = (def: boolean, label: string) => z.boolean().default(def).describe(label);

const choice = <T extends [string, ...string[]]>(values: T, def: T[number], label: string) =>
  z.enum(values).default(def as never).describe(label);

const text = (def: string, max: number, label: string) =>
  z.string().max(max).default(def).describe(label);

export const TRANSPORT_MODES = [
  'zu_fuss',
  'oev_bus',
  'oev_bahn',
  'oev_tram',
  'faehre',
  'taxi',
  'fahrrad',
  'scooter',
  'eigenes_fahrzeug',
] as const;

export const JOKER_TYPES = ['regeneration', 'hunter_erfragen'] as const;

export const CATCH_METHODS = ['qr', 'touch_confirm', 'nfc', 'bluetooth', 'handcuffs'] as const;


/** Ein Joker: welche Art, wie lange er wirkt und nach wie viel Spielzeit er freigeschaltet wird. */
const jokerTypeSchema = z.object({
  type: z.enum(JOKER_TYPES),
  minutes: z.number().int().min(0).max(1440).optional(),
  after_minutes: z.number().int().min(0).max(20160).default(0),
});

export const gameConfigSchema = z.object({
  game: z
    .object({
      timezone: text('Europe/Zurich', 64, 'Zeitzone'),
      duration_minutes: int(180, 15, 20160, 'Spielzeit mit Vorsprung (min)'),
      // Intern: ein einziger Abschnitt, damit die Engine das Spiel am Stück laufen lässt.
      days: int(1, 1, 14, 'Abschnitte'),
      day_length_minutes: int(180, 10, 1440, 'Abschnittslänge (min)'),
    })
    .default({})
    .describe('Spiel und Zeit'),
  roles: z
    .object({
      players_max: int(6, 1, 100, 'Max. Spieler'),
      hunters_max: int(3, 1, 50, 'Max. Hunter'),
      assignment: choice(['host', 'zufall', 'selbst'], 'host', 'Rollenvergabe'),
      balanced_random: bool(true, 'Ausgeglichene Zufallsverteilung'),
    })
    .default({})
    .describe('Rollen'),
  start: z
    .object({
      head_start_minutes: int(60, 0, 600, 'Vorsprung (min)'),
      hq_radius_m: int(100, 20, 1000, 'Wartebereich der Hunter am Startpunkt (m)'),
      hunters_must_stay_in_hq: bool(true, 'Hunter warten am Startpunkt während Vorsprung'),
    })
    .default({})
    .describe('Start'),
  lobby: z
    .object({
      open_minutes_before: int(60, 5, 1440, 'Lobby öffnet vor Start (min)'),
      min_battery_percent: int(60, 0, 100, 'Akku für Startfreigabe (%)'),
    })
    .default({})
    .describe('Lobby'),
  time: z
    .object({
      align_to_full_hour: bool(false, 'Pings auf volle Stunden ausrichten'),
      scale_auto: bool(false, 'Dauern proportional skalieren'),
    })
    .default({})
    .describe('Zeitraster'),
  zone: z
    .object({
      edge_tolerance_m: int(25, 0, 200, 'GPS-Toleranz am Rand (m)'),
      shrink_mode: choice(['manuell', 'auto', 'aus'], 'manuell', 'Spielfeld-Verkleinerung'),
      auto_shrink_percent: int(20, 1, 80, 'Verkleinerung pro Phase (%)'),
      shrink_every_minutes: int(0, 0, 1440, 'Verkleinerung alle (min)'),
      shrink_announce_minutes: int(180, 0, 1440, 'Vorankündigung Verkleinerung (min)'),
      restricted_crossing_max_seconds: int(60, 0, 600, 'Gefahrenzone mit "Überqueren erlaubt": so lange (s)'),
    })
    .default({})
    .describe('Spielfeld und Zonen'),
  ping: z
    .object({
      interval_minutes: int(15, 1, 720, 'Ping-Intervall (min)'),
      offset_minutes: int(0, 0, 719, 'Versatz (min)'),
      jitter_minutes: int(0, 0, 30, 'Zufallsversatz (min)'),
      during_speedhunt: choice(['weiterlaufen', 'aussetzen'], 'weiterlaufen', 'Pings während einer Blitzjagd'),
      // Fest 0: nach dem Vorsprung kommt sofort ein Ping.
      first_ping_delay_minutes: int(0, 0, 600, 'Erster Ping nach Vorsprung (min)'),
      max_age_seconds: int(60, 10, 600, 'Frische-Regel (s)'),
      fresh_fix_wait_seconds: int(30, 5, 120, 'Wartezeit auf frischen Standort (s)'),
      show_suppressed_to_taskforce: bool(false, '"Kein Signal" den Huntern anzeigen'),
      fade_after_minutes: int(60, 5, 600, 'Marker verblassen nach (min)'),
      history_per_player: int(200, 1, 500, 'Sichtbare Pings pro Spieler'),
      reveal_schedule_to_taskforce: bool(true, 'Nächster Ping-Zeitpunkt sichtbar'),
    })
    .default({})
    .describe('Pings'),
  speedhunt: z
    .object({
      enabled: bool(true, 'Blitzjagden aktiv'),
      // Nur der erste Wert zählt: Anzahl Blitzjagden im ganzen Spiel.
      quota_per_day: z
        .array(z.number().int().min(0).max(20))
        .default([2])
        .describe('Blitzjagden im ganzen Spiel'),
      queries: int(3, 1, 20, 'Abfragen pro Blitzjagd'),
      query_min_gap_minutes: int(0, 0, 60, 'Mindestabstand Abfragen (min)'),
      min_minutes_after_silent_ping: int(0, 0, 120, 'Abstand zum letzten Ping (min)'),
      early_start_policy: choice(
        ['verbieten', 'silent_zaehlt_als_abfrage'],
        'silent_zaehlt_als_abfrage',
        'Zu früher Start',
      ),
      max_per_player_per_day: int(0, 0, 10, 'Max. pro Spieler (0 = unbegrenzt)'),
      no_consecutive_same_target: bool(true, 'Nicht zweimal hintereinander gleiches Ziel'),
      consecutive_allowed_when_players_left_le: int(2, 1, 10, 'Ausnahme ab so wenigen freien Spielern'),
      max_parallel: int(2, 1, 10, 'Gleichzeitig laufend'),
      vehicle_live_seconds: int(0, 0, 600, 'Live bei Fahrzeug (s)'),
      catch_removes_one: bool(false, 'Fang streicht eine Blitzjagd'),
      reveal_target_to_target: bool(false, 'Ziel erfährt, dass es gejagt wird'),
      notify_each_query_to_players: bool(true, 'Spieler hören jede Abfrage'),
      announce_text: text('Blitzjagd gestartet!', 200, 'Meldungstext'),
    })
    .default({})
    .describe('Blitzjagd'),
  catch: z
    .object({
      method: z.array(z.enum(CATCH_METHODS)).min(1).default(['qr']).describe('Fangmethode'),
      max_distance_m: int(30, 5, 200, 'GPS-Plausibilität (m)'),
      confirm_seconds: int(60, 10, 300, 'Bestätigungsfrist (s)'),
      require_media: bool(false, 'Foto/Video-Beweis'),
      announce_to_players: bool(true, 'Fang öffentlich'),
      caught_player_becomes: choice(['zuschauer', 'hunter_helfer', 'nichts'], 'zuschauer', 'Gefangene werden'),
      track_after_catch: bool(false, 'Ortung nach Fang weiter'),
    })
    .default({})
    .describe('Fang'),
  out_of_bounds: z
    .object({
      live_visible: bool(true, 'Live für die Hunter'),
      max_minutes: int(10, 1, 600, 'Limit draussen bzw. in Gefahrenzone (min)'),
      count_mode: choice(['pro_ausflug', 'pro_tag'], 'pro_ausflug', 'Zählweise'),
      on_timeout: choice(['catch', 'disqualify', 'penalty'], 'catch', 'Folge bei Ablauf'),
      grace_seconds: int(60, 0, 600, 'Countdown beim Verlassen des Spielfelds oder Betreten einer Gefahrenzone (s, 1. und 2. Mal)'),
    })
    .default({})
    .describe('Ausserhalb des Spielfelds'),
  hideout: z
    .object({
      enabled: bool(true, 'Verschanzen-Regel aktiv'),
      max_minutes: int(30, 5, 720, 'Limit (min)'),
      min_leave_distance_m: int(150, 0, 2000, 'Mindestabstand beim Verlassen (m)'),
      lockout_after_first_entry_minutes: int(0, 0, 2880, 'Ort gesperrt nach (min, 0 = aus)'),
      detection: choice(['selbstmeldung', 'automatisch', 'beides'], 'beides', 'Erkennung'),
      stationary_radius_m: int(40, 10, 200, 'Erkennung Radius (m)'),
      stationary_minutes: int(20, 5, 120, 'Erkennung Dauer (min)'),
      on_timeout: choice(['catch', 'penalty'], 'catch', 'Folge bei Ablauf'),
    })
    .default({})
    .describe('Verschanzen'),
  transport: z
    .object({
      motorized_allowed: bool(true, 'ÖV, Taxi und Auto erlaubt'),
      bikes_allowed: bool(true, 'Velo und Trottinett erlaubt'),
      // Intern: kein Anmelden und kein Live-Standort bei Fahrten (setzt die App selbst).
      checkin_required: bool(false, 'Anmeldepflicht'),
      live_during: bool(false, 'Live während Fahrt'),
    })
    .default({})
    .describe('Fortbewegung'),
  joker: z
    .object({
      enabled: bool(false, 'Joker aktiv'),
      // Jeder Eintrag wird nach `after_minutes` Spielzeit einmal an jeden Spieler vergeben.
      // Ältere Spiele können entfernte Joker enthalten; die werden beim Lesen weggelassen.
      types: z
        .preprocess(
          (v) => (Array.isArray(v) ? v.filter((x) => (JOKER_TYPES as readonly string[]).includes((x as { type?: string })?.type ?? '')) : v),
          z.array(jokerTypeSchema),
        )
        .default([
          { type: 'regeneration', minutes: 15, after_minutes: 30 },
          { type: 'hunter_erfragen', after_minutes: 60 },
        ])
        .describe('Joker und wann sie freigeschaltet werden'),
    })
    .default({})
    .describe('Joker'),
  proximity: z
    .object({
      enabled: bool(true, 'Nähe-Alarm aktiv'),
      distance_m: int(150, 10, 2000, 'Abstand (m)'),
      active_after_minutes: int(10, 0, 600, 'Aktiv ab Start (min)'),
      hysteresis_m: int(50, 0, 500, 'Hysterese (m)'),
      warn_minutes: int(2, 0, 30, 'Zeit zum Auseinandergehen (min)'),
    })
    .default({})
    .describe('Nähe-Alarm'),
  taskforce: z
    .object({
      bounty_per_catch: int(0, 0, 100000, 'Punkte pro Fang (Hunter)'),
      share_positions_internally: bool(true, 'Hunter sehen sich gegenseitig'),
    })
    .default({})
    .describe('Hunter-Team'),
  exit: z
    .object({
      enabled: bool(true, 'Fluchtpunkt aktiv'),
      radius_m: int(30, 5, 500, 'Radius (m)'),
      reveal_minutes_before_end: int(10, 0, 1440, 'Bekanntgabe vor Ende (min)'),
      usable_minutes_before_end: int(2, 0, 1440, 'Nutzbar ab vor Ende (min)'),
      // Fest 0: das Spiel endet pünktlich, ohne Nachspielzeit.
      arrival_deadline_offset_minutes: int(0, 0, 120, 'Ankunftsfrist nach Ende (min)'),
      confirm: choice(['geofence', 'qr'], 'geofence', 'Bestätigung'),
      missed_policy: choice(['verloren', 'gewonnen_ohne_exit'], 'verloren', 'Nicht angekommen'),
    })
    .default({})
    .describe('Fluchtpunkt'),
  win: z
    .object({
      mode: choice(['alle_ueberlebenden', 'letzter_ueberlebender', 'punkte'], 'alle_ueberlebenden', 'Siegmodus'),
      prize: text('', 100, 'Preis (Anzeige)'),
    })
    .default({})
    .describe('Sieg'),
  safety: z
    .object({
      min_age: int(16, 0, 99, 'Mindestalter'),
      battery_warn_percent: int(25, 5, 50, 'Akkuwarnung (%)'),
    })
    .default({})
    .describe('Sicherheit'),
  tracking: z
    .object({
      sample_interval_seconds: int(15, 5, 120, 'GPS-Intervall (s)'),
      signal_loss_max_minutes: int(15, 1, 120, 'Signalverlust-Meldung nach (min)'),
    })
    .default({})
    .describe('Ortung'),
  spectator: z
    .object({
      enabled: bool(false, 'Zuschauer erlaubt'),
      delay_minutes: int(30, 0, 240, 'Verzögerung (min)'),
    })
    .default({})
    .describe('Zuschauer'),
  privacy: z
    .object({
      retention_days: int(30, 1, 365, 'Standortdaten löschen nach (Tage)'),
    })
    .default({})
    .describe('Datenschutz'),
  account: z
    .object({
      require_verified_email: bool(true, 'Bestätigte E-Mail Pflicht'),
    })
    .default({})
    .describe('Konten'),
  extras: z
    .object({
      rules: z.array(z.string().trim().min(1).max(300)).max(30).default([]).describe('Zusatzregeln (Text)'),
    })
    .default({})
    .describe('Eigene Zusatzregeln'),
});

export type GameConfig = z.infer<typeof gameConfigSchema>;
export type ConfigSection = keyof GameConfig;

/** Aktuelle Schema-Version, wird mit jeder Konfiguration gespeichert. */
export const CONFIG_VERSION = 1;

/**
 * Das Spiel läuft am Stück: genau ein Abschnitt, so lang wie die Spieldauer
 * (höchstens 24 h, die Engine braucht danach keinen weiteren Abschnitt).
 */
export function normalizeConfig(c: GameConfig): GameConfig {
  c.game.days = 1;
  c.game.day_length_minutes = Math.min(1440, c.game.duration_minutes);
  c.speedhunt.quota_per_day = [c.speedhunt.quota_per_day[0] ?? 0];
  // Keine Strafen und kein Live-Standort bei Fahrten: die Folge ist immer "gefangen".
  c.speedhunt.vehicle_live_seconds = 0;
  c.out_of_bounds.on_timeout = 'catch';
  c.hideout.on_timeout = 'catch';
  c.hideout.lockout_after_first_entry_minutes = 0;
  c.transport.checkin_required = false;
  c.transport.live_during = false;
  // Hunter sehen alle bisherigen Pings (auf der Karte wählt jeder selbst, wie viele).
  c.ping.history_per_player = Math.max(c.ping.history_per_player, 200);
  // Nach dem Vorsprung sofort ein Ping; das Spiel endet pünktlich; nie zweimal dasselbe Ziel.
  c.ping.first_ping_delay_minutes = 0;
  c.exit.arrival_deadline_offset_minutes = 0;
  c.speedhunt.no_consecutive_same_target = true;
  // Spielzeit gilt alles inklusive: der Vorsprung ist ein Teil davon.
  c.start.head_start_minutes = Math.min(c.start.head_start_minutes, Math.max(0, c.game.duration_minutes - 5));
  c.exit.usable_minutes_before_end = Math.min(c.exit.usable_minutes_before_end, c.exit.reveal_minutes_before_end);
  // Fangen geht immer auf beide Arten: Zahlencode eingeben oder Fang melden und der Spieler bestätigt.
  c.catch.method = ['qr', 'touch_confirm'];
  return c;
}

/** Vollständige Standardkonfiguration. */
export function defaultConfig(): GameConfig {
  return normalizeConfig(gameConfigSchema.parse({}));
}

export type DeepPartial<T> = {
  [K in keyof T]?: T[K] extends unknown[] ? T[K] : T[K] extends object ? DeepPartial<T[K]> : T[K];
};

/** Legt `patch` über `base`. Arrays und Maps werden ersetzt, nicht gemischt. */
export function mergeConfig(base: GameConfig, patch: DeepPartial<GameConfig>): GameConfig {
  const out = structuredClone(base) as Record<string, Record<string, unknown>>;
  for (const [section, values] of Object.entries(patch)) {
    if (!values) continue;
    out[section] = { ...out[section], ...structuredClone(values) };
  }
  return normalizeConfig(gameConfigSchema.parse(out));
}

/** Liest eine gespeicherte Konfiguration; fehlende Felder bekommen Standardwerte. */
export function parseConfig(raw: unknown): GameConfig {
  return normalizeConfig(gameConfigSchema.parse(raw ?? {}));
}
