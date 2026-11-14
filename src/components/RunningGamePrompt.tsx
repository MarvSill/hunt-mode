import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { myGames, type Game } from '../lib/games';
import { t } from '../i18n';

const LIVE = ['vorsprung', 'laeuft', 'finale', 'pausiert'];

/**
 * Läuft gerade ein Spiel, in dem man mitspielt, und ist man ausserhalb davon (Start, Gruppen, Profil …):
 * grosse Meldung "Zurück ins Spiel". Mit "Nicht jetzt" bleibt unten ein Balken, mit dem man jederzeit zurückkommt.
 */
export default function RunningGamePrompt() {
  const location = useLocation();
  const [game, setGame] = useState<Game | null>(null);
  const [later, setLater] = useState<string | null>(() => {
    try { return sessionStorage.getItem('hm-later'); } catch { return null; }
  });

  useEffect(() => {
    let alive = true;
    const load = () => myGames().then((list) => {
      if (alive) setGame(list.find((g) => LIVE.includes(g.status)) ?? null);
    }, () => undefined);
    void load();
    const i = setInterval(load, 30000);
    return () => { alive = false; clearInterval(i); };
  }, [location.pathname]);

  if (!game) return null;
  const to = `/spiel/${game.id}/live`;
  if (later === game.id) {
    return (
      <Link to={to} className="running-bar" role="status">
        <span className="pulse-dot" aria-hidden="true" />
        <span className="spacer">{t('Laufendes Spiel: {0}', { 0: game.name })}</span>
        <strong>{t('Zurück ins Spiel')} ›</strong>
      </Link>
    );
  }
  return (
    <div className="overlay" role="dialog" aria-label={t('Laufendes Spiel')}>
      <div className="card stack" style={{ maxWidth: 420, width: '100%', background: 'var(--surface)', textAlign: 'center' }}>
        <div style={{ fontSize: 44 }} aria-hidden="true">🏃</div>
        <strong style={{ fontSize: 22 }}>{t('Dein Spiel läuft!')}</strong>
        <span>{t('„{0}“ ist gerade im Gange. Willst du zurück ins Spiel?', { 0: game.name })}</span>
        <Link to={to} className="button primary block big">{t('Ja, zurück ins Spiel')}</Link>
        <button type="button" className="ghost block" onClick={() => {
          setLater(game.id);
          try { sessionStorage.setItem('hm-later', game.id); } catch { /* nur jetzt */ }
        }}>{t('Nicht jetzt')}</button>
      </div>
    </div>
  );
}
