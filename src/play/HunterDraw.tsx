/**
 * Zeichnen auf der Karte, nur für Hunter. Einfach wie auf Papier:
 * - Stift unten rechts antippen: jetzt zeichnet der Finger auf der Karte (freihand), oder setzt einen Punkt,
 *   oder zieht einen Kreis auf. Zum Verschieben der Karte den Stift wieder ausschalten.
 * - Lange auf eine Zeichnung drücken (auch ohne Stift): Menü mit Verschieben (mit dem Finger ziehen), Farbe, Text, Löschen.
 * Alles liegt in der Tabelle hunter_drawings: alle Hunter des Spiels sehen es sofort und jeder kann es ändern.
 * Spieler und Zuschauer sehen es nie.
 */
import maplibregl, { type GeoJSONSource } from 'maplibre-gl';
import { useEffect, useRef, useState } from 'react';
import { circle } from '@turf/turf';
import { db, errorText } from '../lib/supabase';
import { tapFeedback } from '../lib/haptics';
import { t } from '../i18n';

type Kind = 'punkt' | 'strich' | 'kreis' | 'flaeche';
type Tool = 'frei' | 'punkt' | 'kreis';
interface Drawing {
  id: string; kind: Kind; geom: GeoJSON.Point | GeoJSON.LineString | GeoJSON.Polygon;
  radius_m: number | null; color: string; label: string;
}

const COLORS = ['#ff3b30', '#ff9f0a', '#ffd60a', '#30d158', '#0a84ff', '#bf5af2', '#ffffff'];
const SRC = 'hm-draw';
const DRAFT = 'hm-draw-draft';
const HIT_LAYERS = ['hm-draw-fill', 'hm-draw-line', 'hm-draw-point'];
const LONG_MS = 550;

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

function moveGeom(g: Drawing['geom'], dx: number, dy: number): Drawing['geom'] {
  const mv = (p: number[]) => [p[0] + dx, p[1] + dy];
  if (g.type === 'Point') return { type: 'Point', coordinates: mv(g.coordinates) };
  if (g.type === 'LineString') return { type: 'LineString', coordinates: g.coordinates.map(mv) };
  return { type: 'Polygon', coordinates: g.coordinates.map((r) => r.map(mv)) };
}

function centerOf(g: Drawing['geom']): number[] {
  if (g.type === 'Point') return g.coordinates;
  const pts = g.type === 'LineString' ? g.coordinates : g.coordinates[0];
  return [pts.reduce((a, p) => a + p[0], 0) / pts.length, pts.reduce((a, p) => a + p[1], 0) / pts.length];
}

type PointerEv = maplibregl.MapMouseEvent | maplibregl.MapTouchEvent;
const fingers = (e: PointerEv) => ('touches' in e.originalEvent ? (e.originalEvent as TouchEvent).touches.length : 1);

