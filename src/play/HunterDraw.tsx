/**
 * Zeichnen auf der Karte, nur für Hunter. Einfach wie auf Papier:
 * - Stift unten rechts öffnet die Werkzeuge. Am Anfang ist keines gewählt: die Karte bewegt sich normal.
 * - Werkzeug antippen = aktiv, nochmals antippen = wieder aus (dann bewegt sich die Karte wieder).
 *   ✍️ Zeichnen: Strich mit dem Finger. ⬠ Form: mit dem Finger umfahren, wird zur Fläche. 📍 Punkt: antippen.
 *   🧽 Radiergummi: mit dem Finger über Zeichnungen fahren, sie verschwinden.
 * - Ohne Werkzeug: Finger kurz auf eine Zeichnung halten und gleich ziehen = verschieben.
 *   Kurz antippen = kleines Menü mit Farbe, Text und Löschen.
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
type Tool = 'frei' | 'form' | 'punkt' | 'radier';
interface Drawing {
  id: string; kind: Kind; geom: GeoJSON.Point | GeoJSON.LineString | GeoJSON.Polygon;
  radius_m: number | null; color: string; label: string;
}

const COLORS = ['#ff3b30', '#ff9f0a', '#ffd60a', '#30d158', '#0a84ff', '#bf5af2', '#ffffff'];
const SRC = 'hm-draw';
const DRAFT = 'hm-draw-draft';
const HIT_LAYERS = ['hm-draw-fill', 'hm-draw-line', 'hm-draw-point'];
const HOLD_MS = 350;

function asFeature(d: Drawing, selected: boolean): GeoJSON.Feature {
  // Alte Kreise (früheres Werkzeug) werden weiter als Kreis gezeigt.
  const geometry = d.kind === 'kreis' && d.geom.type === 'Point'
    ? circle((d.geom as GeoJSON.Point).coordinates, (d.radius_m ?? 50) / 1000, { steps: 64, units: 'kilometers' }).geometry
    : d.geom;
  return { type: 'Feature', geometry, properties: { id: d.id, kind: d.kind, color: d.color, sel: selected ? 1 : 0 } };
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

/** Lange Striche ausdünnen (höchstens n Punkte). */
const thin = (pts: number[][], n = 400) => {
  const step = Math.ceil(pts.length / n);
  return pts.filter((_, i) => i % step === 0 || i === pts.length - 1);
};

type PointerEv = maplibregl.MapMouseEvent | maplibregl.MapTouchEvent;
const fingers = (e: PointerEv) => ('touches' in e.originalEvent ? (e.originalEvent as TouchEvent).touches.length : 1);

