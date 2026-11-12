import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { configSections, optionLabel } from '../shared/schemaMeta';
import { PRESETS } from '../shared/presets';
import { QUICK_HELP, SETTING_HELP, STEP_HELP, ZONE_HELP } from '../shared/help';
import { en } from './en';
import { fr } from './fr';
import { _setLangForTest, t } from './index';
import { translateServer } from './server';

/** Texte, die absichtlich nicht übersetzt werden (Marke, technische Namen). */
const KEEP = new Set(['Hunt Mode', 'VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY', '.env', 'useAuth ausserhalb von AuthProvider']);

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) return files(p);
    return /\.tsx?$/.test(f) && !/\.test\./.test(f) && !p.includes('/i18n/') ? [p] : [];
  });
}

function usedKeys(): Set<string> {
  const keys = new Set<string>();
  for (const f of files('src')) {
    const src = readFileSync(f, 'utf8');
    for (const m of src.matchAll(/(?<![\w.])tr?\('((?:[^'\\]|\\.)*)'/g)) keys.add(m[1].replace(/\\'/g, "'").replace(/\\n/g, '\n'));
  }
  for (const s of configSections()) {
    keys.add(s.label);
    for (const f of s.fields) keys.add(f.label);
  }
  for (const p of PRESETS) {
    keys.add(p.name);
    keys.add(p.description);
  }
  for (const [k, v] of Object.entries(QUICK_HELP)) {
    keys.add(k);
    keys.add(v);
  }
  for (const v of Object.values(STEP_HELP)) keys.add(v);
  for (const v of [...Object.values(SETTING_HELP), ...Object.values(ZONE_HELP)]) {
    keys.add(v.title);
    keys.add(v.text);
  }
  return keys;
}

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');

beforeEach(() => _setLangForTest('de'));
afterEach(() => _setLangForTest('de'));

describe('Sprachen', () => {
  it('jeder Text der App hat eine französische und englische Übersetzung', () => {
    const missing = [...usedKeys()].filter((k) => /[A-Za-zÄÖÜäöü]{2,}/.test(k) && !KEEP.has(k) && (!(k in fr) || !(k in en)));
    expect(missing).toEqual([]);
  });

  it('Platzhalter stimmen in allen Sprachen überein', () => {
    const wrong = Object.keys(fr).filter((k) => placeholders(k) !== placeholders(fr[k]) || placeholders(k) !== placeholders(en[k] ?? ''));
    expect(wrong).toEqual([]);
  });

  it('übersetzt mit Platzhaltern', () => {
    _setLangForTest('fr');
    expect(t('Ende in {0}', { 0: '5:00' })).toBe('Fin dans 5:00');
    _setLangForTest('en');
    expect(t('Ende in {0}', { 0: '5:00' })).toBe('Ends in 5:00');
    _setLangForTest('de');
    expect(t('Ende in {0}', { 0: '5:00' })).toBe('Ende in 5:00');
  });

  it('Auswahlwerte werden übersetzt', () => {
    _setLangForTest('en');
    expect(optionLabel('zufall')).toBe('Random');
  });

  it('Meldungen vom Server werden übersetzt, Namen bleiben', () => {
    _setLangForTest('fr');
    expect(translateServer('NOTFALL: Anna braucht Hilfe')).toBe('URGENCE : Anna a besoin d’aide');
    expect(translateServer('BLITZJAGD: Abfrage 2 von 3')).toBe('CHASSE ÉCLAIR : requête 2 sur 3');
    _setLangForTest('en');
    expect(translateServer('Neuer Joker: Nähe-Radar')).toBe('New joker: Proximity radar');
    expect(translateServer('Fluchtpunkt bekannt: Bahnhof')).toBe('Escape point revealed: Bahnhof');
    expect(translateServer('Noch 3 Person(en) ohne Rolle.')).toBe('3 person(s) still without a role.');
    expect(translateServer('Unbekannter neuer Text')).toBe('Unbekannter neuer Text');
  });
});
