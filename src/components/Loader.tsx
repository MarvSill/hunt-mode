import { t } from '../i18n';

/**
 * Ladeanimation: Radar mit Suchstrahl und aufblinkenden Pings (Stile in index.html,
 * damit dieselbe Animation schon beim Öffnen der App da ist, bevor der Code geladen ist).
 */
export default function Loader({ text, inline = false }: { text?: string; inline?: boolean }) {
  const label = text ?? t('Lade …');
  return (
    <div className={`hm-loader${inline ? ' inline' : ''}`} role="status" aria-label={label}>
      <div className="hm-radar" aria-hidden="true">
        <div className="hm-sweep" />
        <i className="hm-blip b1" />
        <i className="hm-blip b2" />
        <i className="hm-blip b3" />
        <div className="hm-core" />
      </div>
      {!inline && <div className="hm-brand">HUNT MODE</div>}
      <div className="hm-loader-text"><span className="hm-dots">{label.replace(/\s*…$/, '')}</span></div>
    </div>
  );
}
