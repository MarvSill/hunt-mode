import '../lib/leafletGlobal';
import NumberField from '../components/NumberField';
import Icon from '../components/Icon';
import '@geoman-io/leaflet-geoman-free';
import '@geoman-io/leaflet-geoman-free/dist/leaflet-geoman.css';
import L from 'leaflet';
import { addMapButtons } from '../lib/mapControls';
import 'leaflet/dist/leaflet.css';
import { maplibreGL } from '@maplibre/maplibre-gl-leaflet';
import 'maplibre-gl/dist/maplibre-gl.css';
import { getMapSettings, OSM_TILES, resolveStyle, useMapSettings } from '../lib/mapStyle';
import MapStylePicker from '../components/MapStylePicker';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import Info from '../components/Info';
import { esc, pointIcon, zoneBadge, zoneStyle } from '../components/leafletZones';
import { STEP_HELP, ZONE_HELP } from '../shared/help';
import { formatMinutes } from '../shared/format';
import { api, ZONE_INFO, ZONE_KINDS, type MapFeature, type ZoneKind } from '../lib/engine';
import {
  areaKm2, bandFromLine, centerOf, checkMap, circleWithArea, clipTo, exitPlaceOk, fieldOfPhase, INSIDE_FIELD, middleOf, nearestExitPlace, outsideShare, pointInside,
  recommendedFieldKm2, rectWithArea, RESTRICTED_TYPES, restrictedInfo, shrinkArea, spreadPoints, unionAll, type Area, type MapIssue,
} from '../lib/geo';
import { diffConfig, getGame, updateConfig, type Game } from '../lib/games';
import { transformScale } from '@turf/turf';
import { suggestHazards, type HazardSuggestion } from '../lib/hazards';
import { errorText } from '../lib/supabase';
import { gameConfigSchema, parseConfig, type GameConfig } from '../shared/config';
import { durationText, fitTimes, huntMinutes, timeLimits } from '../shared/timeRules';
import Loader from '../components/Loader';
import { t, lazy } from '../i18n';

interface Item { key: string; feature: MapFeature; layer: L.Layer }
type Tool = 'Polygon' | 'Rectangle' | 'Circle' | 'Marker' | 'Line';
interface Pending { kind: ZoneKind; tool: Tool; phase?: number | null; restrictedType?: string; widthM?: number }

let seq = 0;
const newKey = () => `z${Date.now()}_${seq++}`;

/** Symbol je Zonenart (Liste und Knöpfe). */
const ICON: Record<ZoneKind, string> = {
  spielfeld: '🟩', sperrzone: '⚠️', exit: '🏁', treffpunkt: '📍',
};

const TOOL_HINT: Record<Tool, string> = lazy({
  Polygon: 'Tippe die Ecken nacheinander auf die Karte. Zum Abschliessen den ersten Punkt nochmals antippen.',
  Rectangle: 'Tippe eine Ecke, dann die gegenüberliegende Ecke.',
  Circle: 'Tippe den Mittelpunkt, dann tippe so weit weg, wie der Kreis gross sein soll.',
  Marker: 'Tippe die Stelle auf der Karte an.',
  Line: 'Tippe der Strasse oder den Gleisen entlang. Zum Abschliessen den letzten Punkt nochmals antippen.',
});

function circleToPolygon(lat: number, lng: number, r: number, n = 48): GeoJSON.Polygon {
  const coords: [number, number][] = [];
  for (let i = 0; i <= n; i++) {
    const a = (i / n) * 2 * Math.PI;
    const dLat = (r * Math.cos(a)) / 111320;
    const dLng = (r * Math.sin(a)) / (111320 * Math.cos((lat * Math.PI) / 180));
    coords.push([lng + dLng, lat + dLat]);
  }
  return { type: 'Polygon', coordinates: [coords] };
}

const asArea = (f: MapFeature): Area => ({ type: 'Feature', geometry: f.geometry as GeoJSON.Polygon, properties: {} });
const isArea = (f: MapFeature) => f.geometry.type === 'Polygon' || f.geometry.type === 'MultiPolygon';

/** Anzahl Phasen wie in der Engine (phase_count): die Verkleinerung läuft während der Jagd, nach dem Vorsprung. */
export function phaseCount(c: GameConfig): number {
  const every = c.zone.shrink_mode === 'aus' ? 0 : c.zone.shrink_every_minutes;
  return every > 0 ? Math.min(50, Math.max(1, Math.ceil(huntMinutes(c) / every))) : c.game.days;
}

