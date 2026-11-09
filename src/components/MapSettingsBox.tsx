import { t } from '../i18n';
import { MAP_STYLE_OPTIONS, setMapSettings, useMapSettings } from '../lib/mapStyle';

/** Kartenstil und 3D wählen (gilt nur für dieses Gerät). */
export default function MapSettingsBox() {
  const s = useMapSettings();
  const options = MAP_STYLE_OPTIONS;
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
      <div className="muted small">{t('Auf jeder Karte kannst du die Kartenart oben links wechseln und 3D mit dem Knopf 3D. Beim Zeichnen der Karte bleibt sie flach, damit man genau zeichnen kann.')}</div>
    </div>
  );
}
