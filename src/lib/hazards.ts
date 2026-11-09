/**
 * "Gefahrenstellen vorschlagen": fragt OpenStreetMap (Overpass) im Spielfeld ab und schlägt nur
 * aussergewöhnlich gefährliche Orte als Gefahrenzonen vor: Autobahnen, Bahngleise und grosse
 * Gewässer. Strassen, Schulen, kleine Gewässer, Baustellen usw. werden bewusst nicht vorgeschlagen:
 * dort passt jeder selbst auf sich auf.
 *
 * Wichtig: Unterführungen, Brücken und Tunnel dürfen keine Gefahrenzone sein. Strecken auf Brücken
 * oder in Tunneln werden weggelassen, und wo ein Weg unter oder über den Gleisen/der Autobahn/dem
 * Wasser durchführt, wird die Zone ausgeschnitten.
 */
import { area, bbox, buffer, difference, featureCollection, union } from '@turf/turf';
import type { Position } from 'geojson';
import { bandFromLine, clipTo, type Area } from './geo';
export interface HazardSuggestion {
  key: string;
  name: string;
  type: string;
  shape: Area;
}

interface OsmElement {
  type: 'way' | 'relation';
  id: number;
  tags?: Record<string, string>;
  geometry?: { lat: number; lon: number }[];
}

const ENDPOINT = 'https://overpass-api.de/api/interpreter';

/** Gewässer erst ab dieser Fläche (Quadratmeter) – kleine Teiche und Bäche nicht. */
const MIN_WATER_M2 = 20000;

function classify(tags: Record<string, string>): { type: string; width?: number; label: string } | null {
  // Strecken auf Brücken oder in Tunneln: darunter bzw. darüber kann man gefahrlos durch.
  if (tags.bridge && tags.bridge !== 'no') return null;
  if (tags.tunnel && tags.tunnel !== 'no') return null;
  if (tags.covered === 'yes') return null;
  const hw = tags.highway;
  if (hw === 'motorway' || hw === 'motorway_link') return { type: 'strasse', width: 50, label: tags.ref || tags.name || 'Autobahn' };
  if (tags.railway === 'rail') return { type: 'gleise', width: 24, label: tags.name || 'Bahngleise' };
  if (tags.natural === 'water' || tags.waterway === 'riverbank' || tags.water) return { type: 'gewaesser', label: tags.name || 'Gewässer' };
  if (tags.waterway === 'river') return { type: 'gewaesser', width: 20, label: tags.name || 'Fluss' };
  return null;
}

/** Wege, die unter oder über einer Gefahr hindurchführen (Unterführung, Brücke, Steg). */
function isCrossing(tags: Record<string, string>): boolean {
  if (!tags.highway && tags.railway !== 'platform') return false;
  return (!!tags.tunnel && tags.tunnel !== 'no') || (!!tags.bridge && tags.bridge !== 'no') || tags.covered === 'yes'
    || (tags.layer !== undefined && Number(tags.layer) !== 0);
}

function closed(ring: Position[]): boolean {
  if (ring.length < 4) return false;
  const a = ring[0];
  const b = ring[ring.length - 1];
  return a[0] === b[0] && a[1] === b[1];
}

export async function suggestHazards(field: Area, fetcher: typeof fetch = fetch): Promise<HazardSuggestion[]> {
  const [w, s, e, n] = bbox(field);
  const b = `${s},${w},${n},${e}`;
  const q = `[out:json][timeout:25];(
    way["highway"~"^(motorway|motorway_link)$"](${b});
    way["railway"="rail"]["service"!~"."](${b});
    way["natural"="water"](${b});
    way["waterway"~"^(river|riverbank)$"](${b});
    way["highway"]["tunnel"](${b});
    way["highway"]["bridge"](${b});
    way["highway"]["layer"](${b});
    way["highway"]["covered"="yes"](${b});
  );out geom 800;`;
  const res = await fetcher(ENDPOINT, { method: 'POST', body: new URLSearchParams({ data: q }) });
  if (!res.ok) throw new Error(`Overpass ${res.status}`);
  const json = (await res.json()) as { elements: OsmElement[] };
  // Durchgänge (Unterführungen, Brücken, Stege) als Flächen, die aus den Gefahrenzonen ausgeschnitten werden.
  const gaps: Area[] = [];
  for (const el of json.elements) {
    if (!el.geometry || el.geometry.length < 2 || !el.tags || !isCrossing(el.tags)) continue;
    const coords: Position[] = el.geometry.map((g) => [g.lon, g.lat]);
    gaps.push(bandFromLine(coords, 16));
  }
  const gapArea = gaps.length ? (union(featureCollection(gaps)) as Area | null) ?? (buffer(gaps[0], 0) as Area) : null;
  const out: HazardSuggestion[] = [];
  // Gleiche Strecken (z. B. Gleis-Paare) zusammenfassen: pro Name und Typ ein Vorschlag.
  const byName = new Map<string, HazardSuggestion>();
  for (const el of json.elements) {
    if (!el.geometry || el.geometry.length < 2 || !el.tags) continue;
    const c = classify(el.tags);
    if (!c) continue;
    const coords: Position[] = el.geometry.map((g) => [g.lon, g.lat]);
    let shape: Area;
    if (c.width) shape = bandFromLine(coords, c.width);
    else if (closed(coords)) shape = { type: 'Feature', geometry: { type: 'Polygon', coordinates: [coords] }, properties: {} };
    else continue;
    if (!c.width && c.type === 'gewaesser' && area(shape) < MIN_WATER_M2) continue;
    let clipped = clipTo(shape, field);
    if (!clipped) continue;
    if (gapArea) {
      const cut = difference(featureCollection([clipped, gapArea])) as Area | null;
      if (!cut) continue;
      clipped = cut;
    }
    const k = `${c.type}:${c.label}`;
    const prev = byName.get(k);
    if (prev && c.width) {
      const u = union(featureCollection([prev.shape, clipped])) as Area | null;
      if (u) prev.shape = u;
      continue;
    }
    const sug: HazardSuggestion = { key: `${el.type}${el.id}`, name: c.label, type: c.type, shape: clipped };
    byName.set(k, sug);
    out.push(sug);
  }
  return out.slice(0, 60);
}
