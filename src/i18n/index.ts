/**
 * Sprachen: Deutsch (Ausgangstext), Französisch, Englisch.
 *
 * Texte stehen im Code auf Deutsch und werden mit `t('…')` übersetzt. Der deutsche Text ist
 * gleichzeitig der Schlüssel in `fr.ts` und `en.ts`. Platzhalter: `t('Ende in {zeit}', { zeit })`.
 * Jede Person wählt ihre Sprache selbst; gespeichert auf dem Gerät und im Profil.
 */
import { useSyncExternalStore } from 'react';
import { en } from './en';
import { fr } from './fr';

export type Lang = 'de' | 'fr' | 'en';
export const LANGS: { id: Lang; label: string; flag: string }[] = [
  { id: 'de', label: 'Deutsch', flag: 'DE' },
  { id: 'fr', label: 'Français', flag: 'FR' },
  { id: 'en', label: 'English', flag: 'EN' },
];

const KEY = 'hm-lang';
const DICTS: Record<Exclude<Lang, 'de'>, Record<string, string>> = { fr, en };

function detect(): Lang {
  // In den Tests immer Deutsch (Ausgangstexte).
  if ((globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env?.VITEST) return 'de';
  try {
    const saved = localStorage.getItem(KEY);
    if (saved === 'de' || saved === 'fr' || saved === 'en') return saved;
  } catch {
    // ohne Speicher: Sprache des Geräts
  }
  // Sprache des Handys; ist es keine der drei, dann Englisch.
  const langs = typeof navigator !== 'undefined' ? [...(navigator.languages ?? []), navigator.language] : [];
  for (const l of langs) {
    const k = (l || '').slice(0, 2).toLowerCase();
    if (k === 'de' || k === 'fr' || k === 'en') return k;
  }
  return 'en';
}

let current: Lang = detect();
const listeners = new Set<() => void>();
if (typeof document !== 'undefined') document.documentElement.lang = current;

export function getLang(): Lang {
  return current;
}

/** Hat die Person auf diesem Gerät schon selbst eine Sprache gewählt? (Sonst beim ersten Öffnen fragen.) */
export function langChosen(): boolean {
  try {
    return !!localStorage.getItem(KEY);
  } catch {
    return true;
  }
}

export function setLang(lang: Lang) {
  try {
    localStorage.setItem(KEY, lang);
  } catch {
    // nur für diese Sitzung
  }
  if (lang === current) {
    for (const l of listeners) l();
    return;
  }
  current = lang;
  if (typeof document !== 'undefined') document.documentElement.lang = lang;
  for (const l of listeners) l();
}

/** Nur für Tests. */
export function _setLangForTest(lang: Lang) {
  current = lang;
}

export function useLang(): Lang {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
    () => current,
  );
}

type Params = Record<string, unknown>;

function fill(text: string, params?: Params) {
  if (!params) return text;
  return text.replace(/\{(\w+)\}/g, (m, k: string) => (params[k] === undefined || params[k] === null ? m : String(params[k])));
}

/** Übersetzt einen deutschen Text in die eingestellte Sprache (fehlt eine Übersetzung, bleibt Deutsch). */
export function t(de: string, params?: Params): string {
  if (current === 'de') return fill(de, params);
  return fill(DICTS[current][de] ?? de, params);
}

/** Sprache für Datums- und Zeitformate. */
export function locale(): string {
  return current === 'fr' ? 'fr-CH' : current === 'en' ? 'en-GB' : 'de-CH';
}

/**
 * Für feste Listen und Hilfetexte (Konstanten auf Modulebene): Texte werden erst beim Lesen
 * übersetzt, damit ein Sprachwechsel sofort gilt. Nicht für Daten verwenden, die kopiert werden
 * (structuredClone geht mit Proxys nicht).
 */
export function lazy<T extends object>(obj: T): T {
  return new Proxy(obj, {
    get(target, prop, recv) {
      const v = Reflect.get(target, prop, recv);
      if (typeof v === 'string') return t(v);
      if (v && typeof v === 'object') return lazy(v as object);
      return v;
    },
  });
}
