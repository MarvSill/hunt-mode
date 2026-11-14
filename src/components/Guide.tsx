import { useEffect, useState } from 'react';
import { t } from '../i18n';

export interface GuideStep { target?: string; title: string; text: string }

/**
 * Helfer, der Schritt für Schritt durch eine Seite führt. Startet nur auf Wunsch.
 * `target` ist der Wert eines data-guide-Attributs; das Element wird hervorgehoben.
 */
export default function Guide({ steps, onClose }: { steps: GuideStep[]; onClose: () => void }) {
  const list = steps.filter((s) => !s.target || document.querySelector(`[data-guide="${s.target}"]`));
  const [i, setI] = useState(0);
  // Liegt das gezeigte Element weit unten (z. B. die Leiste), rückt die Karte nach oben, damit sie es nicht verdeckt.
  const [top, setTop] = useState(false);
  const step = list[Math.min(i, list.length - 1)];

  useEffect(() => {
    if (!step?.target) { setTop(false); return; }
    const el = document.querySelector(`[data-guide="${step.target}"]`);
    if (!el) return;
    el.classList.add('guide-focus');
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    const check = () => setTop(el.getBoundingClientRect().bottom > window.innerHeight - 190);
    check();
    const tm = setTimeout(check, 500);
    return () => { clearTimeout(tm); el.classList.remove('guide-focus'); };
  }, [step]);

  if (!step) return null;
  return (
    <div className={`guide-card card stack${top ? ' top' : ''}`} role="dialog" aria-label={t('Helfer')}>
      <div className="row">
        <span className="muted small spacer">{t('Helfer · Schritt {0} von {1}', { 0: i + 1, 1: list.length })}</span>
        <button type="button" className="ghost small" onClick={onClose} aria-label={t('Helfer schliessen')}>✕</button>
      </div>
      <strong>{step.title}</strong>
      <span className="small">{step.text}</span>
      <div className="row">
        <button type="button" className="small" disabled={i === 0} onClick={() => setI(i - 1)}>{t('← Zurück')}</button>
        <span className="spacer" />
        {i < list.length - 1
          ? <button type="button" className="small primary" onClick={() => setI(i + 1)}>{t('Weiter →')}</button>
          : <button type="button" className="small primary" onClick={onClose}>{t('Fertig')}</button>}
      </div>
    </div>
  );
}
