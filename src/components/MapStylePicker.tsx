import { t } from '../i18n';
import { MAP_STYLE_OPTIONS, setMapSettings, useMapSettings, type MapStyleId } from '../lib/mapStyle';

/** Auswahl der Kartenart direkt auf der Karte (gilt sofort und für dieses Gerät). */
export default function MapStylePicker() {
  const s = useMapSettings();
  return (
    <label className="map-style-picker">
      <span aria-hidden="true">🗺️</span>
      <select aria-label={t('Kartenstil')} value={s.style} onChange={(e) => setMapSettings({ style: e.target.value as MapStyleId })}>
        {MAP_STYLE_OPTIONS.map((o) => <option key={o.id} value={o.id}>{t(o.label)}</option>)}
      </select>
    </label>
  );
}
