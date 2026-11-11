import { useNavigate } from 'react-router-dom';
import { t } from '../i18n';

/** "Nochmal spielen": fragt, ob auch die Karte (Spielfeld, Zonen, Punkte) übernommen werden soll. */
export default function ReplayAsk({ gameId, name, onClose }: { gameId: string; name: string; onClose: () => void }) {
  const navigate = useNavigate();
  const go = (map: boolean) => navigate(`/neu?von=${gameId}&karte=${map ? 1 : 0}`);
  return (
    <div className="overlay" role="dialog" aria-label={t('Nochmal spielen')} onClick={onClose}>
      <div className="card stack" style={{ maxWidth: 420, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}>
        <strong style={{ fontSize: 20 }}>🔁 {t('„{0}“ nochmal spielen', { 0: name })}</strong>
        <span className="small">{t('Die Einstellungen werden übernommen. Willst du auch die Karte übernehmen (Spielfeld, Gefahrenzonen, Startpunkt und Fluchtpunkte)?')}</span>
        <button type="button" className="primary block big" onClick={() => go(true)}>{t('Ja, mit derselben Karte')}</button>
        <button type="button" className="block" onClick={() => go(false)}>{t('Nein, Karte neu zeichnen')}</button>
        <button type="button" className="ghost block" onClick={onClose}>{t('Abbrechen')}</button>
      </div>
    </div>
  );
}
