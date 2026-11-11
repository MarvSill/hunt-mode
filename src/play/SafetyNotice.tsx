import { useState } from 'react';
import { api, type GameState } from '../lib/engine';
import { nameTag, type PanelProps } from './common';
import { t } from '../i18n';

/**
 * Sicherheitshinweis zu Beginn jedes Spiels: es ist nur ein Spiel, alles auf eigene Gefahr.
 * Jede Person (Spieler und Hunter) bestätigt ihn einmal pro Spiel. Erst wenn alle bestätigt haben,
 * startet der Vorsprung. Der Host kann notfalls ohne die fehlenden Bestätigungen starten.
 */
export default function SafetyNotice({ s, act }: Pick<PanelProps, 's' | 'act'>) {
  const [read, setRead] = useState(false);
  const [busy, setBusy] = useState(false);
  const mustConfirm = ['spieler', 'hunter', 'zentrale'].includes(s.me.role) && !s.me.safety_ok;
  if (mustConfirm) {
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
          <div className="muted small">{t('Das Spiel und der Vorsprung starten erst, wenn alle Spieler und Hunter das bestätigt haben.')}</div>
          <label className="check">
            <input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} />
            <span>{t('Ich habe das gelesen und spiele auf eigene Gefahr.')}</span>
          </label>
          <button className="primary block big" disabled={!read || busy} onClick={async () => {
            setBusy(true);
            await act(() => api.safetyConfirm(s.game.id));
            setBusy(false);
          }}>{t('Verstanden')}</button>
        </div>
      </div>
    );
  }
  return <SafetyWaiting s={s} act={act} />;
}

/** Solange noch jemand fehlt: wer noch bestätigen muss. Der Host kann trotzdem starten. */
function SafetyWaiting({ s, act }: { s: GameState; act: PanelProps['act'] }) {
  if (s.game.pause_kind !== 'sicherheit') return null;
  const missing = s.safety_missing ?? [];
  return (
    <div className="card stack" role="status" style={{ marginBottom: 8, borderColor: 'var(--warn, #d29922)' }}>
      <strong style={{ fontSize: 18 }}>⏳ {t('Warten auf alle')}</strong>
      <span className="small">{t('Der Vorsprung startet automatisch, sobald alle Spieler und Hunter den Sicherheitshinweis bestätigt haben. Bis dahin steht die Zeit still.')}</span>
      {missing.length > 0 && (
        <div className="small">{t('Fehlt noch: {0}', { 0: missing.map((id) => nameTag(s, id)).join(', ') })}</div>
      )}
      {s.game.host && (
        <button className="ghost block" onClick={() => {
          if (window.confirm(t('Ohne die fehlenden Bestätigungen starten?'))) void act(() => api.safetyForce(s.game.id), t('Spiel gestartet.'));
        }}>{t('Trotzdem starten')}</button>
      )}
    </div>
  );
}
