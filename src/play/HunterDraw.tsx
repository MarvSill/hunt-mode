/**
 * Zeichnen auf der Karte, nur für Hunter: Punkte, Striche, Kreise und Flächen, mit Farbe und Text.
 * Alles liegt in der Tabelle hunter_drawings: alle Hunter des Spiels sehen es sofort (Live-Verbindung) und
 * jeder Hunter kann es verschieben, umfärben, beschriften oder löschen. Spieler sehen es nie.
 * Öffnen über den kleinen Stift am Kartenrand.
 */
import maplibregl, { type GeoJSONSource } from 'maplibre-gl';
import { useEffect, useRef, useState } from 'react';
import { circle } from '@turf/turf';
import { db, errorText } from '../lib/supabase';
import { t } from '../i18n';

type Kind = 'punkt' | 'strich' | 'kreis' | 'flaeche';
type Mode = Kind | 'auswahl' | 'verschieben';
interface Drawing {
  id: string; kind: Kind; geom: GeoJSON.Point | GeoJSON.LineString | GeoJSON.Polygon;
  radius_m: number | null; color: string; label: string;
}

const COLORS = ['#ff3b30', '#ff9f0a', '#ffd60a', '#30d158', '#0a84ff', '#bf5af2', '#ffffff'];
const SRC = 'hm-draw';
const DRAFT = 'hm-draw-draft';
const LAYERS = ['hm-draw-fill', 'hm-draw-line', 'hm-draw-point', 'hm-draw-sel'];

function asFeature(d: Drawing, selected: boolean): GeoJSON.Feature {
  const geometry = d.kind === 'kreis' && d.geom.type === 'Point'
    ? circle((d.geom as GeoJSON.Point).coordinates, (d.radius_m ?? 50) / 1000, { steps: 64, units: 'kilometers' }).geometry
    : d.geom;
  return { type: 'Feature', geometry, properties: { id: d.id, kind: d.kind, color: d.color, sel: selected ? 1 : 0 } };
}

function distM(a: number[], b: number[]) {
  const R = 6371000, toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR, dLng = (b[0] - a[0]) * toR;
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * toR) * Math.cos(b[1] * toR) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

/** Alle Koordinaten einer Geometrie um (dx, dy) verschieben. */
function moveGeom(g: Drawing['geom'], dx: number, dy: number): Drawing['geom'] {
  const mv = (p: number[]) => [p[0] + dx, p[1] + dy];
  if (g.type === 'Point') return { type: 'Point', coordinates: mv(g.coordinates) };
  if (g.type === 'LineString') return { type: 'LineString', coordinates: g.coordinates.map(mv) };
  return { type: 'Polygon', coordinates: g.coordinates.map((r) => r.map(mv)) };
}

function centerOf(g: Drawing['geom']): number[] {
  if (g.type === 'Point') return g.coordinates;
  const pts = g.type === 'LineString' ? g.coordinates : g.coordinates[0];
  const n = pts.length;
  return [pts.reduce((a, p) => a + p[0], 0) / n, pts.reduce((a, p) => a + p[1], 0) / n];
}

