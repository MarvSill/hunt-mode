/**
 * Kartenstil und 3D: jede Person wählt selbst (gespeichert nur auf diesem Gerät).
 * Kartendaten: OpenFreeMap (OpenMapTiles, OpenStreetMap) und CARTO, ohne Konto und ohne Schlüssel.
 */
import { useSyncExternalStore } from 'react';

export type MapStyleId = 'auto' | 'stadt3d' | 'klar' | 'nacht';

export interface MapSettings {
  style: MapStyleId;
  /** Karte im Spiel und in der Wiederholung geneigt mit 3D-Gebäuden. */
  tilt: boolean;
}

export const MAP_STYLES: { id: Exclude<MapStyleId, 'auto'>; label: string; hint: string; url: string; dark: boolean }[] = [
  { id: 'stadt3d', label: 'Stadt in 3D', hint: 'hell, mit 3D-Gebäuden', url: 'https://tiles.openfreemap.org/styles/liberty', dark: false },
  { id: 'klar', label: 'Klar und ruhig', hint: 'hell und schlicht', url: 'https://tiles.openfreemap.org/styles/positron', dark: false },
  { id: 'nacht', label: 'Nacht', hint: 'dunkel, leuchtende Zonen', url: 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json', dark: true },
];

const KEY = 'hm-map';
const DEFAULTS: MapSettings = { style: 'auto', tilt: true };

function load(): MapSettings {
  try {
    return { ...DEFAULTS, ...(JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<MapSettings>) };
  } catch {
    return DEFAULTS;
  }
}

let current = load();
const listeners = new Set<() => void>();

export function getMapSettings(): MapSettings {
  return current;
}

export function setMapSettings(next: Partial<MapSettings>) {
  current = { ...current, ...next };
  try {
    localStorage.setItem(KEY, JSON.stringify(current));
  } catch {
    // nur für diese Sitzung
  }
  for (const l of listeners) l();
}

export function useMapSettings(): MapSettings {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
    () => current,
  );
}

function prefersDark(): boolean {
  try {
    return window.matchMedia('(prefers-color-scheme: dark)').matches;
  } catch {
    return false;
  }
}

/** Der tatsächlich verwendete Stil: "automatisch" heisst hell am Tag, dunkel im Dunkelmodus des Handys. */
export function resolveStyle(id: MapStyleId) {
  const real = id === 'auto' ? (prefersDark() ? 'nacht' : 'stadt3d') : id;
  return MAP_STYLES.find((s) => s.id === real) ?? MAP_STYLES[0];
}

/** Nächster Stil für den Wechsel-Knopf auf der Karte. */
export function nextStyle(id: MapStyleId): MapStyleId {
  const order: MapStyleId[] = ['stadt3d', 'klar', 'nacht'];
  const real = resolveStyle(id).id;
  return order[(order.indexOf(real) + 1) % order.length];
}
