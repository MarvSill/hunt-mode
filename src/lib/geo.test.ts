import { describe, expect, it } from 'vitest';
import type { MapFeature } from './engine';
import { recommendedFieldKm2, rectWithArea, areaKm2, bandFromLine, checkMap, exitPlaceOk, nearestExitPlace, circleWithArea, middleOf, pointAtDistance, pointInside, spreadPoints, clipTo, fieldOfPhase, outsideShare, shrinkArea, type Area } from './geo';

const square = (x: number, y: number, d: number): Area => ({
  type: 'Feature', properties: {},
  geometry: { type: 'Polygon', coordinates: [[[x, y], [x + d, y], [x + d, y + d], [x, y + d], [x, y]]] },
});
const zone = (kind: MapFeature['properties']['kind'], a: Area, extra: Partial<MapFeature['properties']> = {}): MapFeature =>
  ({ type: 'Feature', geometry: a.geometry, properties: { kind, ...extra } }) as MapFeature;
const point = (kind: MapFeature['properties']['kind'], x: number, y: number): MapFeature =>
  ({ type: 'Feature', geometry: { type: 'Point', coordinates: [x, y] }, properties: { kind } }) as MapFeature;

describe('geo', () => {
  const field = square(8.5, 47.3, 0.02);

  it('schneidet Zonen aufs Spielfeld zu', () => {
    const half = square(8.51, 47.31, 0.02);
    expect(outsideShare(half, field)).toBeGreaterThan(0.7);
    const c = clipTo(half, field)!;
    expect(outsideShare(c, field)).toBeLessThan(0.001);
    expect(clipTo(square(9, 48, 0.01), field)).toBeNull();
  });

  it('verkleinert wie die Engine (Fläche je Schritt)', () => {
    const a = areaKm2(field);
    const s = shrinkArea(field, [8.51, 47.31], 40, 1);
    expect(areaKm2(s) / a).toBeCloseTo(0.6, 2);
    expect(areaKm2(shrinkArea(field, [8.51, 47.31], 40, 2)) / a).toBeCloseTo(0.36, 2);
  });

  it('macht aus einer Linie ein Band', () => {
    const b = bandFromLine([[8.5, 47.3], [8.51, 47.3]], 30);
    expect(areaKm2(b)).toBeGreaterThan(0.02);
    expect(areaKm2(b)).toBeLessThan(0.03);
  });

  it('wählt das Spielfeld der Phase', () => {
    const f = [zone('spielfeld', field), zone('spielfeld', square(8.505, 47.305, 0.01), { day_index: 2 })];
    expect(areaKm2(fieldOfPhase(f, 1))).toBeCloseTo(areaKm2(field), 3);
    expect(areaKm2(fieldOfPhase(f, 3))).toBeLessThan(areaKm2(field) / 2);
  });

  it('prüft die Karte', () => {
    const base = { exitEnabled: true, phases: 1, autoShrink: false, manualShrink: false, recommendedKm2: 1 };
    expect(checkMap({ ...base, features: [] }).some((i) => i.text.includes('Spielfeld'))).toBe(true);
    const ok = [zone('spielfeld', field), point('treffpunkt', 8.51, 47.31), point('exit', 8.515, 47.315), point('exit', 8.505, 47.315), point('exit', 8.515, 47.305), point('exit', 8.505, 47.305)];
    expect(checkMap({ ...base, features: ok }).filter((i) => i.level === 'error')).toEqual([]);
    const bad = [...ok, zone('sperrzone', square(8.509, 47.309, 0.002))];
    expect(checkMap({ ...base, features: bad }).some((i) => i.text.includes('Gefahrenzone'))).toBe(true);
    const out = [zone('spielfeld', field), point('treffpunkt', 9, 48), point('exit', 8.51, 47.31)];
    expect(checkMap({ ...base, features: out }).some((i) => i.text.includes('Startpunkt liegt ausserhalb'))).toBe(true);
    expect(checkMap({ ...base, features: out }).some((i) => i.text.includes('mindestens 4 Fluchtpunkt'))).toBe(true);
  });

  it('erstellt Spielfeld und Punkte automatisch', () => {
    const f = circleWithArea([8.54, 47.37], 1);
    expect(areaKm2(f)).toBeCloseTo(1, 1);
    const m = middleOf(f);
    expect(pointInside(m, f)).toBe(true);
    const hq = pointAtDistance(m, 300, f);
    expect(pointInside(hq, f)).toBe(true);
    const ex = spreadPoints(f, 3, [m]);
    expect(ex).toHaveLength(3);
    for (const p of ex) expect(pointInside(p, f)).toBe(true);
  });
});

describe('Fluchtpunkt automatisch verschieben', () => {
  const sq = (x0: number, y0: number, x1: number, y1: number): Area => ({ type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]] } });
  const inner = sq(8.53, 47.37, 8.55, 47.38);
  const danger = sq(8.538, 47.37, 8.542, 47.38);

  it('verschiebt aus der Gefahrenzone an die nächste freie Stelle', () => {
    const to = nearestExitPlace([8.54, 47.375], inner, danger)!;
    expect(exitPlaceOk(to, inner, danger)).toBe(true);
    expect(Math.abs(to[0] - 8.54)).toBeLessThan(0.004);
  });

  it('holt einen Punkt von ausserhalb in die kleinste Zone', () => {
    const to = nearestExitPlace([8.56, 47.375], inner, null)!;
    expect(exitPlaceOk(to, inner, null)).toBe(true);
    expect(to[0]).toBeGreaterThan(8.545);
  });

  it('lässt richtige Punkte gelten', () => {
    expect(exitPlaceOk([8.535, 47.375], inner, danger)).toBe(true);
  });

  it('empfiehlt die Fläche nach der Formel', () => {
    // 4 min Abstand, 5 Pings (20 min), 2 Personen, zu Fuss: genau 2 km²
    expect(recommendedFieldKm2({ pingMinutes: 4, durationMinutes: 20, people: 2, motorized: false, bikes: false })).toBeCloseTo(2, 5);
    // Viermal so viele Pings ergeben die doppelte Fläche
    expect(recommendedFieldKm2({ pingMinutes: 4, durationMinutes: 80, people: 2, motorized: false, bikes: false })).toBeCloseTo(4, 5);
    // ÖV erlaubt: dreimal so gross
    expect(recommendedFieldKm2({ pingMinutes: 4, durationMinutes: 20, people: 2, motorized: true, bikes: true })).toBeCloseTo(6, 5);
    expect(areaKm2(rectWithArea([8.5, 47.3], 3))).toBeCloseTo(3, 1);
  });
});
