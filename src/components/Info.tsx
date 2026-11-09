import { useState } from 'react';
import { createPortal } from 'react-dom';
import { t } from '../i18n';

/** Kleiner ⓘ-Knopf: öffnet eine ausführliche Erklärung. */
export default function Info({ title, text }: { title: string; text: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button type="button" className="info-btn" aria-label={t('Erklärung: {0}', { 0: title })}
        onClick={(e) => { e.preventDefault(); e.stopPropagation(); setOpen(true); }}>i</button>
      {open && createPortal(
        <div className="overlay" role="dialog" aria-label={title} onClick={(e) => { e.stopPropagation(); setOpen(false); }}>
          <div className="card stack info-sheet" onClick={(e) => e.stopPropagation()}>
            <h2 style={{ margin: 0 }}>{t(title)}</h2>
            {t(text).split('\n\n').map((p, i) => <p key={i} style={{ margin: 0, whiteSpace: 'pre-line' }}>{p}</p>)}
            <button type="button" className="primary" onClick={(e) => { e.stopPropagation(); setOpen(false); }}>{t('Verstanden')}</button>
          </div>
        </div>,
        document.body,
      )}
    </>
  );
}
