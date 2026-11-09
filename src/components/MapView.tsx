/**
 * Karte im Spiel und in der Wiederholung (MapLibre): Kartenstil und 3D wählt jede Person selbst
 * (Knöpfe auf der Karte oder im Profil). Zonen, Punkte und Marker liegen über der Grundkarte.
 */
import maplibregl, { type GeoJSONSource, type StyleSpecification } from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useEffect, useRef } from 'react';
import { bbox, circle, pointOnFeature } from '@turf/turf';
import { ZONE_INFO, type MapFeature } from '../lib/engine';
import { restrictedInfo } from '../lib/geo';
import { resolveStyle, setMapSettings, useMapSettings } from '../lib/mapStyle';
import MapStylePicker from './MapStylePicker';
import { t } from '../i18n';
import { esc } from './leafletZones';

export interface Marker {
  id: string;
  lat: number;
  lng: number;
  label: string;
  color: string;
  kind: 'me' | 'player' | 'hunter' | 'ping' | 'fake' | 'challenge' | 'emergency' | 'hotel' | 'pick';
  accuracy?: number | null;
  opacity?: number;
  pulse?: boolean;
  popup?: string;
  /** Kurzer Text im Punkt, z. B. die Nummer der Person ("3", "H1"). */
  text?: string;
}

interface Props {
  zones: MapFeature[];
  markers: Marker[];
  lines?: { id: string; points: [number, number][]; color: string }[];
  onClick?: (lat: number, lng: number) => void;
  fitKey?: string | number;
  height?: string;
  showDay?: number;
}

const POINT_ICON: Record<string, string> = { treffpunkt: '📍', exit: '🏁' };
const TILT = 50;

type FC = GeoJSON.FeatureCollection;
const empty = (): FC => ({ type: 'FeatureCollection', features: [] });

