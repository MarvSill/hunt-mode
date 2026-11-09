import { fitTimes } from './timeRules';
import { describe, expect, it } from 'vitest';
import { defaultConfig, gameConfigSchema, mergeConfig, parseConfig } from './config';
import { PRESETS, configFromPreset } from './presets';
import { validateConfig } from './validation';

describe('Konfiguration', () => {
  it('Standardwerte: 3 h am Stück, ein Abschnitt', () => {
    const c = defaultConfig();
    expect(c.game.duration_minutes).toBe(180);
    expect(c.game.days).toBe(1);
    expect(c.game.day_length_minutes).toBe(180);
    expect(c.ping.interval_minutes).toBe(15);
    expect(c.speedhunt.quota_per_day).toEqual([2]);
    expect(c.transport.allowed_modes).not.toContain('eigenes_fahrzeug');
  });

  it('alte Spiele mit mehreren Spieltagen laufen jetzt am Stück', () => {
    const c = parseConfig({ game: { duration_minutes: 1440, days: 4, day_length_minutes: 360 }, speedhunt: { quota_per_day: [2, 1, 1] } });
    expect(c.game.days).toBe(1);
    expect(c.game.day_length_minutes).toBe(1440);
    expect(c.speedhunt.quota_per_day).toEqual([2]);
  });

  it('entfernte Einstellungen (Spielleitung, Schonzeit, Challenges) werden ignoriert', () => {
    const c = parseConfig({ roles: { gm_mode: 'mensch' }, leo: { enabled: true }, challenge: { enabled: true }, game: { quiet_hours: [{ from: '23:00', to: '07:00' }] } });
    expect('gm_mode' in c.roles).toBe(false);
    expect('leo' in c).toBe(false);
    expect('challenge' in c).toBe(false);
    expect('quiet_hours' in c.game).toBe(false);
  });

  it('es gibt nur ein Spielfeld: Einstellungen für weitere Gebiete werden ignoriert', () => {
    const c = parseConfig({ ping: { zone_overrides: { kern: 30 } }, zone: { sections_per_player: true }, transport: { forbidden_in_zone_types: ['center'] } });
    expect('zone_overrides' in c.ping).toBe(false);
    expect('sections_per_player' in c.zone).toBe(false);
    expect('forbidden_in_zone_types' in c.transport).toBe(false);
  });

  it('Joker ohne Freischaltzeit kommen ab Jagdbeginn', () => {
    const c = parseConfig({ joker: { enabled: true, types: [{ type: 'catch_free', minutes: 10 }] } });
    expect(c.joker.types[0].after_minutes).toBe(0);
  });

  it('ergänzt fehlende Felder einer gespeicherten Konfiguration', () => {
    const c = parseConfig({ ping: { interval_minutes: 30 } });
    expect(c.ping.interval_minutes).toBe(30);
    expect(c.ping.max_age_seconds).toBe(60);
    expect(c.exit.enabled).toBe(true);
  });

  it('lehnt Werte ausserhalb des Bereichs ab', () => {
    expect(gameConfigSchema.safeParse({ ping: { interval_minutes: 0 } }).success).toBe(false);
    expect(gameConfigSchema.safeParse({ roles: { players_max: 101 } }).success).toBe(false);
  });

  it('mergeConfig ersetzt Listen statt sie zu mischen', () => {
    const c = mergeConfig(defaultConfig(), { joker: { types: [{ type: 'catch_free', minutes: 5, after_minutes: 10 }] }, speedhunt: { quota_per_day: [1] } });
    expect(c.joker.types).toEqual([{ type: 'catch_free', minutes: 5, after_minutes: 10 }]);
    expect(c.speedhunt.quota_per_day).toEqual([1]);
    expect(c.ping.interval_minutes).toBe(15);
  });
});

