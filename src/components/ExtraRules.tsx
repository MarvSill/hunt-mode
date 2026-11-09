import { useState } from 'react';
import { t } from '../i18n';

/** Eigene Zusatzregeln als Text, die alle in der Lobby und im Spiel sehen. */
interface Props {
  rules: string[];
  readOnly?: boolean;
  onChange?: (rules: string[]) => void;
  /** Ohne eigene Karte und Titel (z. B. in einem aufklappbaren Bereich). */
  bare?: boolean;
}

export default function ExtraRules({ rules, readOnly, onChange, bare }: Props) {
  const [draft, setDraft] = useState('');
  function add() {
    const t = draft.trim();
    if (!t || !onChange || rules.length >= 30) return;
    onChange([...rules, t.slice(0, 300)]);
    setDraft('');
  }
  return (
    <div className={bare ? 'stack' : 'card stack'}>
      {!bare && <h2 style={{ margin: 0 }}>{t('Eigene Zusatzregeln')}</h2>}
      {!readOnly && <p className="muted small" style={{ margin: 0 }}>{t('Alles, was die App nicht kennt, z. B. „Kein Taxi nach 22 Uhr“ oder „Hunter tragen Warnweste“. Alle sehen diese Regeln in der Lobby und im Spiel.')}</p>}
      {rules.length > 0 ? (
        <ol className="extra-rules">
          {rules.map((r, i) => (
            <li key={i}>
              <span className="spacer">{r}</span>
              {!readOnly && onChange && (
                <button type="button" className="ghost small" aria-label={t('Regel entfernen')} onClick={() => onChange(rules.filter((_, j) => j !== i))}>✕</button>
              )}
            </li>
          ))}
        </ol>
      ) : (
        readOnly && <span className="muted small">{t('Keine.')}</span>
      )}
      {!readOnly && onChange && (
        <div className="row">
          <input className="spacer" style={{ minWidth: 0 }} placeholder={t('Neue Regel')} maxLength={300} value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } }} />
          <button type="button" onClick={add} disabled={!draft.trim() || rules.length >= 30}>{t('+ Dazu')}</button>
        </div>
      )}
    </div>
  );
}
