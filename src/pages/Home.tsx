import { useEffect, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import Icon from '../components/Icon';
import { useAuth } from '../lib/auth';
import { STATUS_LABELS, deleteGame, joinGame, myGames, type Game } from '../lib/games';
import { errorText } from '../lib/supabase';
import { t, locale } from '../i18n';

const LIVE = ['vorsprung', 'laeuft', 'pausiert', 'finale'];
const DONE = ['beendet', 'archiviert'];

export default function HomePage() {
  const { profile } = useAuth();
  const navigate = useNavigate();
  const [games, setGames] = useState<Game[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const [showOld, setShowOld] = useState(false);

  useEffect(() => {
    myGames().then(setGames, (e) => setError(errorText(e)));
  }, []);

  async function join(e: FormEvent) {
    e.preventDefault();
    setJoinError(null);
    setJoining(true);
    try {
      const g = await joinGame(code);
      navigate(`/spiel/${g.id}`);
    } catch (err) {
      setJoinError(errorText(err));
    } finally {
      setJoining(false);
    }
  }

  const live = games?.filter((g) => LIVE.includes(g.status)) ?? [];
  const open = games?.filter((g) => !LIVE.includes(g.status) && !DONE.includes(g.status)) ?? [];
  const done = games?.filter((g) => DONE.includes(g.status)) ?? [];

  return (
    <div className="app">
      <div className="topbar" style={{ marginBottom: 14 }}>
        <div className="logo"><Icon name="target" size={26} /></div>
        <div className="spacer">
          <div className="brand" style={{ fontSize: 13 }}>{t('Hunt Mode')}</div>
          <div style={{ fontWeight: 700, fontSize: 19 }}>{t('Hallo')} {profile?.display_name}</div>
        </div>
        <Link to="/hilfe" className="button ghost icon-btn" aria-label={t('So funktioniert\'s')}><Icon name="help" /></Link>
      </div>

      {live.map((g) => (
        <Link key={g.id} to={`/spiel/${g.id}/live`} className="game-card live">
          <span className="status-dot live" />
          <div className="spacer">
            <div style={{ fontWeight: 700 }}>{g.name}</div>
            <div className="small muted">{STATUS_LABELS[g.status]} {t('· jetzt weiterspielen')}</div>
          </div>
          <Icon name="play" />
        </Link>
      ))}

      <div className="stack" style={{ gap: 10 }}>
        <Link to="/neu" className="tile primary">
          <span className="ico"><Icon name="plus" size={26} /></span>
          <span className="spacer"><strong>{t('Spiel erstellen')}</strong><span className="muted">{t('Vorlage wählen, Karte zeichnen, Freunde einladen')}</span></span>
          <Icon name="chevron" />
        </Link>
        <form className="tile" onSubmit={join} style={{ flexDirection: 'column', alignItems: 'stretch', gap: 10 }}>
          <div className="row" style={{ flexWrap: 'nowrap', gap: 14 }}>
            <span className="ico"><Icon name="join" size={24} /></span>
            <span className="spacer"><strong>{t('Spiel beitreten')}</strong><span className="muted">{t('Code vom Host eingeben')}</span></span>
          </div>
          <div className="row" style={{ flexWrap: 'nowrap' }}>
            <input className="code-input" inputMode="numeric" autoComplete="one-time-code" maxLength={6} placeholder="000000"
              aria-label={t('6-stelliger Code')} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} />
            <button className="primary" disabled={joining || code.length !== 6} style={{ flexShrink: 0 }}>{t('Los')}</button>
          </div>
          {joinError && <div className="notice error small">{joinError}</div>}
        </form>
      </div>

      <div className="section-title">{t('Meine Spiele')}</div>
      {error && <div className="notice error">{error}</div>}
      {games === null && !error && <p className="muted">{t('Lade …')}</p>}
      {games?.length === 0 && (
        <div className="empty">
          <div style={{ fontSize: 34 }}>🗺️</div>
          {t('Noch keine Spiele. Erstelle eins oder tritt mit einem Code bei.')}
          <div style={{ marginTop: 10 }}><Link to="/hilfe">{t('So funktioniert Hunt Mode')}</Link></div>
        </div>
      )}
      {open.map((g) => <GameRow key={g.id} g={g} />)}
      {games && games.length > 0 && open.length === 0 && live.length === 0 && <p className="muted small" style={{ margin: '0 4px 8px' }}>{t('Gerade kein Spiel geplant.')}</p>}
      {done.length > 0 && (
        <>
          <button className="ghost small block" onClick={() => setShowOld((v) => !v)}>
            {showOld ? t('Vergangene Spiele ausblenden') : t('Vergangene Spiele ({0})', { 0: done.length })}
          </button>
          {showOld && done.map((g) => (
            <GameRow key={g.id} g={g} host={g.host_id === profile?.user_id} onDelete={async () => {
              try {
                await deleteGame(g.id);
                setGames((list) => (list ?? []).filter((x) => x.id !== g.id));
              } catch (e) {
                setError(errorText(e));
              }
            }} />
          ))}
        </>
      )}
    </div>
  );
}

function GameRow({ g, host, onDelete }: { g: Game; host?: boolean; onDelete?: () => void }) {
  const done = DONE.includes(g.status);
  const [ask, setAsk] = useState(false);
  if (ask && onDelete) {
    return (
      <div className="game-card stack" style={{ alignItems: 'stretch' }}>
        <strong>{t('„{0}“ löschen?', { 0: g.name })}</strong>
        <span className="small muted">{host ? t('Das Spiel wird für alle gelöscht, mit Karte, Pings und Wiederholung. Das lässt sich nicht rückgängig machen.') : t('Das Spiel verschwindet aus deiner Liste.')}</span>
        <div className="row">
          <button className="danger small" onClick={() => { setAsk(false); onDelete(); }}>{t('Ja, löschen')}</button>
          <button className="ghost small" onClick={() => setAsk(false)}>{t('Abbrechen')}</button>
        </div>
      </div>
    );
  }
  return (
    <Link to={`/spiel/${g.id}`} className="game-card">
      <span className={`status-dot ${done ? 'done' : 'lobby'}`} />
      <div className="spacer">
        <div style={{ fontWeight: 600 }}>{g.name}</div>
        <div className="small muted">
          {STATUS_LABELS[g.status] ?? g.status}
          {!done && t(' · Code {0}', { 0: g.code })}
          {g.start_at && ` · ${new Date(g.start_at).toLocaleString(locale(), { dateStyle: 'short', timeStyle: 'short' })}`}
        </div>
      </div>
      {onDelete && (
        <button type="button" className="ghost small" aria-label={t('Spiel löschen')} onClick={(e) => { e.preventDefault(); e.stopPropagation(); setAsk(true); }}>🗑</button>
      )}
      <Icon name="chevron" />
    </Link>
  );
}
