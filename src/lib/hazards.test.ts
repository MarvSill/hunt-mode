import { booleanPointInPolygon, point } from '@turf/turf';
import { describe, expect, it } from 'vitest';
import { circleWithArea } from './geo';
import { suggestHazards } from './hazards';

const field = circleWithArea([8.54, 47.37], 2);
const way = (id: number, tags: Record<string, string>, pts: [number, number][]) => ({
  type: 'way', id, tags, geometry: pts.map(([lon, lat]) => ({ lat, lon })),
});
const square = (lon: number, lat: number, d: number): [number, number][] => [[lon - d, lat - d], [lon + d, lat - d], [lon + d, lat + d], [lon - d, lat + d], [lon - d, lat - d]];

function fakeFetch(elements: unknown[]) {
  return (async () => ({ ok: true, json: async () => ({ elements }) })) as unknown as typeof fetch;
}

describe('Gefahren-Vorschläge', () => {
  it('nur aussergewöhnlich gefährliche Orte, Unterführung bleibt frei', async () => {
    const list = await suggestHazards(field, fakeFetch([
      way(1, { railway: 'rail', name: 'Strecke' }, [[8.53, 47.37], [8.55, 47.37]]),
      // Fussweg unter den Gleisen durch
      way(2, { highway: 'footway', tunnel: 'yes' }, [[8.54, 47.3695], [8.54, 47.3705]]),
      way(3, { amenity: 'school', name: 'Schule' }, square(8.535, 47.372, 0.0005)),
      way(4, { natural: 'water', name: 'Teich' }, square(8.545, 47.372, 0.0002)),
      way(5, { natural: 'water', name: 'See' }, square(8.545, 47.366, 0.002)),
      way(6, { highway: 'motorway', bridge: 'yes', ref: 'A1' }, [[8.53, 47.365], [8.55, 47.365]]),
      way(7, { highway: 'primary', name: 'Hauptstrasse' }, [[8.53, 47.368], [8.55, 47.368]]),
    ]));
    const names = list.map((h) => h.name).sort();
    expect(names).toEqual(['See', 'Strecke']);
    const rail = list.find((h) => h.name === 'Strecke')!;
    // Gleis selbst ist Gefahrenzone, die Unterführung nicht.
    expect(booleanPointInPolygon(point([8.535, 47.37]), rail.shape)).toBe(true);
    expect(booleanPointInPolygon(point([8.54, 47.37]), rail.shape)).toBe(false);
  });
});
