/**
 * Kartenstil und 3D: jede Person wählt selbst (gespeichert nur auf diesem Gerät).
 * Kartendaten: OpenFreeMap (OpenMapTiles, OpenStreetMap) und CARTO, ohne Konto und ohne Schlüssel.
 */
import { useSyncExternalStore } from 'react';
import type { StyleSpecification } from 'maplibre-gl';

export type MapStyleId = 'auto' | 'klassisch' | 'stadt3d' | 'klar' | 'nacht';

export interface MapSettings {
  style: MapStyleId;
  /** Karte im Spiel und in der Wiederholung geneigt mit 3D-Gebäuden. */
  tilt: boolean;
  /** Karte zeigt immer nach Norden (kein Drehen). */
  north: boolean;
}

/** Klassische OpenStreetMap-Karte (wie früher), als Kachel-Adresse. */
export const OSM_TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const CLASSIC: StyleSpecification = {
  version: 8,
  sources: { osm: { type: 'raster', tiles: [OSM_TILES], tileSize: 256, maxzoom: 19, attribution: '© OpenStreetMap' } },
  layers: [{ id: 'osm', type: 'raster', source: 'osm' }],
};

export const MAP_STYLES: { id: Exclude<MapStyleId, 'auto'>; label: string; hint: string; url: string | StyleSpecification; dark: boolean; raster?: boolean }[] = [
  { id: 'klassisch', label: 'Klassisch', hint: 'die gewohnte OpenStreetMap-Karte', url: CLASSIC, dark: false, raster: true },
  { id: 'stadt3d', label: 'Stadt in 3D', hint: 'hell, mit 3D-Gebäuden', url: 'https://tiles.openfreemap.org/styles/liberty', dark: false },
  { id: 'klar', label: 'Klar und ruhig', hint: 'hell und schlicht', url: 'https://tiles.openfreemap.org/styles/positron', dark: false },
  { id: 'nacht', label: 'Nacht', hint: 'dunkel, leuchtende Zonen', url: 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json', dark: true },
];

const KEY = 'hm-map';
const DEFAULTS: MapSettings = { style: 'klassisch', tilt: false, north: false };

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
  const real = id === 'auto' ? (prefersDark() ? 'nacht' : 'klar') : id;
  return MAP_STYLES.find((s) => s.id === real) ?? MAP_STYLES[0];
}

/** Nächster Stil für den Wechsel-Knopf auf der Karte. */
export function nextStyle(id: MapStyleId): MapStyleId {
  const order: MapStyleId[] = ['klassisch', 'stadt3d', 'klar', 'nacht'];
  const real = resolveStyle(id).id;
  return order[(order.indexOf(real) + 1) % order.length];
}

/** Alle Wahlmöglichkeiten für die Auswahl auf der Karte und im Profil. */
export const MAP_STYLE_OPTIONS: { id: MapStyleId; label: string; hint: string }[] = [
  ...MAP_STYLES.map((s) => ({ id: s.id, label: s.label, hint: s.hint })),
  { id: 'auto', label: 'Automatisch', hint: 'hell am Tag, dunkel im Dunkelmodus' },
];