export default function HunterDraw({ map, styleVer, gameId }: { map: maplibregl.Map; styleVer: number; gameId: string }) {
  const [penOn, setPenOn] = useState(false);
  const [tool, setTool] = useState<Tool>('frei');
  const [color, setColor] = useState(COLORS[0]);
  const [items, setItems] = useState<Drawing[]>([]);
  const [draft, setDraft] = useState<{ pts: number[][]; radius?: number } | null>(null);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [moving, setMoving] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const labels = useRef<maplibregl.Marker[]>([]);
  const st = useRef({ penOn, tool, color, items, moving });
  st.current = { penOn, tool, color, items, moving };

  // Laden und live halten.
  useEffect(() => {
    let alive = true;
    const load = () => void db().from('hunter_drawings').select('id,kind,geom,radius_m,color,label').eq('game_id', gameId).order('created_at')
      .then(({ data }) => { if (alive && data && !st.current.moving) setItems(data as Drawing[]); });
    load();
    const ch = db().channel(`draw:${gameId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'hunter_drawings', filter: `game_id=eq.${gameId}` }, load)
      .subscribe();
    const poll = setInterval(load, 15000);
    return () => { alive = false; clearInterval(poll); void db().removeChannel(ch); };
  }, [gameId]);

  // Ebenen (auch nach einem Wechsel des Kartenstils).
  useEffect(() => {
    const m = map;
    const empty: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
    if (!m.getSource(SRC)) m.addSource(SRC, { type: 'geojson', data: empty });
    if (!m.getSource(DRAFT)) m.addSource(DRAFT, { type: 'geojson', data: empty });
    if (!m.getLayer('hm-draw-fill')) m.addLayer({ id: 'hm-draw-fill', type: 'fill', source: SRC, filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.18 } });
    if (!m.getLayer('hm-draw-line')) m.addLayer({ id: 'hm-draw-line', type: 'line', source: SRC, filter: ['!=', ['geometry-type'], 'Point'], layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': ['case', ['==', ['get', 'sel'], 1], 7, 4] } });
    if (!m.getLayer('hm-draw-point')) m.addLayer({ id: 'hm-draw-point', type: 'circle', source: SRC, filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-color': ['get', 'color'], 'circle-radius': ['case', ['==', ['get', 'sel'], 1], 12, 9], 'circle-stroke-color': '#fff', 'circle-stroke-width': 2.5 } });
    if (!m.getLayer('hm-draw-draft')) m.addLayer({ id: 'hm-draw-draft', type: 'line', source: DRAFT, layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': 4, 'line-opacity': 0.8 } });
  }, [map, styleVer]);

  // Zeichnungen und Beschriftungen anzeigen.
  useEffect(() => {
    (map.getSource(SRC) as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: items.map((d) => asFeature(d, d.id === menu?.id || d.id === moving)) });
    for (const mk of labels.current) mk.remove();
    labels.current = items.filter((d) => d.label).map((d) => {
      const el = document.createElement('div');
      el.className = 'draw-label';
      el.textContent = d.label;
      el.style.borderColor = d.color;
      return new maplibregl.Marker({ element: el, anchor: 'bottom', offset: [0, d.kind === 'punkt' ? -12 : 0] }).setLngLat(centerOf(d.geom) as [number, number]).addTo(map);
    });
  }, [items, menu, moving, map, styleVer]);
  useEffect(() => () => { for (const mk of labels.current) mk.remove(); }, []);

  // Entwurf, solange der Finger zeichnet.
  useEffect(() => {
    const feats: GeoJSON.Feature[] = [];
    if (draft?.radius && draft.pts[0]) feats.push({ type: 'Feature', geometry: circle(draft.pts[0], draft.radius / 1000, { steps: 64, units: 'kilometers' }).geometry, properties: { color } });
    else if (draft && draft.pts.length > 1) feats.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: draft.pts }, properties: { color } });
    (map.getSource(DRAFT) as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: feats.map((f) => ({ ...f, geometry: f.geometry.type === 'Polygon' ? { type: 'LineString', coordinates: (f.geometry as GeoJSON.Polygon).coordinates[0] } : f.geometry })) });
  }, [draft, color, map, styleVer]);

  // Karte mit einem Finger verschieben nur, wenn weder gezeichnet noch verschoben wird.
  useEffect(() => {
    if (penOn || moving) map.dragPan.disable();
    else map.dragPan.enable();
    map.getCanvas().style.cursor = penOn || moving ? 'crosshair' : '';
    return () => { map.dragPan.enable(); map.getCanvas().style.cursor = ''; };
  }, [penOn, moving, map]);

  async function insert(row: { kind: Kind; geom: Drawing['geom']; radius_m?: number }) {
    setErr(null);
    const { error } = await db().from('hunter_drawings').insert({ game_id: gameId, color: st.current.color, ...row });
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
    setMenu(null);
    const { error } = await db().from('hunter_drawings').delete().in('id', ids);
    if (error) setErr(errorText(error));
  }

  // Finger auf der Karte: zeichnen, verschieben, oder lange drücken für das Menü.
  useEffect(() => {
    let down: { p: number[]; px: maplibregl.Point; moved: boolean } | null = null;
    let stroke: number[][] = [];
    let lastPx: maplibregl.Point | null = null;
    let longTimer: ReturnType<typeof setTimeout> | null = null;
    let moveFrom: { start: number[]; orig: Drawing['geom'] } | null = null;
    const clearLong = () => { if (longTimer) clearTimeout(longTimer); longTimer = null; };

    const hitAt = (px: maplibregl.Point) => {
      const box: [maplibregl.PointLike, maplibregl.PointLike] = [[px.x - 14, px.y - 14], [px.x + 14, px.y + 14]];
      const f = map.queryRenderedFeatures(box, { layers: HIT_LAYERS.filter((l) => map.getLayer(l)) })[0];
      return (f?.properties?.id as string | undefined) ?? null;
    };

    const onDown = (e: PointerEv) => {
      if (fingers(e) > 1) { down = null; stroke = []; setDraft(null); clearLong(); return; }
      const p = [e.lngLat.lng, e.lngLat.lat];
      down = { p, px: e.point, moved: false };
      lastPx = e.point;
      const s = st.current;
      if (s.moving) {
        const d = s.items.find((x) => x.id === s.moving);
        if (d) moveFrom = { start: p, orig: d.geom };
        return;
      }
      // Lange drücken auf eine Zeichnung: Menü.
      clearLong();
      longTimer = setTimeout(() => {
        if (!down || down.moved) return;
        const id = hitAt(down.px);
        if (!id) return;
        stroke = [];
        setDraft(null);
        tapFeedback();
        setMenu({ id, x: down.px.x, y: down.px.y });
        setLabel(st.current.items.find((x) => x.id === id)?.label ?? '');
        down = null;
      }, LONG_MS);
      if (s.penOn) {
        if (s.tool === 'frei') { stroke = [p]; setDraft({ pts: [p] }); }
        if (s.tool === 'kreis') setDraft({ pts: [p], radius: 0 });
      }
    };

    const onMove = (e: PointerEv) => {
      if (!down) return;
      if (fingers(e) > 1) { down = null; stroke = []; setDraft(null); clearLong(); return; }
      const p = [e.lngLat.lng, e.lngLat.lat];
      if (!down.moved && Math.hypot(e.point.x - down.px.x, e.point.y - down.px.y) > 8) { down.moved = true; clearLong(); }
      const s = st.current;
      if (s.moving && moveFrom) {
        const dx = p[0] - moveFrom.start[0], dy = p[1] - moveFrom.start[1];
        const geom = moveGeom(moveFrom.orig, dx, dy);
        setItems((list) => list.map((d) => (d.id === s.moving ? { ...d, geom } : d)));
        e.originalEvent.preventDefault?.();
        return;
      }
      if (!s.penOn) return;
      e.originalEvent.preventDefault?.();
      if (s.tool === 'frei' && lastPx && Math.hypot(e.point.x - lastPx.x, e.point.y - lastPx.y) >= 4) {
        stroke.push(p);
        lastPx = e.point;
        setDraft({ pts: [...stroke] });
      }
      if (s.tool === 'kreis') setDraft({ pts: [down.p], radius: distM(down.p, p) });
    };

    const onUp = (e: PointerEv) => {
      clearLong();
      const s = st.current;
      if (s.moving && moveFrom) {
        const d = s.items.find((x) => x.id === s.moving);
        if (d) void update(d.id, { geom: d.geom });
        moveFrom = null;
        setMoving(null);
        down = null;
        return;
      }
      if (!down || !s.penOn) { down = null; return; }
      const p = [e.lngLat.lng, e.lngLat.lat];
      if (s.tool === 'frei' && stroke.length >= 2) {
        // Höchstens 400 Punkte speichern (lange Striche werden ausgedünnt).
        const step = Math.ceil(stroke.length / 400);
        const pts = stroke.filter((_, i) => i % step === 0 || i === stroke.length - 1);
        void insert({ kind: 'strich', geom: { type: 'LineString', coordinates: pts } });
      }
      if (s.tool === 'punkt' && !down.moved) void insert({ kind: 'punkt', geom: { type: 'Point', coordinates: p } });
      if (s.tool === 'kreis') {
        const r = Math.round(distM(down.p, p));
        if (r >= 10) void insert({ kind: 'kreis', geom: { type: 'Point', coordinates: down.p }, radius_m: r });
      }
      stroke = [];
      setDraft(null);
      down = null;
    };

    map.on('touchstart', onDown); map.on('mousedown', onDown);
    map.on('touchmove', onMove); map.on('mousemove', onMove);
    map.on('touchend', onUp); map.on('mouseup', onUp); map.on('touchcancel', onUp);
    return () => {
      clearLong();
      map.off('touchstart', onDown); map.off('mousedown', onDown);
      map.off('touchmove', onMove); map.off('mousemove', onMove);
      map.off('touchend', onUp); map.off('mouseup', onUp); map.off('touchcancel', onUp);
    };
  }, [map]); // eslint-disable-line react-hooks/exhaustive-deps

  const selected = menu ? items.find((d) => d.id === menu.id) ?? null : null;
  const box = map.getContainer().getBoundingClientRect();
  const menuLeft = menu ? Math.min(Math.max(8, menu.x - 130), Math.max(8, box.width - 270)) : 0;
  const menuTop = menu ? (menu.y > box.height / 2 ? Math.max(8, menu.y - 210) : menu.y + 20) : 0;

  return (
    <>
      <button type="button" className={`draw-pen${penOn ? ' on' : ''}`} aria-pressed={penOn} aria-label={penOn ? t('Zeichnen beenden') : t('Zeichnen')}
        onClick={() => { setPenOn(!penOn); setMenu(null); setMoving(null); }}>
        {penOn ? '✓' : '✏️'}
      </button>

      {penOn && (
        <div className="draw-bar" onClick={(e) => e.stopPropagation()}>
          <div className="row" style={{ gap: 4, flexWrap: 'nowrap' }}>
            {([['frei', '✍️', t('Zeichnen')], ['punkt', '📍', t('Punkt')], ['kreis', '⭕', t('Kreis')]] as [Tool, string, string][]).map(([id, ic, name]) => (
              <button key={id} type="button" className={`draw-tool${tool === id ? ' on' : ''}`} onClick={() => setTool(id)}><span>{ic}</span><small>{name}</small></button>
            ))}
            {items.length > 0 && (
              <button type="button" className="draw-tool" onClick={() => { if (window.confirm(t('Alle Zeichnungen für alle Hunter löschen?'))) void remove(items.map((d) => d.id)); }}>
                <span>🗑️</span><small>{t('Alles')}</small>
              </button>
            )}
          </div>
          <div className="draw-colors">
            {COLORS.map((c) => <button key={c} type="button" className={`draw-color${color === c ? ' on' : ''}`} style={{ background: c }} aria-label={t('Farbe')} onClick={() => setColor(c)} />)}
          </div>
          <div className="tiny muted">
            {tool === 'frei' ? t('Mit dem Finger auf die Karte zeichnen.') : tool === 'punkt' ? t('Auf die Karte tippen.') : t('Von der Mitte aus mit dem Finger aufziehen.')}
            {' '}{t('Karte bewegen: Stift mit ✓ ausschalten. Lange drücken = ändern.')}
          </div>
        </div>
      )}

      {moving && <div className="draw-hint">✋ {t('Mit dem Finger an die neue Stelle ziehen.')}</div>}

      {menu && selected && (
        <div className="draw-menu" style={{ left: menuLeft, top: menuTop }} onClick={(e) => e.stopPropagation()}>
          <div className="row" style={{ gap: 6 }}>
            <button type="button" className="small" onClick={() => { setMoving(menu.id); setMenu(null); }}>✋ {t('Verschieben')}</button>
            <button type="button" className="small danger" onClick={() => void remove([menu.id])}>🗑️ {t('Löschen')}</button>
            <button type="button" className="small ghost" aria-label={t('Schliessen')} onClick={() => setMenu(null)}>✕</button>
          </div>
          <div className="draw-colors">
            {COLORS.map((c) => <button key={c} type="button" className={`draw-color${selected.color === c ? ' on' : ''}`} style={{ background: c }} aria-label={t('Farbe')} onClick={() => void update(selected.id, { color: c })} />)}
          </div>
          <form className="row" style={{ gap: 6, flexWrap: 'nowrap' }} onSubmit={(e) => { e.preventDefault(); void update(selected.id, { label: label.trim() }); setMenu(null); }}>
            <input value={label} maxLength={40} placeholder={t('Text (z. B. „gesehen 14:20“)')} aria-label={t('Text')} onChange={(e) => setLabel(e.target.value)} style={{ flex: 1, minWidth: 0 }} />
            <button type="submit" className="small">💬</button>
          </form>
        </div>
      )}
      {err && <div className="draw-hint red">{err}</div>}
    </>
  );
}