export default function HunterDraw({ map, styleVer, gameId }: { map: maplibregl.Map; styleVer: number; gameId: string }) {
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<Drawing[]>([]);
  const [mode, setMode] = useState<Mode>('auswahl');
  const [color, setColor] = useState(COLORS[0]);
  const [draft, setDraft] = useState<number[][]>([]);
  const [sel, setSel] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const labels = useRef<maplibregl.Marker[]>([]);
  const state = useRef({ mode, draft, sel, color, items });
  state.current = { mode, draft, sel, color, items };

  // Laden und live halten (jede Änderung eines Hunters lädt die Liste neu).
  useEffect(() => {
    let alive = true;
    const load = () => void db().from('hunter_drawings').select('id,kind,geom,radius_m,color,label').eq('game_id', gameId).order('created_at')
      .then(({ data }) => { if (alive && data) setItems(data as Drawing[]); });
    load();
    const ch = db().channel(`draw:${gameId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'hunter_drawings', filter: `game_id=eq.${gameId}` }, load)
      .subscribe();
    const poll = setInterval(load, 15000);
    return () => { alive = false; clearInterval(poll); void db().removeChannel(ch); };
  }, [gameId]);

  // Ebenen anlegen (auch nach einem Wechsel des Kartenstils).
  useEffect(() => {
    const m = map;
    if (!m.getSource(SRC)) m.addSource(SRC, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    if (!m.getSource(DRAFT)) m.addSource(DRAFT, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    if (!m.getLayer('hm-draw-fill')) m.addLayer({ id: 'hm-draw-fill', type: 'fill', source: SRC, filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.18 } });
    if (!m.getLayer('hm-draw-line')) m.addLayer({ id: 'hm-draw-line', type: 'line', source: SRC, filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': ['get', 'color'], 'line-width': ['case', ['==', ['get', 'sel'], 1], 6, 4] } });
    if (!m.getLayer('hm-draw-point')) m.addLayer({ id: 'hm-draw-point', type: 'circle', source: SRC, filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-color': ['get', 'color'], 'circle-radius': ['case', ['==', ['get', 'sel'], 1], 11, 8], 'circle-stroke-color': '#fff', 'circle-stroke-width': 2.5 } });
    if (!m.getLayer('hm-draw-sel')) m.addLayer({ id: 'hm-draw-sel', type: 'line', source: SRC, filter: ['==', ['get', 'sel'], 1], paint: { 'line-color': '#ffffff', 'line-width': 2, 'line-dasharray': [2, 2] } });
    if (!m.getLayer('hm-draw-draft-line')) m.addLayer({ id: 'hm-draw-draft-line', type: 'line', source: DRAFT, paint: { 'line-color': '#ffffff', 'line-width': 3, 'line-dasharray': [1.5, 1.5] } });
    if (!m.getLayer('hm-draw-draft-pt')) m.addLayer({ id: 'hm-draw-draft-pt', type: 'circle', source: DRAFT, filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-color': '#ffffff', 'circle-radius': 5 } });
  }, [map, styleVer]);

  // Zeichnungen und Beschriftungen anzeigen.
  useEffect(() => {
    (map.getSource(SRC) as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: items.map((d) => asFeature(d, d.id === sel)) });
    for (const mk of labels.current) mk.remove();
    labels.current = items.filter((d) => d.label).map((d) => {
      const el = document.createElement('div');
      el.className = 'draw-label';
      el.textContent = d.label;
      el.style.borderColor = d.color;
      return new maplibregl.Marker({ element: el, anchor: 'bottom', offset: [0, d.kind === 'punkt' ? -12 : 0] }).setLngLat(centerOf(d.geom) as [number, number]).addTo(map);
    });
  }, [items, sel, map, styleVer]);
  useEffect(() => () => { for (const mk of labels.current) mk.remove(); }, []);

  // Entwurf (Strich, Fläche, Kreis in Arbeit)
  useEffect(() => {
    const feats: GeoJSON.Feature[] = draft.map((p) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: p }, properties: {} }));
    if (draft.length > 1) feats.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: mode === 'flaeche' ? [...draft, draft[0]] : draft }, properties: {} });
    (map.getSource(DRAFT) as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: feats });
  }, [draft, mode, map, styleVer]);

  async function save(row: Partial<Drawing> & { kind: Kind; geom: Drawing['geom'] }) {
    setErr(null);
    const { error } = await db().from('hunter_drawings').insert({ game_id: gameId, color: state.current.color, ...row });
    if (error) setErr(errorText(error));
  }
  async function update(id: string, patch: Partial<Drawing>) {
    setErr(null);
    setItems((list) => list.map((d) => (d.id === id ? { ...d, ...patch } : d)));
    const { error } = await db().from('hunter_drawings').update(patch).eq('id', id);
    if (error) setErr(errorText(error));
  }
  async function remove(ids: string[]) {
    setErr(null);
    setItems((list) => list.filter((d) => !ids.includes(d.id)));
    setSel(null);
    const { error } = await db().from('hunter_drawings').delete().in('id', ids);
    if (error) setErr(errorText(error));
  }

  // Tippen auf die Karte, solange das Werkzeug offen ist.
  useEffect(() => {
    if (!open) return;
    const onClick = (e: maplibregl.MapMouseEvent) => {
      const p = [e.lngLat.lng, e.lngLat.lat];
      const { mode: md, draft: dr, sel: sl, items: list } = state.current;
      if (md === 'punkt') void save({ kind: 'punkt', geom: { type: 'Point', coordinates: p } });
      else if (md === 'strich' || md === 'flaeche') setDraft([...dr, p]);
      else if (md === 'kreis') {
        if (dr.length === 0) setDraft([p]);
        else { void save({ kind: 'kreis', geom: { type: 'Point', coordinates: dr[0] }, radius_m: Math.max(10, Math.round(distM(dr[0], p))) }); setDraft([]); }
      } else if (md === 'verschieben' && sl) {
        const d = list.find((x) => x.id === sl);
        if (d) {
          const c = centerOf(d.geom);
          void update(d.id, { geom: moveGeom(d.geom, p[0] - c[0], p[1] - c[1]) });
        }
        setMode('auswahl');
      } else {
        const box: [maplibregl.PointLike, maplibregl.PointLike] = [[e.point.x - 12, e.point.y - 12], [e.point.x + 12, e.point.y + 12]];
        const hit = map.queryRenderedFeatures(box, { layers: LAYERS.filter((l) => map.getLayer(l)) })[0];
        const id = (hit?.properties?.id as string | undefined) ?? null;
        setSel(id);
        setLabel(list.find((x) => x.id === id)?.label ?? '');
      }
    };
    map.on('click', onClick);
    map.getCanvas().style.cursor = 'crosshair';
    return () => { map.off('click', onClick); map.getCanvas().style.cursor = ''; };
  }, [open, map]); // eslint-disable-line react-hooks/exhaustive-deps

  function pick(next: Mode) {
    setMode(next);
    setDraft([]);
    if (next !== 'auswahl' && next !== 'verschieben') setSel(null);
  }
  function finishDraft() {
    if (mode === 'strich' && draft.length >= 2) void save({ kind: 'strich', geom: { type: 'LineString', coordinates: draft } });
    if (mode === 'flaeche' && draft.length >= 3) void save({ kind: 'flaeche', geom: { type: 'Polygon', coordinates: [[...draft, draft[0]]] } });
    setDraft([]);
  }

  const selected = items.find((d) => d.id === sel) ?? null;
  const hint = mode === 'punkt' ? t('Tippe auf die Karte, um einen Punkt zu setzen.')
    : mode === 'strich' ? t('Tippe die Punkte des Strichs nacheinander, dann „Fertig“.')
    : mode === 'flaeche' ? t('Tippe die Ecken der Fläche, dann „Fertig“.')
    : mode === 'kreis' ? (draft.length ? t('Tippe so weit weg, wie gross der Kreis sein soll.') : t('Tippe die Mitte des Kreises.'))
    : mode === 'verschieben' ? t('Tippe, wohin es soll.')
    : selected ? '' : t('Tippe eine Zeichnung an, um sie zu ändern oder zu löschen.');

  return (
    <>
      <button type="button" className={`draw-pen${open ? ' on' : ''}`} aria-label={open ? t('Zeichnen beenden') : t('Zeichnen')} onClick={() => { setOpen(!open); pick('auswahl'); setSel(null); }}>
        {open ? '✕' : '✏️'}
      </button>
      {open && (
        <div className="draw-panel" onClick={(e) => e.stopPropagation()}>
          <div className="draw-tools">
            {([['auswahl', '👆', t('Auswählen')], ['punkt', '📍', t('Punkt')], ['strich', '〰️', t('Strich')], ['kreis', '⭕', t('Kreis')], ['flaeche', '⬠', t('Fläche')]] as [Mode, string, string][]).map(([id, ic, name]) => (
              <button key={id} type="button" className={`draw-tool${mode === id ? ' on' : ''}`} onClick={() => pick(id)}><span>{ic}</span><small>{name}</small></button>
            ))}
          </div>
          <div className="draw-colors">
            {COLORS.map((c) => (
              <button key={c} type="button" className={`draw-color${color === c ? ' on' : ''}`} style={{ background: c }} aria-label={t('Farbe')}
                onClick={() => { setColor(c); if (selected) void update(selected.id, { color: c }); }} />
            ))}
          </div>
          {hint && <div className="small muted">{hint}</div>}
          {(mode === 'strich' || mode === 'flaeche') && draft.length > 0 && (
            <div className="row">
              <button type="button" className="small" onClick={() => setDraft(draft.slice(0, -1))}>↩️ {t('Zurück')}</button>
              <button type="button" className="small primary" disabled={draft.length < (mode === 'strich' ? 2 : 3)} onClick={finishDraft}>✓ {t('Fertig')}</button>
            </div>
          )}
          {selected && mode === 'auswahl' && (
            <div className="stack" style={{ gap: 6 }}>
              <div className="row" style={{ gap: 6 }}>
                <input value={label} maxLength={40} placeholder={t('Text (z. B. „gesehen 14:20“)')} aria-label={t('Text')} onChange={(e) => setLabel(e.target.value)} style={{ flex: 1, minWidth: 0 }} />
                <button type="button" className="small" onClick={() => void update(selected.id, { label: label.trim() })}>💬 {t('Text')}</button>
              </div>
              <div className="row" style={{ gap: 6 }}>
                <button type="button" className="small" onClick={() => setMode('verschieben')}>✋ {t('Verschieben')}</button>
                <button type="button" className="small danger" onClick={() => void remove([selected.id])}>🗑️ {t('Löschen')}</button>
              </div>
            </div>
          )}
          {items.length > 0 && mode === 'auswahl' && !selected && (
            <button type="button" className="small ghost" onClick={() => { if (window.confirm(t('Alle Zeichnungen für alle Hunter löschen?'))) void remove(items.map((d) => d.id)); }}>🗑️ {t('Alles löschen')} ({items.length})</button>
          )}
          {err && <div className="small red">{err}</div>}
        </div>
      )}
    </>
  );
}