export default function MapEditorPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  // Direkt nach "Spiel erstellen": Schritt 4 von 4, danach geht es in die Lobby.
  const setup = useSearchParams()[0].get('neu') === '1';
  const [game, setGame] = useState<Game | null>(null);
  const [savedConfig, setSavedConfig] = useState<GameConfig | null>(null);
  const issuesRef = useRef<MapIssue[]>([]);
  const [config, setConfig] = useState<GameConfig | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [dirty, setDirty] = useState(false);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [preview, setPreview] = useState(1);
  const [hazards, setHazards] = useState<HazardSuggestion[] | null>(null);
  const [hazardBusy, setHazardBusy] = useState(false);
  const [lineWidth, setLineWidth] = useState(30);
  const [restrictedType, setRestrictedType] = useState('gleise');
  const [stepIdx, setStepIdx] = useState(0);
  /** Eigener Standort (blauer Punkt), um Spielfeld und Startpunkt dort zu setzen. */
  const [me, setMe] = useState<{ lat: number; lng: number; acc: number } | null>(null);
  const meLayer = useRef<L.LayerGroup | null>(null);
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const base = useRef<L.Layer | null>(null);
  const mapSettings = useMapSettings();
  /** Grundkarte wechseln: klassisch als Kacheln, sonst als MapLibre-Stil. */
  function setBase(m: L.Map, styleId: Parameters<typeof resolveStyle>[0]) {
    if (base.current) m.removeLayer(base.current);
    const s = resolveStyle(styleId);
    base.current = s.raster
      ? L.tileLayer(OSM_TILES, { maxZoom: 19, attribution: '&copy; OpenStreetMap' })
      : (maplibreGL({ style: s.url, interactive: false } as Parameters<typeof maplibreGL>[0]) as unknown as L.Layer);
    base.current.addTo(m);
    (base.current as L.GridLayer).bringToBack?.();
  }
  useEffect(() => {
    if (map.current) setBase(map.current, mapSettings.style);
  }, [mapSettings.style]); // eslint-disable-line react-hooks/exhaustive-deps
  const group = useRef<L.FeatureGroup | null>(null);
  const badges = useRef<L.LayerGroup | null>(null);
  const previewLayer = useRef<L.LayerGroup | null>(null);
  const hazardLayer = useRef<L.LayerGroup | null>(null);
  const pendingRef = useRef(pending);
  pendingRef.current = pending;
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const handleCreateRef = useRef<(layer: L.Layer) => void>(() => undefined);

  const editable = !!game && ['entwurf', 'geplant', 'lobby'].includes(game.status);
  const editableRef = useRef(editable);
  editableRef.current = editable;
  const gameId = game?.id;
  const features = useMemo(() => items.map((x) => x.feature), [items]);
  const phases = config ? phaseCount(config) : 1;
  const shrink = config?.zone.shrink_mode ?? 'aus';

  const restyle = useCallback((it: Item) => {
    const l = it.layer as L.Path;
    const p = it.feature.properties;
    if (l.setStyle) l.setStyle(zoneStyle(it.feature));
    const path = (l as unknown as { _path?: SVGElement })._path;
    if (path) path.classList.toggle('hm-danger', p.kind === 'sperrzone');
    const info = ZONE_INFO[p.kind];
    const extra = p.kind === 'sperrzone' ? ` (${restrictedInfo(p.restricted_type).label})` : p.day_index ? t(' · Phase {0}', { 0: p.day_index }) : '';
    l.unbindTooltip?.();
    l.bindTooltip?.(esc(`${ICON[p.kind]} ${p.name || info.label}${extra}`), { sticky: true });
  }, []);

  const layerToFeature = useCallback((layer: L.Layer, props: MapFeature['properties']): MapFeature => {
    const k = props.kind;
    if (layer instanceof L.Circle) {
      const c = layer.getLatLng();
      if (ZONE_INFO[k].point) {
        return { type: 'Feature', geometry: { type: 'Point', coordinates: [c.lng, c.lat] }, properties: { ...props, radius_m: Math.round(layer.getRadius()) } };
      }
      return { type: 'Feature', geometry: circleToPolygon(c.lat, c.lng, layer.getRadius()), properties: props };
    }
    if (layer instanceof L.Marker) {
      const c = layer.getLatLng();
      return { type: 'Feature', geometry: { type: 'Point', coordinates: [c.lng, c.lat] }, properties: { ...props, radius_m: props.radius_m ?? 30 } };
    }
    const gj = (layer as L.Polygon).toGeoJSON() as GeoJSON.Feature;
    return { type: 'Feature', geometry: gj.geometry, properties: props };
  }, []);

  const addItem = useCallback((feature: MapFeature) => {
    const g = group.current!;
    let l: L.Layer;
    if (feature.geometry.type === 'Point') {
      const [lng, lat] = (feature.geometry as GeoJSON.Point).coordinates;
      l = L.marker([lat, lng], { icon: pointIcon(feature.properties.kind), draggable: editableRef.current });
    } else {
      l = L.geoJSON(feature as GeoJSON.Feature).getLayers()[0];
    }
    g.addLayer(l);
    const it: Item = { key: newKey(), feature, layer: l };
    restyle(it);
    // Beim Setzen eines Punkts nicht die Zone darunter öffnen.
    l.on('click', () => { if (!pendingRef.current) setSelected(it.key); });
    const changed = () => {
      setItems((prev) => prev.map((x) => (x.key === it.key ? { ...x, feature: layerToFeature(l, x.feature.properties) } : x)));
      setDirty(true);
    };
    l.on('pm:edit', changed);
    l.on('dragend', changed);
    return it;
  }, [layerToFeature, restyle]);

  // Spiel laden
  useEffect(() => {
    if (!id) return;
    void (async () => {
      try {
        const g = await getGame(id);
        setGame(g);
        if (g) {
          const c = parseConfig(g.config_json);
          setSavedConfig(c);
          // Alte Spiele: unstimmige Zeiten gleich anpassen (wird mit der Karte gespeichert).
          const fit = fitTimes(c);
          setConfig(fit.config);
          if (fit.fixes.length && ['entwurf', 'geplant', 'lobby'].includes(g.status)) {
            setDirty(true);
            setMsg({ ok: true, text: t('Angepasst: ') + fit.fixes.map((f) => f.message).join(' ') });
          }
        }
      } catch (err) {
        setMsg({ ok: false, text: errorText(err) });
      }
    })();
  }, [id]);

  // Karte aufbauen
  useEffect(() => {
    if (!el.current || map.current || !gameId) return;
    const m = L.map(el.current).setView([47.3769, 8.5417], 13);
    // Grundkarte im gewählten Stil (flach, damit man genau zeichnen kann).
    setBase(m, getMapSettings().style);
    previewLayer.current = L.layerGroup().addTo(m);
    group.current = L.featureGroup().addTo(m);
    badges.current = L.layerGroup().addTo(m);
    hazardLayer.current = L.layerGroup().addTo(m);
    meLayer.current = L.layerGroup().addTo(m);
    map.current = m;
    m.pm.setLang('de');
    m.pm.setGlobalOptions({ snappable: true, snapDistance: 15, allowSelfIntersection: false } as L.PM.GlobalOptions);
    m.on('pm:create', (e: { layer: L.Layer }) => handleCreateRef.current(e.layer));
    addMapButtons(m, {
      wrap: () => el.current?.parentElement ?? null,
      fit: () => {
        const b = group.current?.getBounds();
        return b?.isValid() ? b : null;
      },
    });
    let cancelled = false;
    void (async () => {
      try {
        // Den Wartebereich der Hunter legt die Datenbank selbst an den Startpunkt; er wird nicht gezeichnet.
        const list = (await api.map(gameId)).filter((f) => (f.properties.kind as string) !== 'hq').map((f) => addItem(f));
        if (cancelled) return;
        // Was schon gezeichnet oder importiert wurde, bleibt erhalten.
        setItems((prev) => [...list, ...prev]);
        setLoaded(true);
        const b = group.current!.getBounds();
        if (b.isValid()) m.fitBounds(b, { padding: [20, 20], animate: false });
        else if (navigator.geolocation) {
          navigator.geolocation.getCurrentPosition((p) => {
            if (!cancelled && itemsRef.current.length === 0) m.setView([p.coords.latitude, p.coords.longitude], 15, { animate: false });
          }, () => undefined, { timeout: 5000 });
        }
      } catch (err) {
        setMsg({ ok: false, text: errorText(err) });
      }
    })();
    return () => {
      cancelled = true;
      m.remove();
      map.current = null;
    };
  }, [gameId, addItem]);

  // Eigenen Standort laufend zeigen.
  useEffect(() => {
    if (!navigator.geolocation) return;
    const w = navigator.geolocation.watchPosition(
      (p) => setMe({ lat: p.coords.latitude, lng: p.coords.longitude, acc: Math.round(p.coords.accuracy) }),
      () => undefined,
      { enableHighAccuracy: true, maximumAge: 10000, timeout: 20000 },
    );
    return () => navigator.geolocation.clearWatch(w);
  }, []);
  useEffect(() => {
    const l = meLayer.current;
    if (!l) return;
    l.clearLayers();
    if (!me) return;
    if (me.acc > 15) l.addLayer(L.circle([me.lat, me.lng], { radius: me.acc, color: '#58a6ff', weight: 1, fillOpacity: 0.1, interactive: false }));
    l.addLayer(L.circleMarker([me.lat, me.lng], { radius: 8, color: '#fff', weight: 3, fillColor: '#1f6feb', fillOpacity: 1, interactive: false }).bindTooltip(t('Du bist hier')));
  }, [me, loaded]);

  // Beim Öffnen immer ganz vorne beginnen: wer das Spiel erstellt, entscheidet selbst, ob die App das Spielfeld
  // erstellt oder ob er es selbst zeichnet. Weiter geht es nur mit „Weiter“.

  // Symbole auf Gefahrenzonen
  useEffect(() => {
    const b = badges.current;
    if (!b) return;
    b.clearLayers();
    for (const f of features) if (f.properties.kind === 'sperrzone') b.addLayer(zoneBadge(f));
    // Gestrichelter Kreis: Ankunftsradius um den Fluchtpunkt.
    for (const f of features) {
      if (f.geometry.type !== 'Point' || !config) continue;
      const [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
      const k = f.properties.kind;
      const r = k === 'exit' ? config.exit.radius_m : 0;
      if (!r) continue;
      const ring = L.circle([lat, lng], { radius: r, color: ZONE_INFO[k].color, weight: 2, dashArray: '6 6', fill: false, interactive: false });
      b.addLayer(ring);
    }
  }, [features, config]);

  // Gewählte Zone bearbeitbar machen
  useEffect(() => {
    for (const it of items) {
      if (it.layer instanceof L.Marker) continue;
      const pm = (it.layer as L.Layer & { pm?: { enable: (o?: object) => void; disable: () => void; enabled: () => boolean } }).pm;
      if (!pm) continue;
      if (editable && it.key === selected) {
        if (!pm.enabled()) pm.enable({ draggable: true, allowSelfIntersection: false });
      } else if (pm.enabled()) pm.disable();
    }
  }, [selected, items, editable]);

  // Vorschau der Verkleinerung
  const phaseFields = useMemo(() => {
    const out: (Area | null)[] = [];
    if (!config) return out;
    const f1 = fieldOfPhase(features, 1);
    for (let p = 1; p <= phases; p++) {
      if (shrink === 'auto' && f1) {
        // Wie auf dem Server: Richtung Mitte des Spielfelds (der Fluchtpunkt steht noch nicht fest).
        out.push(p === 1 ? f1 : shrinkArea(f1, centerOf(f1, null), config.zone.auto_shrink_percent, p - 1));
      } else {
        out.push(fieldOfPhase(features, p));
      }
    }
    return out;
  }, [features, config, phases, shrink]);

  useEffect(() => {
    const l = previewLayer.current;
    if (!l) return;
    l.clearLayers();
    if (shrink === 'aus' || phases < 2) return;
    phaseFields.forEach((f, i) => {
      if (!f || i === 0) return;
      const active = i + 1 === preview;
      l.addLayer(L.geoJSON(f, {
        style: { color: active ? '#f0f6fc' : '#3fb950', weight: active ? 3 : 1.5, dashArray: '8 6', fillOpacity: active ? 0.08 : 0, opacity: active ? 1 : 0.6 },
        interactive: false,
      }));
    });
  }, [phaseFields, preview, shrink, phases]);

  // Fluchtpunkte, die in einer Gefahrenzone oder ausserhalb der kleinsten Zone liegen (z. B. nach dem Ändern der
  // Verkleinerung, einer neuen Gefahrenzone oder dem Verschieben), automatisch an die nächste erlaubte Stelle setzen.
  useEffect(() => {
    if (!loaded || !editable || pending) return;
    const inner = innermostField();
    if (!inner) return;
    const blocked = blockedArea();
    const exits = items.filter((x) => x.feature.properties.kind === 'exit' && x.feature.geometry.type === 'Point');
    const placed: GeoJSON.Position[] = [];
    let moved = 0;
    const next = new Map<string, GeoJSON.Position>();
    for (const it of exits) {
      const pt = (it.feature.geometry as GeoJSON.Point).coordinates;
      if (exitPlaceOk(pt, inner, blocked, config?.exit.radius_m ?? 0)) { placed.push(pt); continue; }
      const others = [...placed, ...exits.filter((x) => x !== it).map((x) => (x.feature.geometry as GeoJSON.Point).coordinates)];
      const to = nearestExitPlace(pt, inner, blocked, others, config?.exit.radius_m ?? 0);
      if (!to) continue;
      next.set(it.key, to);
      placed.push(to);
      moved++;
    }
    if (!moved) return;
    setItems((prev) => prev.map((x) => {
      const to = next.get(x.key);
      if (!to) return x;
      (x.layer as L.Marker).setLatLng?.([to[1], to[0]]);
      return { ...x, feature: { ...x.feature, geometry: { type: 'Point', coordinates: to } } };
    }));
    setDirty(true);
    setMsg({ ok: true, text: t('{0} Fluchtpunkt(e) lagen in einer Gefahrenzone oder ausserhalb der kleinsten Zone und wurden automatisch an die nächste erlaubte Stelle verschoben.', { 0: moved }) });
  }, [items, phaseFields, loaded, editable, pending, config?.exit.radius_m]); // eslint-disable-line react-hooks/exhaustive-deps

  // Neue Zeichnung übernehmen
  handleCreateRef.current = (layer: L.Layer) => {
    const m = map.current!;
    m.removeLayer(layer);
    const p = pendingRef.current;
    setPending(null);
    m.pm.disableDraw();
    m.doubleClickZoom.enable();
    if (!p) return;
    const field1 = fieldOfPhase(itemsRef.current.map((x) => x.feature), 1);
    const props: MapFeature['properties'] = { kind: p.kind, name: '' };
    if (p.kind === 'spielfeld' && p.phase) props.day_index = p.phase;
    if (p.kind === 'sperrzone') props.restricted_type = p.restrictedType ?? 'andere';
    let f: MapFeature;
    let moved = false;
    if (p.tool === 'Line') {
      const coords = ((layer as L.Polyline).toGeoJSON() as GeoJSON.Feature<GeoJSON.LineString>).geometry.coordinates;
      f = { type: 'Feature', geometry: bandFromLine(coords, p.widthM ?? 30).geometry, properties: props };
    } else {
      f = layerToFeature(layer, props);
    }

    if (f.geometry.type === 'Point') {
      const pt = (f.geometry as GeoJSON.Point).coordinates;
      if (p.kind === 'treffpunkt' && field1 && !pointInside(pt, field1)) {
        setMsg({ ok: false, text: t('{0} muss im Spielfeld liegen. Bitte innerhalb antippen.', { 0: ZONE_INFO[p.kind].label }) });
        return;
      }
      if (p.kind === 'exit') {
        // Fluchtpunkte immer in der kleinsten Zone und nie in einer Gefahrenzone: sonst gleich an die nächste erlaubte Stelle.
        const inner = innermostField();
        if (inner && !exitPlaceOk(pt, inner, blockedArea(), config?.exit.radius_m ?? 0)) {
          const others = itemsRef.current.filter((x) => x.feature.properties.kind === 'exit').map((x) => (x.feature.geometry as GeoJSON.Point).coordinates);
          const to = nearestExitPlace(pt, inner, blockedArea(), others, config?.exit.radius_m ?? 0);
          if (!to) {
            setMsg({ ok: false, text: t('In der kleinsten Zone ist kein Platz ausserhalb der Gefahrenzonen. Bitte das Spielfeld oder die Verkleinerung anpassen.') });
            setTimeout(() => startDraw(p, false), 0);
            return;
          }
          f = { ...f, geometry: { type: 'Point', coordinates: to } };
          moved = true;
        }
      }
      if (p.kind === 'treffpunkt') {
        // Nur einen davon: der alte wird ersetzt.
        for (const old of itemsRef.current.filter((x) => x.feature.properties.kind === p.kind)) group.current?.removeLayer(old.layer);
        setItems((prev) => prev.filter((x) => x.feature.properties.kind !== p.kind));
      }
    } else {
      // Zonen, die nur innerhalb eines anderen Gebiets liegen dürfen, werden zugeschnitten.
      let container: Area | null = null;
      let where = t('im Spielfeld');
      if (INSIDE_FIELD.includes(p.kind)) container = field1;
      if (p.kind === 'spielfeld' && p.phase && p.phase > 1) {
        container = fieldOfPhase(itemsRef.current.map((x) => x.feature), p.phase - 1);
        where = t('im Spielfeld von Phase {0}', { 0: p.phase - 1 });
      }
      if (INSIDE_FIELD.includes(p.kind) && !container) {
        setMsg({ ok: false, text: t('Zeichne zuerst das Spielfeld. Diese Zone muss darin liegen.') });
        return;
      }
      if (container) {
        const share = outsideShare(asArea(f), container);
        if (share > 0.001) {
          const clipped = clipTo(asArea(f), container);
          if (!clipped) {
            setMsg({ ok: false, text: t('Die Zone liegt ganz ausserhalb. Sie muss {0} liegen.', { 0: where }) });
            return;
          }
          f = { ...f, geometry: clipped.geometry };
          setMsg({ ok: true, text: t('Der Teil ausserhalb wurde abgeschnitten: die Zone liegt jetzt ganz {0}.', { 0: where }) });
        } else {
          setMsg(null);
        }
      } else {
        setMsg(null);
      }
    }
    const it = addItem(f);
    setItems((prev) => [...prev, it]);
    setDirty(true);
    if (moved) setMsg({ ok: true, text: t('Der Fluchtpunkt lag in einer Gefahrenzone oder ausserhalb der kleinsten Zone und wurde an die nächste erlaubte Stelle verschoben.') });
    // Fluchtpunkte: gleich den nächsten antippen, ohne jedes Mal den Knopf zu drücken.
    if (p.kind === 'exit') {
      const n = itemsRef.current.filter((x) => x.feature.properties.kind === 'exit').length + 1;
      if (!moved) setMsg({ ok: true, text: t('{0} Fluchtpunkt-Kandidaten gesetzt. Tippe den nächsten an oder drücke „Fertig“.', { 0: n }) });
      setTimeout(() => startDraw(p, false), 0);
    }
  };

  function startDraw(p: Pending, fresh = true) {
    const m = map.current;
    if (!m || !editable) return;
    m.pm.disableDraw();
    m.doubleClickZoom.disable();
    setSelected(null);
    setPending(p);
    if (fresh) setMsg(null);
    const color = p.kind === 'sperrzone' ? '#f85149' : ZONE_INFO[p.kind].color;
    m.pm.enableDraw(p.tool, {
      snappable: true,
      templineStyle: { color },
      hintlineStyle: { color, dashArray: '5,5' },
      pathOptions: { color },
      finishOn: p.tool === 'Line' ? 'dblclick' : undefined,
    } as L.PM.DrawModeOptions);
    if (fresh) el.current?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  function cancelDraw() {
    map.current?.doubleClickZoom.enable();
    map.current?.pm.disableDraw();
    setPending(null);
  }

  function finishLine() {
    // Linie mit den bisher gesetzten Punkten abschliessen.
    const m = map.current as unknown as { pm: { Draw: { Line: { _finishShape: () => void } } } } | null;
    m?.pm.Draw.Line._finishShape();
  }

  function update(key: string, patch: Partial<MapFeature['properties']>) {
    setItems((prev) =>
      prev.map((it) => {
        if (it.key !== key) return it;
        const feature = { ...it.feature, properties: { ...it.feature.properties, ...patch } };
        if (patch.radius_m && it.layer instanceof L.Circle) it.layer.setRadius(patch.radius_m);
        const next = { ...it, feature };
        restyle(next);
        return next;
      }),
    );
    setDirty(true);
  }

  function remove(key: string) {
    const it = items.find((x) => x.key === key);
    if (it) group.current?.removeLayer(it.layer);
    setItems((prev) => prev.filter((x) => x.key !== key));
    setSelected(null);
    setDirty(true);
  }

  function select(key: string) {
    setSelected(key);
    const it = items.find((x) => x.key === key);
    const l = it?.layer as L.Polygon | L.Circle | undefined;
    if (l && 'getBounds' in l) map.current?.fitBounds(l.getBounds(), { padding: [40, 40], maxZoom: 17 });
    el.current?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  function setZone<K extends keyof GameConfig['zone']>(key: K, value: GameConfig['zone'][K]) {
    if (!config) return;
    const next = structuredClone(config);
    next.zone[key] = value;
    const parsed = gameConfigSchema.safeParse(next);
    if (!parsed.success) return;
    // Zeiten müssen in die Spieldauer passen.
    const fit = fitTimes(parsed.data);
    setConfig(fit.config);
    if (fit.fixes.length) setMsg({ ok: true, text: fit.fixes.map((f) => f.message).join(' ') });
    setDirty(true);
  }

  /** Spielfeld der nächsten Phase als verkleinerte Kopie der vorherigen anlegen. */
  function copyShrunk(phase: number, percent: number) {
    const prev = fieldOfPhase(features, phase - 1);
    if (!prev) return setMsg({ ok: false, text: t('Zeichne zuerst das Spielfeld von Phase {0}.', { 0: phase - 1 }) });
    const shape = shrinkArea(prev, centerOf(prev, null), percent, 1);
    for (const old of items.filter((x) => x.feature.properties.kind === 'spielfeld' && x.feature.properties.day_index === phase)) group.current?.removeLayer(old.layer);
    const it = addItem({ type: 'Feature', geometry: shape.geometry, properties: { kind: 'spielfeld', name: t('Spielfeld Phase {0}', { 0: phase }), day_index: phase } });
    setItems((prevItems) => [...prevItems.filter((x) => !(x.feature.properties.kind === 'spielfeld' && x.feature.properties.day_index === phase)), it]);
    setSelected(it.key);
    setPreview(phase);
    setDirty(true);
  }

  /** Alle Zonen, die über das Spielfeld hinausragen, zuschneiden. */
  function clipAll() {
    const field1 = fieldOfPhase(features, 1);
    if (!field1) return;
    let n = 0;
    const next: Item[] = [];
    for (const it of items) {
      const f = it.feature;
      if (INSIDE_FIELD.includes(f.properties.kind) && isArea(f) && outsideShare(asArea(f), field1) > 0.001) {
        const c = clipTo(asArea(f), field1);
        group.current?.removeLayer(it.layer);
        if (c) next.push(addItem({ ...f, geometry: c.geometry }));
        n++;
      } else next.push(it);
    }
    setItems(next);
    setDirty(true);
    setMsg({ ok: true, text: t('{0} Zone(n) aufs Spielfeld zugeschnitten.', { 0: n }) });
  }

  async function loadHazards() {
    const field1 = fieldOfPhase(features, 1);
    if (!field1) return setMsg({ ok: false, text: t('Zeichne zuerst das Spielfeld.') });
    setHazardBusy(true);
    setMsg(null);
    try {
      const list = await suggestHazards(field1);
      setHazards(list);
      if (list.length === 0) setMsg({ ok: true, text: t('Keine Autobahnen, Bahngleise oder grossen Gewässer im Spielfeld gefunden.') });
    } catch {
      setMsg({ ok: false, text: t('OpenStreetMap ist gerade nicht erreichbar. Versuch es später nochmals oder zeichne die Sperrzonen selbst.') });
    } finally {
      setHazardBusy(false);
    }
  }

  useEffect(() => {
    const l = hazardLayer.current;
    if (!l) return;
    l.clearLayers();
    for (const h of hazards ?? []) {
      l.addLayer(L.geoJSON(h.shape, { style: { color: '#f85149', weight: 1, dashArray: '3 3', fillOpacity: 0.25 }, interactive: false }));
    }
  }, [hazards]);

  function takeHazards(list: HazardSuggestion[]) {
    const added = list.map((h) => addItem({ type: 'Feature', geometry: h.shape.geometry, properties: { kind: 'sperrzone', name: h.name, restricted_type: h.type } }));
    setItems((prev) => [...prev, ...added]);
    setHazards((prev) => (prev ?? []).filter((h) => !list.includes(h)));
    setDirty(true);
  }

  async function save(): Promise<boolean> {
    if (!game || !config || !savedConfig) return false;
    setBusy(true);
    setMsg(null);
    try {
      const list = itemsRef.current.map((it) => {
        const { id: _id, released: _r, visible_from: _v, ...props } = it.feature.properties;
        // Punkte: Radius kommt aus den Regeln (Fluchtpunkt-Radius).
        if (props.kind === 'exit') props.radius_m = config.exit.radius_m;
        if (props.kind === 'treffpunkt') props.radius_m = 30;
        return { type: 'Feature' as const, geometry: it.feature.geometry, properties: props };
      });
      const n = await api.saveMap(game.id, list);
      const changes = diffConfig(savedConfig, config);
      if (changes.length) {
        await updateConfig(game.id, config, changes);
        setSavedConfig(config);
      }
      // Gleich beim Speichern sagen, was noch fehlt oder nicht stimmt (nicht erst beim Starten des Spiels).
      const errs = issuesRef.current.filter((i) => i.level === 'error');
      const saved = changes.length ? t('Gespeichert: {0} Elemente und die Einstellungen zur Verkleinerung.', { 0: n }) : t('Gespeichert: {0} Elemente.', { 0: n });
      if (errs.length) setMsg({ ok: false, text: `${saved} ${t('Aber so kann das Spiel noch nicht starten:')} ${errs.map((i) => i.text).join(' ')}` });
      else setMsg({ ok: true, text: saved });
      setDirty(false);
      return true;
    } catch (err) {
      setMsg({ ok: false, text: errorText(err) });
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function findPlace() {
    if (!search.trim() || !map.current) return;
    try {
      const r = await fetch(`https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(search)}`, { headers: { 'Accept-Language': 'de' } });
      const j = (await r.json()) as { lat: string; lon: string; boundingbox?: string[] }[];
      if (!j.length) return setMsg({ ok: false, text: t('Ort nicht gefunden.') });
      const bb = j[0].boundingbox;
      if (bb) map.current.fitBounds([[+bb[0], +bb[2]], [+bb[1], +bb[3]]]);
      else map.current.setView([+j[0].lat, +j[0].lon], 15);
    } catch {
      setMsg({ ok: false, text: t('Suche nicht erreichbar.') });
    }
  }

  function locate() {
    navigator.geolocation?.getCurrentPosition((p) => map.current?.setView([p.coords.latitude, p.coords.longitude], 16), () => setMsg({ ok: false, text: t('Standort nicht verfügbar.') }), { timeout: 8000 });
  }

  function exportJson() {
    const fc = { type: 'FeatureCollection', features: items.map((it) => it.feature) };
    const blob = new Blob([JSON.stringify(fc, null, 2)], { type: 'application/geo+json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `${game?.name ?? 'karte'}.geojson`;
    a.click();
  }

  async function importJson(file: File) {
    try {
      const fc = JSON.parse(await file.text()) as { features?: MapFeature[] };
      const list: Item[] = [];
      for (const f of fc.features ?? []) {
        if (!f.geometry) continue;
        const k = (ZONE_KINDS as readonly string[]).includes(f.properties?.kind) ? f.properties.kind : 'spielfeld';
        list.push(addItem({ type: 'Feature', geometry: f.geometry, properties: { ...f.properties, kind: k } }));
      }
      setItems((prev) => [...prev, ...list]);
      setDirty(true);
      const b = group.current?.getBounds();
      if (b?.isValid()) map.current?.fitBounds(b, { animate: false });
      setMsg({ ok: true, text: t('{0} Elemente importiert. Speichern nicht vergessen.', { 0: list.length }) });
    } catch {
      setMsg({ ok: false, text: t('Datei ist kein gültiges GeoJSON.') });
    }
  }

  /** Punkt (Startpunkt, Fluchtpunkt) setzen; den Startpunkt gibt es nur einmal. */
  function placePoints(kind: ZoneKind, coords: GeoJSON.Position[], radius: number) {
    const replace = kind === 'treffpunkt';
    if (replace) for (const old of itemsRef.current.filter((x) => x.feature.properties.kind === kind)) group.current?.removeLayer(old.layer);
    const added = coords.map((c) => addItem({ type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: { kind, name: '', radius_m: radius } }));
    const next = [...itemsRef.current.filter((x) => !(replace && x.feature.properties.kind === kind)), ...added];
    itemsRef.current = next;
    setItems(next);
    setDirty(true);
  }

  const blockedArea = () => unionAll(itemsRef.current.map((x) => x.feature).filter((f) => f.properties.kind === 'sperrzone' && isArea(f)).map(asArea));
  const meetPoint = () => {
    const m = itemsRef.current.find((x) => x.feature.properties.kind === 'treffpunkt' && x.feature.geometry.type === 'Point');
    return m ? (m.feature.geometry as GeoJSON.Point).coordinates : null;
  };

  /** Spielfeld als Kreis oder Rechteck mit gewünschter Fläche um den eigenen Standort (ohne Standort: Kartenmitte). */
  function quickField(km2: number, form: 'kreis' | 'rechteck') {
    const m = map.current;
    if (!m) return;
    const c = me ? L.latLng(me.lat, me.lng) : m.getCenter();
    for (const old of itemsRef.current.filter((x) => x.feature.properties.kind === 'spielfeld' && !x.feature.properties.day_index)) group.current?.removeLayer(old.layer);
    const shape = form === 'rechteck' ? rectWithArea([c.lng, c.lat], km2) : circleWithArea([c.lng, c.lat], km2);
    const it = addItem({ type: 'Feature', geometry: shape.geometry, properties: { kind: 'spielfeld', name: t('Spielfeld') } });
    const next = [...itemsRef.current.filter((x) => !(x.feature.properties.kind === 'spielfeld' && !x.feature.properties.day_index)), it];
    itemsRef.current = next;
    setItems(next);
    setDirty(true);
    m.fitBounds((it.layer as L.Polygon).getBounds(), { padding: [20, 20] });
    setMsg({ ok: true, text: me ? t('Spielfeld um deinen Standort erstellt. Du kannst es antippen und die Ecken verschieben. Danach „Weiter“.') : t('Spielfeld erstellt. Du kannst es antippen und die Ecken verschieben. Danach „Weiter“.') });
  }

  /** Spielfeld mit + / − grösser oder kleiner machen (um die Mitte, Form bleibt gleich). */
  function scaleField(factor: number) {
    const m = map.current;
    const old = itemsRef.current.find((x) => x.feature.properties.kind === 'spielfeld' && !x.feature.properties.day_index);
    if (!m || !old) return;
    const geom = old.feature.geometry as GeoJSON.Polygon | GeoJSON.MultiPolygon;
    const scaled = transformScale({ type: 'Feature', geometry: geom, properties: {} } as GeoJSON.Feature<GeoJSON.Polygon | GeoJSON.MultiPolygon>, Math.sqrt(factor), { origin: 'centroid' });
    group.current?.removeLayer(old.layer);
    const it = addItem({ type: 'Feature', geometry: scaled.geometry, properties: { ...old.feature.properties } });
    const next = [...itemsRef.current.filter((x) => x !== old), it];
    itemsRef.current = next;
    setItems(next);
    setDirty(true);
    m.fitBounds((it.layer as L.Polygon).getBounds(), { padding: [20, 20] });
  }

  function autoMeet(): GeoJSON.Position | null {
    const f = fieldOfPhase(itemsRef.current.map((x) => x.feature), 1);
    if (!f) return null;
    const pt = middleOf(f);
    placePoints('treffpunkt', [pt], 30);
    return pt;
  }

  function innermostField(): Area | null {
    const feats = itemsRef.current.map((x) => x.feature);
    if (shrink === 'auto') return phaseFields[phaseFields.length - 1] ?? fieldOfPhase(feats, 1);
    return fieldOfPhase(feats, phases) ?? fieldOfPhase(feats, 1);
  }

  function autoExits(n: number, meet?: GeoJSON.Position | null) {
    // Fluchtpunkte immer in die innerste Zone (Spielfeld der letzten Phase), sonst sind sie am Ende nicht erreichbar.
    const f = innermostField();
    if (!f) return;
    for (const old of itemsRef.current.filter((x) => x.feature.properties.kind === 'exit')) group.current?.removeLayer(old.layer);
    itemsRef.current = itemsRef.current.filter((x) => x.feature.properties.kind !== 'exit');
    const from = meet ?? meetPoint();
    placePoints('exit', spreadPoints(f, n, from ? [from] : [], blockedArea()), 30);
  }

  function autoPoints() {
    autoMeet();
    setMsg({ ok: true, text: t('Startpunkt gesetzt. Zum Verschieben antippen und ziehen.') });
  }

  /** Startpunkt genau dort, wo man gerade steht. */
  function meetHere() {
    if (!me) return setMsg({ ok: false, text: t('Dein Standort ist noch nicht bekannt. Erlaube den Standort und warte kurz.') });
    const f1 = fieldOfPhase(itemsRef.current.map((x) => x.feature), 1);
    if (f1 && !pointInside([me.lng, me.lat], f1)) return setMsg({ ok: false, text: t('Du stehst ausserhalb des Spielfelds. Der Startpunkt muss im Spielfeld liegen.') });
    placePoints('treffpunkt', [[me.lng, me.lat]], 30);
    setMsg({ ok: true, text: t('Startpunkt an deinem Standort gesetzt.') });
  }

  function goStep(i: number) {
    cancelDraw();
    setSelected(null);
    setMsg(null);
    setStepIdx(Math.max(0, i));
  }

  if (!game || !config) {
    return <div className="app">{msg ? <div className="notice error">{msg.text}</div> : <Loader inline />}</div>;
  }

  const sel = items.find((x) => x.key === selected);
  const field1 = fieldOfPhase(features, 1);
  const km2 = areaKm2(field1);
  const has = (k: ZoneKind) => features.some((f) => f.properties.kind === k);
  const recKm2 = recommendedFieldKm2({
    pingMinutes: config.ping.interval_minutes, durationMinutes: config.game.duration_minutes,
    people: config.roles.players_max + config.roles.hunters_max,
    motorized: config.transport.motorized_allowed, bikes: config.transport.bikes_allowed,
  });
  const issues = checkMap({
    features, exitEnabled: config.exit.enabled && config.win.mode !== 'letzter_ueberlebender', phases,
    autoShrink: shrink === 'auto', manualShrink: shrink === 'manuell', finalField: phaseFields[phaseFields.length - 1] ?? null,
    recommendedKm2: recKm2,
  });
  issuesRef.current = issues;
  const sticking = field1 ? items.filter((it) => INSIDE_FIELD.includes(it.feature.properties.kind) && isArea(it.feature) && outsideShare(asArea(it.feature), field1) > 0.01) : [];
  const unitLabel = t('Phase');
  const limits = timeLimits(config);
  const draw = (p: Pending) => () => startDraw(p);
  const steps: { id: string; icon: string; title: string; text: string; done: boolean; optional?: boolean }[] = [
    { id: 'feld', icon: '🟩', title: t('Spielfeld'), text: t('Der Bereich, in dem gespielt wird. Alle anderen Zonen liegen darin.'), done: !!field1 },
    { id: 'treff', icon: '📍', title: t('Startpunkt'), text: t('Hier starten alle, Spieler und Hunter. Die Spieler laufen zuerst los, die Hunter warten hier, bis der Vorsprung vorbei ist. Muss im Spielfeld liegen.'), done: has('treffpunkt') },
    { id: 'klein', icon: '⏳', title: t('Kleiner werden'), text: t('Soll das Spielfeld im Lauf des Spiels kleiner werden? Neue Grenzen werden vorher angekündigt und gestrichelt gezeigt. Lege das vor den Fluchtpunkten fest: die müssen in der kleinsten Zone liegen.'), done: shrink !== 'aus', optional: true },
    ...(config.exit.enabled ? [{ id: 'exit', icon: '🏁', title: t('Fluchtpunkt'), text: t('Setze mindestens 4 mögliche Fluchtpunkte, alle in der kleinsten Zone (Spielfeld der letzten Phase). Erst kurz vor Schluss wählt die App zufällig einen davon und verrät ihn nur den Spielern. So weisst auch du nicht, welcher es wird.'), done: features.filter((f) => f.properties.kind === 'exit').length >= 4 }] : []),
    { id: 'gefahr', icon: '⚠️', title: t('Gefahren'), text: t('Nur aussergewöhnlich gefährliche Orte: Autobahnen, Bahngleise, grosse Gewässer. Unterführungen und Brücken bleiben frei. Für alles andere ist jeder selbst verantwortlich.'), done: has('sperrzone'), optional: true },
    { id: 'fertig', icon: '✅', title: t('Prüfen'), text: t('Hier siehst du, ob die Karte bereit ist.'), done: !issues.some((i) => i.level === 'error') },
  ];
  const cur = steps[Math.min(stepIdx, steps.length - 1)];
  const kmText = (v: number) => (v < 1 ? `${Math.round(v * 100)} ha` : `${v.toFixed(1)} km²`);
  const legend = (['spielfeld', 'sperrzone', 'treffpunkt', 'exit'] as ZoneKind[]).filter((k) => k === 'spielfeld' || has(k));

  return (
    <div className="app wide map-editor">
      <div className="topbar">
        <Link to={`/spiel/${id}`} className="button ghost back" aria-label={t('Zurück')}><Icon name="back" /></Link>
        <h1>{setup ? t('Schritt 4: Karte') : t('Karte')}</h1>
        {editable && !setup && <button className="primary small" onClick={save} disabled={busy || !dirty || !loaded}>{busy ? t('Speichere …') : dirty ? t('Speichern') : t('Gespeichert')}</button>}
      </div>
      {setup && editable && (
        <div className="notice" style={{ marginBottom: 8 }}>
          <strong>{t('Letzter Schritt: das Spielfeld.')}</strong> {t('Zeichne, wo gespielt wird, und setze den Startpunkt. Danach bekommst du den Code, mit dem deine Freunde beitreten.')}
        </div>
      )}
      {!editable && <div className="notice">{t('Das Spiel läuft: die Karte ist gesperrt.')}</div>}

      {editable && (
        <div className="row" style={{ marginBottom: 8 }}>
          <input placeholder={t('Ort suchen (z. B. Zürich HB)')} value={search} onChange={(e) => setSearch(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && findPlace()} style={{ flex: 1 }} />
          <button className="small" onClick={findPlace}>{t('Suchen')}</button>
          <button className="small" onClick={locate} aria-label={t('Mein Standort')}>◎</button>
        </div>
      )}

      <div className="map-wrap">
        <div ref={el} className="map" style={{ height: '48dvh' }} />
        <div className="map-overlay-tl"><MapStylePicker /></div>
        {pending && (
          <div className="draw-hint">
            <strong>{ICON[pending.kind]} {pending.kind === 'spielfeld' && pending.phase && pending.phase > 1 ? t('Spielfeld {0} {1}', { 0: unitLabel, 1: pending.phase }) : ZONE_INFO[pending.kind].label}</strong>
            <div className="small">{TOOL_HINT[pending.tool]}</div>
            <div className="row">
              {pending.tool === 'Line' && <button className="small primary" onClick={finishLine}>{t('Linie fertig')}</button>}
              {pending.kind === 'exit'
                ? <button className="small primary" onClick={cancelDraw}>{t('Fertig')} ({features.filter((f) => f.properties.kind === 'exit').length})</button>
                : <button className="small" onClick={cancelDraw}>{t('Abbrechen')}</button>}
            </div>
          </div>
        )}
      </div>
      <div className="legend">
        {legend.map((k) => (
          <span key={k}><i className={`swatch${k === 'sperrzone' ? ' danger' : ''}`} style={{ background: k === 'sperrzone' ? undefined : ZONE_INFO[k].color }} />{ZONE_INFO[k].label}</span>
        ))}
        {shrink !== 'aus' && phases > 1 && <span><i className="swatch dashed" />{t('spätere Grenze')}</span>}
      </div>
      <div className="muted small" style={{ margin: '6px 0' }}>
        {km2 > 0 ? t('Spielfeld {0} km² · empfohlen etwa {1}', { 0: km2.toFixed(2), 1: kmText(recKm2) }) : t('Noch kein Spielfeld. Empfohlen etwa {0}.', { 0: kmText(recKm2) })}
      </div>
      {msg && <div className={`notice ${msg.ok ? 'success' : 'error'}`} style={{ marginBottom: 12 }}>{msg.text}</div>}

      {sel && (
        <ZoneProps sel={sel} editable={editable} phases={phases} unitLabel={unitLabel} update={update} remove={remove} close={() => setSelected(null)} />
      )}

      {editable && (
        <div className="wizard card stack">
          <div className="wizard-steps" role="tablist">
            {steps.map((st, i) => (
              <button key={st.id} type="button" role="tab" aria-selected={i === stepIdx} aria-label={st.title}
                className={`wizard-dot${i === stepIdx ? ' on' : ''}${st.done ? ' done' : ''}`} onClick={() => goStep(i)}>
                <span>{st.done && i !== stepIdx ? '✓' : st.icon}</span>
                <small>{st.title}</small>
              </button>
            ))}
          </div>
          <div>
            <div className="muted small">{t('Schritt {0} von {1}', { 0: stepIdx + 1, 1: steps.length })}{cur.optional ? t(' · freiwillig') : ''}</div>
            <h2 style={{ margin: '2px 0 0' }}>{cur.icon} {cur.title} <Info title={cur.title} text={STEP_HELP[cur.id]} /></h2>
            <div className="muted small" style={{ marginTop: 4 }}>{cur.text}</div>
          </div>

          {cur.id === 'feld' && (
            <>
              <div className="small">
                <strong>✨ {t('Empfohlene Fläche: etwa {0}', { 0: kmText(recKm2) })}</strong> <Info title={t('Empfohlene Fläche')} text={t('Berechnet aus Ping-Abstand ({0}), Anzahl Pings, Anzahl Personen ({1}) und Fortbewegung. Das ist nur ein Richtwert: die passende Grösse hängt auch von der Umgebung ab (Häuser, Wald, Wasser, Strassen). Du kannst die Fläche jederzeit selbst anpassen.', { 0: formatMinutes(config.ping.interval_minutes), 1: config.roles.players_max + config.roles.hunters_max })} />
              </div>
              <div className="muted small">{me ? t('Um deinen Standort:') : t('Karte auf den Ort schieben, dann:')}</div>
              <div className="tool-row size-row">
                <button className="size-btn primary" onClick={() => quickField(recKm2, 'kreis')}>
                  <strong>{t('◯ Kreis')}</strong><span className="small">{kmText(recKm2)}</span>
                </button>
                <button className="size-btn primary" onClick={() => quickField(recKm2, 'rechteck')}>
                  <strong>{t('▭ Rechteck')}</strong><span className="small">{kmText(recKm2)}</span>
                </button>
              </div>
              <div className="muted small">{t('Oder selbst zeichnen:')}</div>
              <div className="tool-row">
                <button onClick={draw({ kind: 'spielfeld', tool: 'Circle' })}>{t('◯ Kreis')}</button>
                <button onClick={draw({ kind: 'spielfeld', tool: 'Rectangle' })}>{t('▭ Rechteck')}</button>
                <button onClick={draw({ kind: 'spielfeld', tool: 'Polygon' })}>{t('✎ Eigene Form')}</button>
              </div>
              {field1 && editable && (
                <div className="row" style={{ alignItems: 'center', gap: 10 }}>
                  <button type="button" className="big" style={{ minWidth: 56, fontSize: 24 }} aria-label={t('Spielfeld kleiner')} onClick={() => scaleField(1 / 1.2)}>−</button>
                  <div className="spacer" style={{ textAlign: 'center' }}><strong>{kmText(areaKm2(field1))}</strong><div className="muted small">{t('Grösse des Spielfelds')}</div></div>
                  <button type="button" className="big" style={{ minWidth: 56, fontSize: 24 }} aria-label={t('Spielfeld grösser')} onClick={() => scaleField(1.2)}>+</button>
                </div>
              )}
              {field1 && <div className="muted small">{t('Antippen = Ecken verschieben')}</div>}
            </>
          )}

          {cur.id === 'treff' && (
            <>
              <button className="primary" onClick={meetHere} disabled={!field1 || !me}>{t('📍 Hier (mein Standort)')}</button>
              <button onClick={autoPoints} disabled={!field1}>{t('✨ Automatisch')}</button>
              <button onClick={draw({ kind: 'treffpunkt', tool: 'Marker' })} disabled={!field1}>{t('👆 Selbst antippen')}</button>
              {!me && <div className="muted small">{t('Warte auf deinen Standort … (Standort erlauben)')}</div>}
            </>
          )}

          {cur.id === 'exit' && (
            <>
              <button className="primary" onClick={() => autoExits(4)} disabled={!field1}>{t('✨ 4 Fluchtpunkte automatisch')}</button>
              <button onClick={draw({ kind: 'exit', tool: 'Marker' })} disabled={!field1}>{t('👆 Fluchtpunkte selbst setzen')}</button>
              <div className="muted small">{features.filter((f) => f.properties.kind === 'exit').length} {t('von mindestens 4 Kandidaten gesetzt.')}</div>
            </>
          )}

          {cur.id === 'klein' && (
            <>
            <div className="chips">
              {([['aus', t('Nie')], ['auto', t('Automatisch')], ['manuell', t('Selbst zeichnen')]] as const).map(([v, t]) => (
                <button key={v} type="button" className={`chip${shrink === v ? ' on' : ''}`} onClick={() => setZone('shrink_mode', v)}>{t}</button>
              ))}
            </div>
            {shrink !== 'aus' && (
              <>
                <NumberRow label={t('Kleiner alle (Minuten, Jagd dauert {0})', { 0: durationText(huntMinutes(config)) })} value={config.zone.shrink_every_minutes} min={5} max={limits['zone.shrink_every_minutes']?.max ?? 1440} step={5} onChange={(v) => setZone('shrink_every_minutes', v)} />
                <div className="muted small">{phases} {t('Phasen → das Spielfeld ändert sich')} {Math.max(0, phases - 1)}{t('-mal.')}</div>
                {shrink === 'auto' && (
                  <NumberRow label={t('Kleiner um (% Fläche je Schritt)')} value={config.zone.auto_shrink_percent} min={1} max={80} step={5} onChange={(v) => setZone('auto_shrink_percent', v)} />
                )}
                <NumberRow label={t('Vorher ankündigen (Minuten)')} value={config.zone.shrink_announce_minutes} min={0} max={limits['zone.shrink_announce_minutes']?.max ?? 1440} step={5} onChange={(v) => setZone('shrink_announce_minutes', v)} />
                {shrink === 'auto' && <div className="muted small">{t('Es wird Richtung Fluchtpunkt kleiner (ohne Fluchtpunkt Richtung Mitte).')}</div>}
                {shrink === 'manuell' && phases > 1 && (
                  <div className="stack">
                    {Array.from({ length: phases - 1 }, (_, i) => i + 2).map((p) => {
                      const own = features.some((f) => f.properties.kind === 'spielfeld' && f.properties.day_index === p);
                      return (
                        <div key={p} className="phase-row">
                          <span className="spacer">{own ? '✓' : '○'} {t('Phase')} {p}</span>
                          <button className="small" onClick={() => copyShrunk(p, 25)}>{t('Vorherige −25 %')}</button>
                          <button className="small" onClick={draw({ kind: 'spielfeld', tool: 'Polygon', phase: p })}>{t('✎ Zeichnen')}</button>
                        </div>
                      );
                    })}
                    <div className="muted small">{t('Tipp: „Vorherige −25 %“ legt eine kleinere Kopie an, deren Ecken du danach verschieben kannst.')}</div>
                  </div>
                )}
                {phases > 1 && (
                  <label className="field">
                    <span>{t('Vorschau:')} {unitLabel} {preview} {phaseFields[preview - 1] ? `(${areaKm2(phaseFields[preview - 1]).toFixed(2)} km²)` : ''}</span>
                    <input type="range" min={1} max={phases} value={preview} onChange={(e) => setPreview(+e.target.value)} />
                  </label>
                )}
              </>
            )}
            </>
          )}

          {cur.id === 'gefahr' && (
            <>
            <button onClick={loadHazards} disabled={!field1 || hazardBusy}>{hazardBusy ? t('Suche …') : t('🔎 Gefahrenstellen automatisch vorschlagen')}</button>
            {hazards && hazards.length > 0 && (
              <div className="stack">
                <div className="row"><strong className="spacer">{hazards.length} {t('Vorschläge')}</strong><button className="small primary" onClick={() => takeHazards(hazards)}>{t('Alle übernehmen')}</button></div>
                {hazards.map((h) => (
                  <div key={h.key} className="phase-row">
                    <span className="spacer">{restrictedInfo(h.type).icon} {h.name} <span className="muted small">({restrictedInfo(h.type).label})</span></span>
                    <button className="small" onClick={() => takeHazards([h])}>{t('Übernehmen')}</button>
                  </div>
                ))}
              </div>
            )}
            <label className="field">
              {t('Art der Gefahr')}
              <select value={restrictedType} onChange={(e) => setRestrictedType(e.target.value)}>
                {Object.entries(RESTRICTED_TYPES).map(([k, v]) => <option key={k} value={k}>{v.icon} {v.label}</option>)}
              </select>
            </label>
            <div className="tool-row">
              <button onClick={draw({ kind: 'sperrzone', tool: 'Polygon', restrictedType })} disabled={!field1}>{t('✎ Fläche')}</button>
              <button onClick={draw({ kind: 'sperrzone', tool: 'Line', restrictedType, widthM: lineWidth })} disabled={!field1}>{t('〰 Entlang Strasse/Gleis')}</button>
            </div>
            <NumberRow label={t('Breite bei Linien (m)')} value={lineWidth} min={5} max={200} step={5} onChange={setLineWidth} />
            </>
          )}

          {cur.id === 'fertig' && (
            <>
              {issues.length === 0 && <div className="notice success">{t('Alles in Ordnung. Die Karte ist bereit.')}</div>}
              {issues.map((i, n) => <div key={n} className={`notice ${i.level === 'error' ? 'error' : 'warning'}`}>{i.text}</div>)}
              {sticking.length > 0 && (
                <div className="notice warning">
                  {sticking.length} {t('Zone(n) ragen über das Spielfeld hinaus.')}{' '}
                  <button className="small" onClick={clipAll}>{t('Zuschneiden')}</button>
                </div>
              )}
              {dirty && !setup && <button className="primary" onClick={save} disabled={busy || !loaded}>{busy ? t('Speichere …') : t('Karte speichern')}</button>}
            </>
          )}

          <div className="row wizard-nav">
            <button onClick={() => goStep(stepIdx - 1)} disabled={stepIdx === 0}>{t('← Zurück')}</button>
            <span className="spacer" />
            {stepIdx < steps.length - 1 && (
              <button className={cur.done || cur.optional ? 'primary' : ''} onClick={() => goStep(stepIdx + 1)}>
                {cur.done || cur.optional ? t('Weiter →') : t('Überspringen →')}
              </button>
            )}
          </div>
          {setup && (
            <div className="sticky-cta">
              <button className="primary block big" disabled={busy || !loaded || !field1}
                onClick={async () => { if (!dirty || (await save())) navigate(`/spiel/${id}`, { replace: true }); }}>
                {busy ? t('Speichere …') : field1 ? t('Fertig: Karte speichern und Freunde einladen') : t('Zuerst das Spielfeld zeichnen')}
              </button>
            </div>
          )}
        </div>
      )}

      <details className="card" style={{ marginTop: 12 }}>
        <summary><strong>{t('Alles auf der Karte ({0})', { 0: items.length })}</strong> <span className="muted small">{t('· Spielfeld, Punkte und Gefahrenzonen · zum Ändern antippen')}</span></summary>
        {items.length === 0 && <span className="muted small">{t('Noch nichts gesetzt.')}</span>}
        <ul className="list zone-list">
          {items.map((it) => {
            const p = it.feature.properties;
            const size = it.feature.geometry.type === 'Point' ? `${p.radius_m ?? 30} m` : `${areaKm2(asArea(it.feature)).toFixed(2)} km²`;
            return (
              <li key={it.key} className={it.key === selected ? 'selected' : ''} onClick={() => select(it.key)}>
                <span>{p.kind === 'sperrzone' ? restrictedInfo(p.restricted_type).icon : ICON[p.kind]}</span>
                <span className="spacer">
                  {ZONE_INFO[p.kind].label}
                  {p.kind === 'spielfeld' && p.day_index ? ` · ${unitLabel} ${p.day_index}` : ''}
                  {p.kind === 'sperrzone' && <span className="muted small"> · {restrictedInfo(p.restricted_type).label}</span>}
                </span>
                <span className="muted small">{size}</span>
              </li>
            );
          })}
        </ul>
        {editable && (
          <div className="row" style={{ marginTop: 12 }}>
            <button className="small" onClick={exportJson}>{t('GeoJSON exportieren')}</button>
            <label className="button small">
              {t('GeoJSON importieren')}
              <input type="file" accept=".json,.geojson,application/geo+json" hidden disabled={!loaded} onChange={(e) => e.target.files?.[0] && importJson(e.target.files[0])} />
            </label>
          </div>
        )}
      </details>

      {editable && dirty && (
        <div className="save-bar">
          <span className="spacer small">{t('Ungespeicherte Änderungen')}</span>
          <button className="primary" onClick={save} disabled={busy || !loaded}>{busy ? t('Speichere …') : t('Speichern')}</button>
        </div>
      )}
    </div>
  );
}

function NumberRow({ label, value, min, max, step, onChange }: { label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void }) {
  const clamp = (v: number) => Math.min(max, Math.max(min, v));
  return (
    <div className="quick-row">
      <span className="spacer">{label}</span>
      <div className="stepper">
        <button type="button" aria-label={t('{0} weniger', { 0: label })} disabled={value <= min} onClick={() => onChange(clamp(value - step))}>−</button>
        <NumberField label={label} value={value} min={min} max={max} onChange={onChange} />
        <button type="button" aria-label={t('{0} mehr', { 0: label })} disabled={value >= max} onClick={() => onChange(clamp(value + step))}>+</button>
      </div>
    </div>
  );
}

function ZoneProps({ sel, editable, phases, unitLabel, update, remove, close }: {
  sel: Item; editable: boolean; phases: number; unitLabel: string;
  update: (key: string, patch: Partial<MapFeature['properties']>) => void; remove: (key: string) => void; close: () => void;
}) {
  const p = sel.feature.properties;
  const isPoint = sel.feature.geometry.type === 'Point';
  const areaKinds = ZONE_KINDS.filter((k) => !ZONE_INFO[k].point);
  return (
    <div className="card stack zone-props">
      <div className="row">
        <h2 className="spacer" style={{ margin: 0 }}>{p.kind === 'sperrzone' ? restrictedInfo(p.restricted_type).icon : ICON[p.kind]} {ZONE_INFO[p.kind].label} <Info title={ZONE_HELP[p.kind].title} text={ZONE_HELP[p.kind].text} /></h2>
        <button className="ghost small" onClick={close} aria-label={t('Schliessen')}>✕</button>
      </div>
      {editable && !isPoint && <div className="muted small">{t('Ecken ziehen zum Ändern, Mitte einer Kante ziehen für eine neue Ecke, ganze Zone verschieben mit Ziehen.')}</div>}
      {editable && isPoint && <div className="muted small">{t('Zum Verschieben das Symbol gedrückt halten und ziehen.')}</div>}
      {!isPoint && (
        <label className="field">
          {t('Art')}
          <select value={p.kind} disabled={!editable} onChange={(e) => update(sel.key, { kind: e.target.value as ZoneKind })}>
            {areaKinds.map((k) => <option key={k} value={k}>{ICON[k]} {ZONE_INFO[k].label}</option>)}
          </select>
        </label>
      )}
      {p.kind === 'sperrzone' && (
        <>
          <label className="field">
            {t('Art der Gefahr')}
            <select value={p.restricted_type ?? 'andere'} disabled={!editable} onChange={(e) => update(sel.key, { restricted_type: e.target.value })}>
              {Object.entries(RESTRICTED_TYPES).map(([k, v]) => <option key={k} value={k}>{v.icon} {v.label}</option>)}
            </select>
          </label>
          <label className="check">
            <input type="checkbox" disabled={!editable} checked={!!p.crossing_allowed} onChange={(e) => update(sel.key, { crossing_allowed: e.target.checked })} />
            <span>{t('Überqueren erlaubt (z. B. Brücke), Aufenthalt nicht')}</span>
          </label>
        </>
      )}
      {p.kind === 'spielfeld' && phases > 1 && (
        <>
          <label className="field">
            {t('Gilt ab')}
            <select value={p.day_index ?? ''} disabled={!editable} onChange={(e) => update(sel.key, { day_index: e.target.value ? +e.target.value : null })}>
              <option value="">{t('Von Anfang an')}</option>
              {Array.from({ length: phases }, (_, i) => <option key={i} value={i + 1}>{unitLabel} {i + 1}</option>)}
            </select>
          </label>
          {(p.day_index ?? 1) > 1 && (
            <label className="check">
              <input type="checkbox" disabled={!editable} checked={!!p.grows} onChange={(e) => update(sel.key, { grows: e.target.checked })} />
              <span>{t('Wird bewusst grösser (statt kleiner)')}</span>
            </label>
          )}
        </>
      )}
      {editable && <button className="ghost" onClick={() => remove(sel.key)}>{isPoint ? t('🗑 Punkt löschen') : t('🗑 Löschen')}</button>}
    </div>
  );
}
