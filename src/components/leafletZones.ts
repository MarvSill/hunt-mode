/** Zonen und Punkte für den Karten-Editor (Leaflet). Die Spielkarte nutzt MapLibre (MapView). */
import L from 'leaflet';
import { pointOnFeature } from '@turf/turf';
import { ZONE_INFO, type MapFeature } from '../lib/engine';
import { restrictedInfo } from '../lib/geo';
import { t } from '../i18n';

export function zoneStyle(f: MapFeature, day?: number): L.PathOptions {
  const k = f.properties.kind;
  const info = ZONE_INFO[k] ?? ZONE_INFO.spielfeld;
  const color = f.properties.color || info.color;
  const future = k === 'spielfeld' && f.properties.day_index != null && day != null && f.properties.day_index > day;
  const past = k === 'spielfeld' && f.properties.day_index != null && day != null && f.properties.day_index < day;
  return {
    color,
    weight: k === 'spielfeld' ? 3 : 2,
    fillOpacity: k === 'spielfeld' ? (future || past ? 0 : 0.05) : k === 'sperrzone' ? 0.3 : 0.15,
    dashArray: future ? '8 8' : k === 'sperrzone' ? '6 4' : undefined,
    opacity: past ? 0.25 : 1,
    // Gefahren schraffiert (Muster in index.html).
    className: k === 'sperrzone' ? 'hm-danger' : undefined,
  };
}

export function addZones(layer: L.LayerGroup, zones: MapFeature[], day?: number) {
  for (const f of zones) {
    const k = f.properties.kind;
    // Den Wartebereich der Hunter (am Startpunkt) und entfernte Zonenarten nicht zeichnen.
    if (!ZONE_INFO[k]) continue;
    const info = ZONE_INFO[k] ?? ZONE_INFO.spielfeld;
    const name = f.properties.name || info.label;
    let l: L.Layer;
    if (f.geometry.type === 'Point') {
      const [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
      // Punkt mit Symbol; der Radius nur gestrichelt darum.
      l = L.marker([lat, lng], { icon: pointIcon(k) });
      if (k !== 'treffpunkt') {
        layer.addLayer(L.circle([lat, lng], { radius: f.properties.radius_m || 30, color: info.color, weight: 2, dashArray: '6 6', fill: false, interactive: false }));
      }
    } else {
      l = L.geoJSON(f as GeoJSON.Feature, { style: () => zoneStyle(f, day) });
    }
    const dayText = f.properties.day_index ? t(' (Phase {0})', { 0: f.properties.day_index }) : '';
    if (k === 'sperrzone') layer.addLayer(zoneBadge(f));
    // Fluchtpunkt immer beschriftet, alles andere beim Antippen.
    const permanent = k === 'exit';
    const prefix = k === 'exit' ? t('FLUCHTPUNKT: ') : k === 'sperrzone' ? t('GEFAHR ({0}): ', { 0: restrictedInfo(f.properties.restricted_type).label }) : '';
    (l as L.Path).bindTooltip(esc(`${prefix}${name}${dayText}`), permanent ? { permanent: true, direction: 'top' } : { sticky: true });
    layer.addLayer(l);
  }
}

const POINT_ICON: Record<string, string> = { treffpunkt: '📍', exit: '🏁' };

/** Punkt-Symbol für Startpunkt und Fluchtpunkt (gut antipp- und verschiebbar). */
export function pointIcon(kind: string): L.DivIcon {
  const color = ZONE_INFO[kind as keyof typeof ZONE_INFO]?.color ?? '#fff';
  return L.divIcon({
    className: '',
    html: `<div class="point-pin" style="border-color:${color}">${POINT_ICON[kind] ?? '•'}</div>`,
    iconSize: [34, 34],
    iconAnchor: [17, 17],
  });
}

/** Symbol in der Mitte einer Gefahrenzone, damit man sie sofort erkennt. */
export function zoneBadge(f: MapFeature): L.Marker {
  const k = f.properties.kind;
  let lat: number;
  let lng: number;
  if (f.geometry.type === 'Point') {
    [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
  } else {
    [lng, lat] = pointOnFeature(f as GeoJSON.Feature).geometry.coordinates;
  }
  const info = restrictedInfo(f.properties.restricted_type);
  const html = k === 'sperrzone'
    ? `<div class="zone-badge danger" title="${esc(info.label)}">⚠️${info.icon === '⚠️' ? '' : info.icon}</div>`
    : '<div class="zone-badge safe" title="Sichere Zone">🛡️</div>';
  return L.marker([lat, lng], { icon: L.divIcon({ className: '', html, iconSize: [36, 22], iconAnchor: [18, 11] }), interactive: false, keyboard: false });
}

// Tooltips rendern HTML: Namen von Nutzern immer escapen.
export function esc(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);
}
