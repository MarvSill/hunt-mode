import { lazy } from '../i18n';
import { Capacitor } from '@capacitor/core';
/**
 * Alarm für Spieler bei jedem Ping und jeder Blitzjagd: Klingelton, Vibration und Meldung.
 * Jeder Spieler stellt Ton, Klingelton, Lautstärke und Vibration auf seinem Handy selbst ein
 * (gespeichert nur auf diesem Gerät). Der Browser spielt Töne erst nach einer ersten Berührung
 * der Seite und nur, solange die App offen ist.
 */

export type Tone = 'klingel' | 'sirene' | 'piep';
export type AlarmKind = 'ping' | 'blitzjagd';

export interface AlarmSettings {
  sound: boolean;
  tone: Tone;
  /** 0 bis 1 */
  volume: number;
  vibrate: boolean;
}

export const TONE_LABELS: Record<Tone, string> = lazy({ klingel: 'Telefon', sirene: 'Sirene', piep: 'Piepen' });

const KEY = 'hm-alarm';
const DEFAULTS: AlarmSettings = { sound: true, tone: 'klingel', volume: 0.8, vibrate: true };

export function loadAlarm(): AlarmSettings {
  try {
    return { ...DEFAULTS, ...(JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<AlarmSettings>) };
  } catch {
    return DEFAULTS;
  }
}

export function saveAlarm(s: AlarmSettings) {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    // ohne Speicher gilt die Einstellung nur bis zum Neuladen
  }
}

let ctx: AudioContext | null = null;
function audio(): AudioContext {
  if (!ctx) {
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    ctx = new Ctx();
  }
  if (ctx.state === 'suspended') void ctx.resume();
  return ctx;
}

/** Bei der ersten Berührung aufrufen, damit der Browser später Töne abspielen darf. */
export function unlockAudio() {
  try {
    audio();
  } catch {
    // kein Ton möglich
  }
}

export const VIBRATION: Record<AlarmKind, number[]> = {
  ping: [300, 120, 300, 120, 300],
  blitzjagd: [500, 150, 500, 150, 500, 150, 500, 150, 500],
};

/**
 * Vibration nach Muster [an, aus, an, …] in ms. iPhones kennen navigator.vibrate nicht:
 * in der Handy-App läuft die Vibration darum über das Haptics-Modul, Stoss für Stoss.
 */
export function vibrate(pattern: number[]) {
  if (!Capacitor.isNativePlatform()) {
    navigator.vibrate?.(pattern);
    return;
  }
  void import('@capacitor/haptics').then(({ Haptics }) => {
    let t = 0;
    pattern.forEach((ms, i) => {
      if (i % 2 === 0) setTimeout(() => void Haptics.vibrate({ duration: ms }).catch(() => undefined), t);
      t += ms;
    });
  }).catch(() => navigator.vibrate?.(pattern));
}

/** Ein Ton-Abschnitt: Frequenz von, Frequenz bis, Dauer (s). */
type Segment = [number, number, number];

function pattern(tone: Tone): { segments: Segment[]; gap: number; wave: OscillatorType } {
  if (tone === 'sirene') return { segments: [[600, 1300, 0.55], [1300, 600, 0.55]], gap: 0.05, wave: 'sawtooth' };
  if (tone === 'piep') return { segments: [[1000, 1000, 0.15], [0, 0, 0.1], [1000, 1000, 0.15]], gap: 0.35, wave: 'sine' };
  // Telefon: schnelles Trillern zwischen zwei Tönen
  const trill: Segment[] = [];
  for (let i = 0; i < 10; i++) trill.push(i % 2 ? [800, 800, 0.05] : [1050, 1050, 0.05]);
  return { segments: trill, gap: 0.4, wave: 'square' };
}

/** Alarm auslösen: Vibration und Klingelton nach den Einstellungen des Spielers. */
export function ring(kind: AlarmKind, s: AlarmSettings = loadAlarm()) {
  if (s.vibrate) vibrate(VIBRATION[kind]);
  if (!s.sound || s.volume <= 0) return;
  try {
    const c = audio();
    const out = c.createGain();
    out.gain.value = Math.min(1, s.volume) * 0.35;
    out.connect(c.destination);
    const { segments, gap, wave } = pattern(s.tone);
    const repeats = kind === 'blitzjagd' ? 5 : 3;
    let t = c.currentTime + 0.03;
    for (let r = 0; r < repeats; r++) {
      for (const [from, to, dur] of segments) {
        if (from > 0) {
          const o = c.createOscillator();
          const g = c.createGain();
          o.type = wave;
          o.frequency.setValueAtTime(from, t);
          o.frequency.linearRampToValueAtTime(to, t + dur);
          g.gain.setValueAtTime(0, t);
          g.gain.linearRampToValueAtTime(1, t + 0.01);
          g.gain.setValueAtTime(1, t + dur - 0.01);
          g.gain.linearRampToValueAtTime(0, t + dur);
          o.connect(g).connect(out);
          o.start(t);
          o.stop(t + dur);
        }
        t += dur;
      }
      t += gap;
    }
  } catch {
    // ohne Ton
  }
}

/** Welche Meldungen einen Alarm auslösen. */
export function alarmKindOf(kinds: string[]): AlarmKind | null {
  if (kinds.some((k) => k === 'speedhunt_start' || k === 'speedhunt_query' || k === 'outside_warning' || k === 'outside' || k === 'danger_warning' || k === 'danger_live')) return 'blitzjagd';
  if (kinds.some((k) => k === 'hunter_early')) return 'blitzjagd';
  if (kinds.some((k) => k === 'ping' || k === 'ping_self')) return 'ping';
  return null;
}