/** Zonen als Flächen mit Zustand (aktuell, später, vorbei) für die Darstellung. */
function zoneData(zones: MapFeature[], day?: number): { areas: FC; rings: FC } {
  const areas: GeoJSON.Feature[] = [];
  const rings: GeoJSON.Feature[] = [];
  for (const f of zones) {
    const k = f.properties.kind;
    if (!ZONE_INFO[k]) continue;
    const color = f.properties.color || ZONE_INFO[k].color;
    if (f.geometry.type === 'Point') {
      if (k === 'exit') {
        const [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
        rings.push({ ...circle([lng, lat], (f.properties.radius_m || 30) / 1000, { steps: 48 }), properties: { color } });
      }
      continue;
    }
    const di = f.properties.day_index;
    const state = k !== 'spielfeld' || di == null || day == null ? 'now' : di > day ? 'later' : di < day ? 'past' : 'now';
    areas.push({ type: 'Feature', geometry: f.geometry, properties: { kind: k, color, state, name: f.properties.name || ZONE_INFO[k].label } });
  }
  return { areas: { type: 'FeatureCollection', features: areas }, rings: { type: 'FeatureCollection', features: rings } };
}

/** Schraffur für Gefahrenzonen als kleines Bild. */
function hatchImage(): ImageData {
  const s = 12;
  const c = document.createElement('canvas');
  c.width = s;
  c.height = s;
  const g = c.getContext('2d')!;
  g.fillStyle = 'rgba(248,81,73,0.18)';
  g.fillRect(0, 0, s, s);
  g.strokeStyle = 'rgba(248,81,73,0.85)';
  g.lineWidth = 2.5;
  g.beginPath();
  g.moveTo(0, s);
  g.lineTo(s, 0);
  g.moveTo(-s / 2, s / 2);
  g.lineTo(s / 2, -s / 2);
  g.moveTo(s / 2, s * 1.5);
  g.lineTo(s * 1.5, s / 2);
  g.stroke();
  return g.getImageData(0, 0, s, s);
}

function markerEl(m: Marker): HTMLElement {
  const d = document.createElement('div');
  const ping = m.kind === 'ping' || m.kind === 'fake';
  // Mit Nummer etwas grösser, damit sie gut lesbar ist; Pings als abgerundete Raute, Personen rund.
  const size = m.text ? (m.text.length > 2 ? 30 : 26) : ping ? 16 : m.kind === 'me' ? 20 : 18;
  d.className = `hm-mk${m.pulse ? ' pulse' : ''}${m.kind === 'emergency' ? ' sos' : ''}${m.text ? ' num' : ''}${ping ? ' ping' : ''}`;
  d.style.cssText = `width:${size}px;height:${size}px;background:${m.color};opacity:${m.opacity ?? 1};border-radius:${ping ? (m.text ? '8px' : '3px') : '50%'};${ping && !m.text ? 'transform:rotate(45deg);' : ''}`;
  if (m.text) d.textContent = m.text;
  d.title = m.label;
  return d;
}

function pointEl(kind: string): HTMLElement {
  const d = document.createElement('div');
  d.className = 'point-pin';
  d.style.borderColor = ZONE_INFO[kind as keyof typeof ZONE_INFO]?.color ?? '#fff';
  d.textContent = POINT_ICON[kind] ?? '•';
  return d;
}

function badgeEl(f: MapFeature): HTMLElement {
  const d = document.createElement('div');
  const info = restrictedInfo(f.properties.restricted_type);
  d.className = 'zone-badge danger';
  d.title = info.label;
  d.textContent = `⚠️${info.icon === '⚠️' ? '' : info.icon}`;
  return d;
}

/** 3D-Gebäude: vorhandene Ebenen nutzen oder passend zur Kartenquelle ergänzen. */
function ensureBuildings(m: maplibregl.Map, dark: boolean) {
  const style = m.getStyle();
  const own = style.layers.filter((l) => l.type === 'fill-extrusion' && l.id !== 'hm-3d');
  if (own.length || m.getLayer('hm-3d')) return;
  const firstSymbol = style.layers.find((l) => l.type === 'symbol')?.id;
  const src = m.getSource('openmaptiles') ? ['openmaptiles', 'building', 'render_height'] : m.getSource('protomaps') ? ['protomaps', 'buildings', 'height'] : null;
  if (!src) return;
  m.addLayer({
    id: 'hm-3d', type: 'fill-extrusion', source: src[0], 'source-layer': src[1], minzoom: 13,
    paint: {
      'fill-extrusion-color': dark ? '#222c3a' : '#d9d4cc',
      'fill-extrusion-height': ['coalesce', ['get', src[2]], 10],
      'fill-extrusion-base': 0,
      'fill-extrusion-opacity': dark ? 0.9 : 0.75,
    },
  }, firstSymbol);
}

function setBuildingsVisible(m: maplibregl.Map, on: boolean) {
  for (const l of m.getStyle().layers) {
    if (l.type === 'fill-extrusion') m.setLayoutProperty(l.id, 'visibility', on ? 'visible' : 'none');
  }
}

function addOverlays(m: maplibregl.Map, dark: boolean, tilt: boolean) {
  if (!m.hasImage('hm-hatch')) m.addImage('hm-hatch', hatchImage());
  ensureBuildings(m, dark);
  setBuildingsVisible(m, tilt);
  const firstSymbol = m.getStyle().layers.find((l) => l.type === 'symbol')?.id;
  for (const id of ['hm-zones', 'hm-rings', 'hm-lines', 'hm-acc']) if (!m.getSource(id)) m.addSource(id, { type: 'geojson', data: empty() });
  const field = ['all', ['==', ['get', 'kind'], 'spielfeld']] as maplibregl.FilterSpecification;
  m.addLayer({ id: 'hm-field-fill', type: 'fill', source: 'hm-zones', filter: ['all', field, ['==', ['get', 'state'], 'now']] as maplibregl.FilterSpecification,
    paint: { 'fill-color': ['get', 'color'], 'fill-opacity': dark ? 0.1 : 0.07 } }, firstSymbol);
  m.addLayer({ id: 'hm-danger', type: 'fill', source: 'hm-zones', filter: ['==', ['get', 'kind'], 'sperrzone'], paint: { 'fill-pattern': 'hm-hatch' } }, firstSymbol);
  m.addLayer({ id: 'hm-danger-line', type: 'line', source: 'hm-zones', filter: ['==', ['get', 'kind'], 'sperrzone'], paint: { 'line-color': '#f85149', 'line-width': 2 } });
  m.addLayer({ id: 'hm-field-glow', type: 'line', source: 'hm-zones', filter: ['all', field, ['==', ['get', 'state'], 'now']] as maplibregl.FilterSpecification,
    paint: { 'line-color': ['get', 'color'], 'line-width': 12, 'line-opacity': dark ? 0.35 : 0.22, 'line-blur': 7 } });
  m.addLayer({ id: 'hm-field-line', type: 'line', source: 'hm-zones', filter: ['all', field, ['==', ['get', 'state'], 'now']] as maplibregl.FilterSpecification,
    paint: { 'line-color': ['get', 'color'], 'line-width': 3 } });
  m.addLayer({ id: 'hm-field-later', type: 'line', source: 'hm-zones', filter: ['all', field, ['==', ['get', 'state'], 'later']] as maplibregl.FilterSpecification,
    paint: { 'line-color': ['get', 'color'], 'line-width': 2.5, 'line-dasharray': [2, 2] } });
  m.addLayer({ id: 'hm-field-past', type: 'line', source: 'hm-zones', filter: ['all', field, ['==', ['get', 'state'], 'past']] as maplibregl.FilterSpecification,
    paint: { 'line-color': ['get', 'color'], 'line-width': 2, 'line-opacity': 0.25 } });
  m.addLayer({ id: 'hm-rings', type: 'line', source: 'hm-rings', paint: { 'line-color': dark ? '#f0f6fc' : '#57606a', 'line-width': 2, 'line-dasharray': [2, 2] } });
  m.addLayer({ id: 'hm-acc', type: 'fill', source: 'hm-acc', paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.1 } });
  m.addLayer({ id: 'hm-lines', type: 'line', source: 'hm-lines', paint: { 'line-color': ['get', 'color'], 'line-width': 3, 'line-opacity': 0.75 } });
}