describe('Vorlagen', () => {
  it('bietet drei Vorlagen an', () => {
    expect(PRESETS.map((p) => p.id)).toEqual(['wochenende_24h', 'stadtabend_3h', 'schnell_90min']);
  });

  it.each(PRESETS.map((p) => [p.id, p] as const))('%s ist gültig und startbar', (_id, preset) => {
    const config = configFromPreset(preset.id);
    const result = validateConfig(config, preset.suggested);
    const blocking = result.issues.filter((i) => i.level === 'error');
    expect(blocking).toEqual([]);
    expect(result.config.roles.players_max).toBe(preset.suggested.players);
    expect(result.config.roles.hunters_max).toBe(preset.suggested.hunters);
  });

  it('alle Vorlagen laufen am Stück', () => {
    for (const p of PRESETS) {
      const c = configFromPreset(p.id);
      expect(c.game.days).toBe(1);
      expect(c.game.day_length_minutes).toBe(Math.min(1440, c.game.duration_minutes));
    }
  });

  it('Joker kommen in der Reihenfolge ihrer Freischaltzeit und vor Spielende', () => {
    for (const p of PRESETS) {
      const c = configFromPreset(p.id);
      const after = c.joker.types.map((j) => j.after_minutes);
      expect(after).toEqual([...after].sort((a, b) => a - b));
      for (const a of after) expect(a).toBeLessThan(c.game.duration_minutes);
    }
  });

  it('Vorlagen heissen nach ihrer Dauer', () => {
    for (const p of PRESETS) expect(p.name).toMatch(/\d+ (min|h)$/);
  });

  it('kurze Presets zählen ab Spielstart statt auf volle Stunden', () => {
    for (const id of ['wochenende_24h', 'stadtabend_3h', 'schnell_90min']) {
      expect(configFromPreset(id).time.align_to_full_hour).toBe(false);
    }
  });

  it('Schnell 90 min: am Stück, Pings alle 10 min, 3 Blitzjagden', () => {
    const c = configFromPreset('schnell_90min');
    expect(c.game.duration_minutes).toBe(90);
    expect(c.ping.interval_minutes).toBe(10);
    expect(c.speedhunt.quota_per_day).toEqual([3]);
  });
});

describe('Validierung', () => {
  it('Intervall 240 bei Spieldauer 180 wird automatisch angepasst', () => {
    const c = mergeConfig(defaultConfig(), { game: { duration_minutes: 180 }, ping: { interval_minutes: 240 } });
    const r = validateConfig(c);
    expect(r.config.ping.interval_minutes).toBeLessThan(180);
    expect(r.issues.some((i) => i.level === 'autofix' && i.paths.includes('ping.interval_minutes'))).toBe(true);
    expect(r.issues.some((i) => i.code === 'no_ping')).toBe(false);
  });

  it('braucht mindestens einen Spieler und einen Hunter', () => {
    expect(validateConfig(defaultConfig(), { players: 3, hunters: 0 }).canStart).toBe(false);
    expect(validateConfig(defaultConfig(), { players: 3, hunters: 2 }).canStart).toBe(true);
  });

  it('Blitzjagd länger als das Spiel wird gekürzt', () => {
    const c = mergeConfig(defaultConfig(), { game: { duration_minutes: 60 }, ping: { interval_minutes: 10 }, speedhunt: { max_duration_minutes: 90 } });
    expect(validateConfig(c).config.speedhunt.max_duration_minutes).toBe(60);
  });

  it('Blitzjagden löst nur das Hunter-Team oder der Zufall aus', () => {
    expect(gameConfigSchema.safeParse({ speedhunt: { trigger_mode: 'gm' } }).success).toBe(false);
  });

  it('schaltet "Zentrale besetzt" bei nur einem Hunter automatisch aus', () => {
    const r = validateConfig(defaultConfig(), { players: 3, hunters: 1 });
    expect(r.config.taskforce.hq_required).toBe(false);
    expect(r.issues.some((i) => i.level === 'autofix')).toBe(true);
    expect(r.canStart).toBe(true);
  });

  it('Handschellen mit Minderjährigen sind verboten', () => {
    const c = mergeConfig(defaultConfig(), { catch: { method: ['qr', 'handcuffs'] } });
    expect(validateConfig(c, { hasMinors: true }).canStart).toBe(false);
    expect(validateConfig(c, { hasMinors: false }).canStart).toBe(true);
  });

  it('Bekanntgabe des Fluchtpunkts vor Spielbeginn wird angepasst', () => {
    const c = mergeConfig(defaultConfig(), { game: { duration_minutes: 60 }, ping: { interval_minutes: 10 }, exit: { reveal_minutes_before_end: 120 } });
    expect(validateConfig(c).config.exit.reveal_minutes_before_end).toBe(60);
  });

  it('warnt bei kurzen Spielen mit Ausrichtung auf volle Stunden', () => {
    const c = mergeConfig(defaultConfig(), { game: { duration_minutes: 60 }, time: { align_to_full_hour: true }, ping: { interval_minutes: 10 }, speedhunt: { max_duration_minutes: 30 } });
    const issue = validateConfig(c).issues.find((i) => i.code === 'align_short_game');
    expect(issue?.level).toBe('warning');
  });

  it('warnt: letzter Überlebender ignoriert den Fluchtpunkt', () => {
    const c = mergeConfig(defaultConfig(), { win: { mode: 'letzter_ueberlebender' } });
    expect(validateConfig(c).issues.some((i) => i.code === 'exit_ignored')).toBe(true);
  });
});

