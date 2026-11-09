import { t } from '../i18n';
import { MAP_STYLES, setMapSettings, useMapSettings, type MapStyleId } from '../lib/mapStyle';

/** Kartenstil und 3D wählen (gilt nur für dieses Gerät). */
export default function MapSettingsBox() {
  const s = useMapSettings();
  const options: { id: MapStyleId; label: string; hint: string }[] = [
    { id: 'auto', label: 'Automatisch', hint: 'hell am Tag, dunkel im Dunkelmodus' },
    ...MAP_STYLES.map((x) => ({ id: x.id, label: x.label, hint: x.hint })),
  ];
  return (
    <div className="stack">
      <div className="chips" role="group" aria-label={t('Kartenstil')}>
        {options.map((o) => (
          <button key={o.id} type="button" className={`chip${s.style === o.id ? ' on' : ''}`} aria-pressed={s.style === o.id} onClick={() => setMapSettings({ style: o.id })}>
            {t(o.label)}
          </button>
        ))}
      </div>
      <div className="muted small">{t(options.find((o) => o.id === s.style)?.hint ?? '')}</div>
      <label className="check">
        <input type="checkbox" checked={s.tilt} onChange={(e) => setMapSettings({ tilt: e.target.checked })} />
        <span>{t('3D-Ansicht im Spiel (geneigt, mit Gebäuden)')}</span>
      </label>
      <div className="muted small">{t('Auf der Karte kannst du beides auch mit den Knöpfen 3D und 🎨 wechseln. Beim Zeichnen der Karte bleibt sie flach, damit man genau zeichnen kann.')}</div>
    </div>
  );
}