/** Eigene Knöpfe: Vollbild, auf das Spielfeld, eigener Standort, 3D an/aus, Kartenstil wechseln. */
class Buttons implements maplibregl.IControl {
  private box?: HTMLDivElement;
  constructor(private opts: { wrap: () => HTMLElement | null; fit: () => void; tilt: () => boolean }) {}
  onAdd(m: maplibregl.Map) {
    const box = document.createElement('div');
    box.className = 'maplibregl-ctrl maplibregl-ctrl-group hm-map-buttons';
    const btn = (text: string, title: string, fn: (b: HTMLButtonElement) => void) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = text;
      b.title = title;
      b.setAttribute('aria-label', title);
      b.addEventListener('click', (e) => { e.stopPropagation(); fn(b); });
      box.appendChild(b);
      return b;
    };
    btn('⛶', t('Vollbild'), (b) => {
      const w = this.opts.wrap();
      if (!w) return;
      const on = w.classList.toggle('map-fullscreen');
      document.body.classList.toggle('no-scroll', on);
      b.textContent = on ? '✕' : '⛶';
      setTimeout(() => m.resize(), 50);
    });
    btn('⌖', t('Auf das Spielfeld zoomen'), () => this.opts.fit());
    btn('◎', t('Mein Standort'), () => {
      navigator.geolocation?.getCurrentPosition((p) => m.easeTo({ center: [p.coords.longitude, p.coords.latitude], zoom: Math.max(m.getZoom(), 16) }), () => undefined, { timeout: 8000 });
    });
    btn('3D', t('3D an/aus'), () => setMapSettings({ tilt: !this.opts.tilt() }));
    this.box = box;
    return box;
  }
  onRemove() {
    this.box?.remove();
  }
}

