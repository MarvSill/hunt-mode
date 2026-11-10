import { useState } from 'react';
import { t } from '../i18n';

const key = (gameId: string) => `hm-sicher-${gameId}`;

/**
 * Hinweis zu Beginn jedes Spiels: es ist nur ein Spiel, alles auf eigene Gefahr.
 * Jede Person bestätigt ihn einmal pro Spiel (gespeichert auf diesem Gerät).
 */
export default function SafetyNotice({ gameId }: { gameId: string }) {
  const [done, setDone] = useState(() => {
    try {
      return localStorage.getItem(key(gameId)) === '1';
    } catch {
      return false;
    }
  });
  const [read, setRead] = useState(false);
  if (done) return null;
  return (
    <div className="overlay" role="dialog" aria-modal="true" aria-label={t('Bevor es losgeht')}>
      <div className="card stack" style={{ maxWidth: 460, width: '100%', background: 'var(--surface)', maxHeight: '90dvh', overflowY: 'auto' }}>
        <strong style={{ fontSize: 20 }}>⚠️ {t('Bevor es losgeht')}</strong>
        <span>{t('Hunt Mode ist nur ein Spiel. Die Teilnahme ist freiwillig und auf eigene Gefahr. Jede Person ist selbst für sich verantwortlich.')}</span>
        <ul className="small" style={{ margin: 0, paddingLeft: 18 }}>
          <li>{t('Halte dich an die Verkehrsregeln und alle Gesetze. Kein Rennen über Strassen, keine Abkürzungen über Gleise oder Privatgrund.')}</li>
          <li>{t('Pass auf dich und andere auf. Kein Körperkontakt ausser beim Fangen, keine Gewalt, niemanden in Gefahr bringen.')}</li>
          <li>{t('Schau nicht nur aufs Handy, wenn du unterwegs bist. Achte auf den Verkehr und deine Umgebung.')}</li>
          <li>{t('Gefahrenzonen (Autobahnen, Gleise, grosse Gewässer) nie betreten.')}</li>
          <li>{t('Bei Gefahr oder Verletzung: SOS drücken. Das Spiel wird unterbrochen und alle werden alarmiert. Im Ernstfall sofort 117 (Polizei), 144 (Sanität) oder 112 anrufen.')}</li>
          <li>{t('Nimm Rücksicht auf Unbeteiligte. Das Spiel darf niemanden stören oder erschrecken.')}</li>
        </ul>
        <label className="check">
          <input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} />
          <span>{t('Ich habe das gelesen und spiele auf eigene Gefahr.')}</span>
        </label>
        <button className="primary block big" disabled={!read} onClick={() => {
          try {
            localStorage.setItem(key(gameId), '1');
          } catch {
            // nur für diese Sitzung
          }
          setDone(true);
        }}>{t('Verstanden')}</button>
      </div>
    </div>
  );
}