export default function HunterDraw({ map, styleVer, gameId }: { map: maplibregl.Map; styleVer: number; gameId: string }) {
  const [open, setOpen] = useState(false);
  const [tool, setTool] = useState<Tool | null>(null);
  const [color, setColor] = useState(COLORS[0]);
  const [items, setItems] = useState<Drawing[]>([]);
  const [draft, setDraft] = useState<number[][] | null>(null);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [moving, setMoving] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const labels = useRef<maplibregl.Marker[]>([]);
  const st = useRef({ open, tool, color, items, moving });
  st.current = { open, tool, color, items, moving };

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
    if (!m.getLayer('hm-draw-fill')) m.addLayer({ id: 'hm-draw-fill', type: 'fill', source: SRC, filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.2 } });
    if (!m.getLayer('hm-draw-line')) m.addLayer({ id: 'hm-draw-line', type: 'line', source: SRC, filter: ['!=', ['geometry-type'], 'Point'], layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': ['case', ['==', ['get', 'sel'], 1], 7, 4] } });
    if (!m.getLayer('hm-draw-point')) m.addLayer({ id: 'hm-draw-point', type: 'circle', source: SRC, filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-color': ['get', 'color'], 'circle-radius': ['case', ['==', ['get', 'sel'], 1], 13, 9], 'circle-stroke-color': '#fff', 'circle-stroke-width': 2.5 } });
    if (!m.getLayer('hm-draw-draft')) m.addLayer({ id: 'hm-draw-draft', type: 'line', source: DRAFT, layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': 4, 'line-opacity': 0.85 } });
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

  // Entwurf, solange der Finger zeichnet (bei der Form schon geschlossen).
  useEffect(() => {
    const feats: GeoJSON.Feature[] = draft && draft.length > 1
      ? [{ type: 'Feature', geometry: { type: 'LineString', coordinates: tool === 'form' ? [...draft, draft[0]] : draft }, properties: { color } }]
      : [];
    (map.getSource(DRAFT) as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: feats });
  }, [draft, color, tool, map, styleVer]);

  // Karte mit einem Finger bewegen nur, wenn kein Werkzeug gewählt ist und nichts verschoben wird.
  useEffect(() => {
    if ((open && tool) || moving) map.dragPan.disable();
    else map.dragPan.enable();
    return () => { map.dragPan.enable(); };
  }, [open, tool, moving, map]);

  async function insert(row: { kind: Kind; geom: Drawing['geom'] }) {
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
    if (!ids.length) return;
    setErr(null);
    setItems((list) => list.filter((d) => !ids.includes(d.id)));
    setMenu(null);
    const { error } = await db().from('hunter_drawings').delete().in('id', ids);
    if (error) setErr(errorText(error));
  }

  // Finger auf der Karte.
  useEffect(() => {
    let down: { p: number[]; px: maplibregl.Point; moved: boolean; hit: string | null } | null = null;
    let stroke: number[][] = [];
    let lastPx: maplibregl.Point | null = null;
    let holdTimer: ReturnType<typeof setTimeout> | null = null;
    let hold: { id: string; start: number[]; orig: Drawing['geom'] } | null = null;
    let erased = new Set<string>();
    const clearHold = () => { if (holdTimer) clearTimeout(holdTimer); holdTimer = null; };

    const hitAt = (px: maplibregl.Point, r = 14) => {
      const box: [maplibregl.PointLike, maplibregl.PointLike] = [[px.x - r, px.y - r], [px.x + r, px.y + r]];
      return map.queryRenderedFeatures(box, { layers: HIT_LAYERS.filter((l) => map.getLayer(l)) })
        .map((f) => f.properties?.id as string | undefined).filter((x): x is string => !!x);
    };
    const eraseAt = (px: maplibregl.Point) => {
      const ids = hitAt(px, 16).filter((id) => !erased.has(id));
      if (!ids.length) return;
      ids.forEach((id) => erased.add(id));
      tapFeedback();
      setItems((list) => list.filter((d) => !erased.has(d.id)));
    };
    const cancel = () => { down = null; stroke = []; setDraft(null); clearHold(); };

    const onDown = (e: PointerEv) => {
      const s = st.current;
      if (!s.open) return;
      if (fingers(e) > 1) { cancel(); return; }
      const p = [e.lngLat.lng, e.lngLat.lat];
      down = { p, px: e.point, moved: false, hit: null };
      lastPx = e.point;
      if (s.tool === 'frei' || s.tool === 'form') { stroke = [p]; setDraft([p]); return; }
      if (s.tool === 'radier') { erased = new Set(); eraseAt(e.point); return; }
      if (s.tool) return;
      // Kein Werkzeug: auf eine Zeichnung? Kurz halten = verschieben, kurz antippen = Menü.
      const hit = hitAt(e.point)[0] ?? null;
      down.hit = hit;
      if (!hit) return;
      clearHold();
      holdTimer = setTimeout(() => {
        if (!down || down.moved || !down.hit) return;
        const d = st.current.items.find((x) => x.id === down!.hit);
        if (!d) return;
        hold = { id: d.id, start: down.p, orig: d.geom };
        map.dragPan.disable();
        tapFeedback();
        setMenu(null);
        setMoving(d.id);
      }, HOLD_MS);
    };

    const onMove = (e: PointerEv) => {
      if (!down) return;
      if (fingers(e) > 1) { cancel(); return; }
      const p = [e.lngLat.lng, e.lngLat.lat];
      if (hold) {
        const geom = moveGeom(hold.orig, p[0] - hold.start[0], p[1] - hold.start[1]);
        const id = hold.id;
        setItems((list) => list.map((d) => (d.id === id ? { ...d, geom } : d)));
        e.originalEvent.preventDefault?.();
        return;
      }
      if (!down.moved && Math.hypot(e.point.x - down.px.x, e.point.y - down.px.y) > 8) { down.moved = true; clearHold(); }
      const s = st.current;
      if (!s.tool) return;
      e.originalEvent.preventDefault?.();
      if ((s.tool === 'frei' || s.tool === 'form') && lastPx && Math.hypot(e.point.x - lastPx.x, e.point.y - lastPx.y) >= 4) {
        stroke.push(p);
        lastPx = e.point;
        setDraft([...stroke]);
      }
      if (s.tool === 'radier') eraseAt(e.point);
    };

    const onUp = (e: PointerEv) => {
      clearHold();
      const s = st.current;
      if (hold) {
        const d = s.items.find((x) => x.id === hold!.id);
        if (d) void update(d.id, { geom: d.geom });
        hold = null;
        setMoving(null);
        down = null;
        return;
      }
      if (!down) return;
      const p = [e.lngLat.lng, e.lngLat.lat];
      if (s.tool === 'frei' && stroke.length >= 2) void insert({ kind: 'strich', geom: { type: 'LineString', coordinates: thin(stroke) } });
      if (s.tool === 'form' && stroke.length >= 3) {
        const pts = thin(stroke);
        void insert({ kind: 'flaeche', geom: { type: 'Polygon', coordinates: [[...pts, pts[0]]] } });
      }
      if (s.tool === 'punkt' && !down.moved) void insert({ kind: 'punkt', geom: { type: 'Point', coordinates: p } });
      if (s.tool === 'radier' && erased.size) void remove([...erased]);
      if (!s.tool && !down.moved) {
        // Kurz antippen: Menü der Zeichnung (oder Menü schliessen).
        if (down.hit) {
          setMenu({ id: down.hit, x: down.px.x, y: down.px.y });
          setLabel(s.items.find((x) => x.id === down!.hit)?.label ?? '');
        } else setMenu(null);
      }
      stroke = [];
      setDraft(null);
      down = null;
    };

    map.on('touchstart', onDown); map.on('mousedown', onDown);
    map.on('touchmove', onMove); map.on('mousemove', onMove);
    map.on('touchend', onUp); map.on('mouseup', onUp); map.on('touchcancel', onUp);
    return () => {
      clearHold();
      map.off('touchstart', onDown); map.off('mousedown', onDown);
      map.off('touchmove', onMove); map.off('mousemove', onMove);
      map.off('touchend', onUp); map.off('mouseup', onUp); map.off('touchcancel', onUp);
    };
  }, [map]); // eslint-disable-line react-hooks/exhaustive-deps

  const selected = menu ? items.find((d) => d.id === menu.id) ?? null : null;
  const box = map.getContainer().getBoundingClientRect();
  const menuLeft = menu ? Math.min(Math.max(8, menu.x - 130), Math.max(8, box.width - 270)) : 0;
  const menuTop = menu ? (menu.y > box.height / 2 ? Math.max(8, menu.y - 170) : menu.y + 20) : 0;
  const hint = tool === 'frei' ? t('Mit dem Finger zeichnen.') : tool === 'form' ? t('Mit dem Finger eine Form umfahren.')
    : tool === 'punkt' ? t('Auf die Karte tippen.') : tool === 'radier' ? t('Mit dem Finger über Zeichnungen fahren.')
    : t('Werkzeug wählen. Zeichnung halten und ziehen = verschieben, antippen = ändern.');

  return (
    <>
      <button type="button" className={`draw-pen${open ? ' on' : ''}`} aria-pressed={open} aria-label={open ? t('Zeichnen beenden') : t('Zeichnen')}
        onClick={() => { setOpen(!open); setTool(null); setMenu(null); setMoving(null); }}>
        {open ? '✓' : '✏️'}
      </button>

      {open && (
        <div className="draw-bar" onClick={(e) => e.stopPropagation()}>
          <div className="row" style={{ gap: 4, flexWrap: 'nowrap' }}>
            {([['frei', '✍️', t('Zeichnen')], ['form', '⬠', t('Form')], ['punkt', '📍', t('Punkt')], ['radier', '🧽', t('Radieren')]] as [Tool, string, string][]).map(([id, ic, name]) => (
              <button key={id} type="button" className={`draw-tool${tool === id ? ' on' : ''}`} aria-pressed={tool === id}
                onClick={() => { setTool(tool === id ? null : id); setMenu(null); }}><span>{ic}</span><small>{name}</small></button>
            ))}
          </div>
          {(tool === 'frei' || tool === 'form' || tool === 'punkt') && (
            <div className="draw-colors">
              {COLORS.map((c) => <button key={c} type="button" className={`draw-color${color === c ? ' on' : ''}`} style={{ background: c }} aria-label={t('Farbe')} onClick={() => setColor(c)} />)}
            </div>
          )}
          <div className="tiny muted">{hint}</div>
          {tool === 'radier' && items.length > 0 && (
            <button type="button" className="small ghost" onClick={() => { if (window.confirm(t('Alle Zeichnungen für alle Hunter löschen?'))) void remove(items.map((d) => d.id)); }}>🗑️ {t('Alles löschen')} ({items.length})</button>
          )}
        </div>
      )}

      {menu && selected && (
        <div className="draw-menu" style={{ left: menuLeft, top: menuTop }} onClick={(e) => e.stopPropagation()}>
          <div className="draw-colors">
            {COLORS.map((c) => <button key={c} type="button" className={`draw-color${selected.color === c ? ' on' : ''}`} style={{ background: c }} aria-label={t('Farbe')} onClick={() => void update(selected.id, { color: c })} />)}
          </div>
          <form className="row" style={{ gap: 6, flexWrap: 'nowrap' }} onSubmit={(e) => { e.preventDefault(); void update(selected.id, { label: label.trim() }); setMenu(null); }}>
            <input value={label} maxLength={40} placeholder={t('Text (z. B. „gesehen 14:20“)')} aria-label={t('Text')} onChange={(e) => setLabel(e.target.value)} style={{ flex: 1, minWidth: 0 }} />
            <button type="submit" className="small">💬</button>
          </form>
          <div className="row" style={{ gap: 6 }}>
            <button type="button" className="small danger" onClick={() => void remove([selected.id])}>🗑️ {t('Löschen')}</button>
            <span className="spacer" />
            <button type="button" className="small ghost" onClick={() => setMenu(null)}>{t('Schliessen')}</button>
          </div>
        </div>
      )}
      {err && <div className="draw-hint red">{err}</div>}
    </>
  );
}