export default function MapView({ zones, markers, lines, onClick, fitKey, height = '60dvh', showDay }: Props) {
  const settings = useMapSettings();
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<maplibregl.Map | null>(null);
  const ready = useRef(false);
  const htmlMarkers = useRef<maplibregl.Marker[]>([]);
  const zoneMarkers = useRef<maplibregl.Marker[]>([]);
  const clickRef = useRef(onClick);
  clickRef.current = onClick;
  const fitted = useRef<string | number | undefined>(undefined);
  const centered = useRef(false);
  const pendingFit = useRef<maplibregl.LngLatBoundsLike | null>(null);
  const props = useRef({ zones, markers, lines, showDay });
  props.current = { zones, markers, lines, showDay };
  const settingsRef = useRef(settings);
  settingsRef.current = settings;

  function bounds(): maplibregl.LngLatBoundsLike | null {
    const areas = props.current.zones.filter((z) => z.geometry.type !== 'Point' && ZONE_INFO[z.properties.kind]);
    const list = areas.length ? areas : props.current.zones;
    if (!list.length) return null;
    const [w, s, e, n] = bbox({ type: 'FeatureCollection', features: list as GeoJSON.Feature[] });
    return [[w, s], [e, n]];
  }

  function fit(animate: boolean) {
    const m = map.current;
    const b = bounds();
    if (!m || !b) return false;
    if (el.current && el.current.clientWidth === 0) {
      pendingFit.current = b;
      return true;
    }
    m.fitBounds(b, { padding: 24, duration: animate ? 600 : 0, pitch: settingsRef.current.tilt ? TILT : 0 });
    return true;
  }

  function drawZones() {
    const m = map.current;
    if (!m || !ready.current) return;
    const { areas, rings } = zoneData(props.current.zones, props.current.showDay);
    (m.getSource('hm-zones') as GeoJSONSource | undefined)?.setData(areas);
    (m.getSource('hm-rings') as GeoJSONSource | undefined)?.setData(rings);
    for (const mk of zoneMarkers.current) mk.remove();
    zoneMarkers.current = [];
    for (const f of props.current.zones) {
      const k = f.properties.kind;
      if (!ZONE_INFO[k]) continue;
      const name = f.properties.name || ZONE_INFO[k].label;
      if (f.geometry.type === 'Point') {
        const [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
        const mk = new maplibregl.Marker({ element: pointEl(k) }).setLngLat([lng, lat])
          .setPopup(new maplibregl.Popup({ offset: 18, closeButton: false }).setHTML(esc(`${k === 'exit' ? t('FLUCHTPUNKT: ') : ''}${name}`)))
          .addTo(m);
        zoneMarkers.current.push(mk);
      } else if (k === 'sperrzone') {
        const [lng, lat] = pointOnFeature(f as GeoJSON.Feature).geometry.coordinates;
        const mk = new maplibregl.Marker({ element: badgeEl(f) }).setLngLat([lng, lat])
          .setPopup(new maplibregl.Popup({ offset: 12, closeButton: false }).setHTML(esc(t('GEFAHR ({0}): ', { 0: restrictedInfo(f.properties.restricted_type).label }) + name)))
          .addTo(m);
        zoneMarkers.current.push(mk);
      }
    }
  }

  function drawMarkers() {
    const m = map.current;
    if (!m || !ready.current) return;
    const { markers: list, lines: ls } = props.current;
    if (!centered.current && list.length && !bounds()) {
      m.jumpTo({ center: [list[0].lng, list[0].lat], zoom: 15 });
      centered.current = true;
    }
    (m.getSource('hm-lines') as GeoJSONSource | undefined)?.setData({
      type: 'FeatureCollection',
      features: (ls ?? []).filter((l) => l.points.length > 1).map((l) => ({
        type: 'Feature', properties: { color: l.color }, geometry: { type: 'LineString', coordinates: l.points.map(([la, ln]) => [ln, la]) },
      })),
    });
    (m.getSource('hm-acc') as GeoJSONSource | undefined)?.setData({
      type: 'FeatureCollection',
      features: list.filter((x) => x.accuracy && (x.accuracy > 15 || x.kind === 'hotel') && ['me', 'player', 'hunter', 'hotel'].includes(x.kind))
        .map((x) => ({ ...circle([x.lng, x.lat], (x.accuracy ?? 0) / 1000, { steps: 40 }), properties: { color: x.color } })),
    });
    for (const mk of htmlMarkers.current) mk.remove();
    htmlMarkers.current = list.map((x) => {
      const mk = new maplibregl.Marker({ element: markerEl(x) }).setLngLat([x.lng, x.lat])
        .setPopup(new maplibregl.Popup({ offset: 12, closeButton: false }).setHTML(esc(x.popup ? `${x.label} · ${x.popup}` : x.label)))
        .addTo(m);
      if (x.kind === 'me') mk.getElement().style.zIndex = '5';
      return mk;
    });
  }

  // Karte anlegen
  useEffect(() => {
    if (!el.current || map.current) return;
    const s = resolveStyle(settingsRef.current.style);
    const m = new maplibregl.Map({
      container: el.current,
      style: s.url as string | StyleSpecification,
      center: [8.5417, 47.3769],
      zoom: 13,
      pitch: settingsRef.current.tilt ? TILT : 0,
      maxPitch: 70,
      attributionControl: { compact: true },
    });
    m.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), 'top-right');
    m.addControl(new Buttons({ wrap: () => el.current?.parentElement ?? null, fit: () => fit(true), tilt: () => settingsRef.current.tilt }), 'top-right');
    m.on('click', (e) => clickRef.current?.(e.lngLat.lat, e.lngLat.lng));
    m.on('style.load', () => {
      addOverlays(m, resolveStyle(settingsRef.current.style).dark, settingsRef.current.tilt);
      ready.current = true;
      drawZones();
      drawMarkers();
      if (!centered.current && fit(false)) {
        fitted.current = fitKeyRef.current;
        centered.current = true;
      }
    });
    map.current = m;
    const ro = new ResizeObserver(() => {
      m.resize();
      if (pendingFit.current && el.current && el.current.clientWidth > 0) {
        m.fitBounds(pendingFit.current, { padding: 24, duration: 0, pitch: settingsRef.current.tilt ? TILT : 0 });
        pendingFit.current = null;
      }
    });
    ro.observe(el.current);
    return () => {
      ro.disconnect();
      m.remove();
      map.current = null;
      ready.current = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const fitKeyRef = useRef(fitKey);
  fitKeyRef.current = fitKey;

  // Stil gewechselt: neue Grundkarte, Zonen und Marker werden in "style.load" neu gezeichnet.
  const styleId = resolveStyle(settings.style).id;
  const lastId = useRef(styleId);
  useEffect(() => {
    const m = map.current;
    if (!m || lastId.current === styleId) return;
    lastId.current = styleId;
    const styleUrl = resolveStyle(settings.style).url;
    ready.current = false;
    // Ganz neu laden (ohne Diff), damit "style.load" sicher kommt und die eigenen Ebenen neu gezeichnet werden.
    m.setStyle(styleUrl as unknown as StyleSpecification, { diff: false });
  }, [styleId]); // eslint-disable-line react-hooks/exhaustive-deps

  // 3D an/aus
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    m.easeTo({ pitch: settings.tilt ? TILT : 0, duration: 700 });
    if (ready.current) setBuildingsVisible(m, settings.tilt);
  }, [settings.tilt]);

  useEffect(() => {
    drawZones();
    if (ready.current && (fitted.current !== fitKey || fitKey === undefined) && fit(false)) {
      fitted.current = fitKey;
      centered.current = true;
    }
  }, [zones, fitKey, showDay]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    drawMarkers();
  }, [markers, lines]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="map-wrap">
      <div ref={el} className="map" style={{ height }} />
      <div className="map-overlay-tl"><MapStylePicker /></div>
    </div>
  );
}