describe('Eigene Zusatzregeln', () => {
  it('sind standardmässig leer und werden gekürzt gespeichert', () => {
    expect(defaultConfig().extras.rules).toEqual([]);
    const c = parseConfig({ extras: { rules: ['  Kein Taxi nach 22 Uhr  '] } });
    expect(c.extras.rules).toEqual(['Kein Taxi nach 22 Uhr']);
  });

  it('lehnt leere und zu viele Regeln ab', () => {
    expect(() => parseConfig({ extras: { rules: [' '] } })).toThrow();
    expect(() => parseConfig({ extras: { rules: Array(31).fill('x') } })).toThrow();
  });
});

describe('Zeitlogik', () => {
  it('Vorlagen brauchen keine Korrektur', () => {
    for (const p of PRESETS) expect(fitTimes(mergeConfig(defaultConfig(), p.patch)).fixes.map((f) => `${p.id}: ${f.message}`)).toEqual([]);
  });

  it('90 min Spiel: Verkleinerung, Pings und Meldungen passen in die Spieldauer', () => {
    const c = mergeConfig(defaultConfig(), {
      game: { duration_minutes: 90 },
      zone: { shrink_mode: 'auto', shrink_every_minutes: 0, shrink_announce_minutes: 180 },
      ping: { interval_minutes: 120, first_ping_delay_minutes: 100 },
      speedhunt: { max_duration_minutes: 200 },
      exit: { reveal_minutes_before_end: 120 },
      joker: { enabled: true, types: [{ type: 'regeneration', minutes: 240, after_minutes: 300 }] },
    });
    const { config: f, fixes } = fitTimes(c);
    expect(f.zone.shrink_every_minutes).toBeGreaterThan(0);
    expect(f.zone.shrink_every_minutes).toBeLessThanOrEqual(45);
    expect(f.zone.shrink_announce_minutes).toBeLessThanOrEqual(f.zone.shrink_every_minutes);
    expect(f.ping.first_ping_delay_minutes + f.ping.interval_minutes).toBeLessThan(90);
    expect(f.speedhunt.max_duration_minutes).toBeLessThanOrEqual(90);
    expect(f.exit.reveal_minutes_before_end).toBeLessThanOrEqual(90);
    expect(f.joker.types[0].after_minutes).toBeLessThan(90);
    expect(f.joker.types[0].minutes).toBeLessThanOrEqual(90);
    expect(fixes.length).toBeGreaterThan(5);
    // Nochmals anwenden ändert nichts mehr.
    expect(fitTimes(f).fixes).toEqual([]);
  });
});
