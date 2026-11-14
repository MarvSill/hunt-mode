import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import Icon from '../components/Icon';
import IssueList from '../components/IssueList';
import RulesSummary from '../components/RulesSummary';
import { useAuth } from '../lib/auth';
import {
  ROLE_LABELS,
  diffConfig,
  updateConfig,
  STATUS_LABELS,
  getGame,
  getRoster,
  removeParticipant,
  setReady,
  setRole,
  type Game,
  type Role,
  type RosterEntry,
} from '../lib/games';
import { api } from '../lib/engine';
import { appUrl, db, errorText } from '../lib/supabase';
import DeviceCheck from '../components/DeviceCheck';
import { parseConfig } from '../shared/config';
import { formatMinutes } from '../shared/format';
import { getPreset } from '../shared/presets';
import { distributeRoles, lobbyIssues } from '../shared/roles';
import { validateConfig } from '../shared/validation';
import Loader from '../components/Loader';
import { t, lazy } from '../i18n';
import Guide, { type GuideStep } from '../components/Guide';

const ASSIGNABLE: Role[] = ['offen', 'spieler', 'hunter', 'zuschauer'];
const WISHABLE: Role[] = ['spieler', 'hunter', 'zuschauer'];

/** Helfer in der Lobby: die letzten Schritte bis zum Start. */
const LOBBY_GUIDE: GuideStep[] = lazy([
  { title: 'Fast geschafft!', text: 'Noch ein paar Schritte, dann kann es losgehen. Ich zeige sie dir der Reihe nach.' },
  { target: 'todo-0', title: 'Karte', text: 'Zeichne das Spielfeld und setze den Startpunkt (und die Fluchtpunkte). Die Karte führt dich Schritt für Schritt.' },
  { target: 'todo-1', title: 'Freunde einladen', text: 'Teile den Code oder den Link. Wer ihn öffnet, ist im Spiel.' },
  { target: 'todo-2', title: 'Rollen', text: 'Lege fest, wer Spieler und wer Hunter ist, oder tippe auf "Zufällig". Wähle auch deine eigene Rolle.' },
  { target: 'todo-3', title: 'Alle bereit', text: 'Jeder bestätigt in seiner App, dass er die Regeln gelesen hat.' },
  { target: 'start', title: 'Start', text: 'Sind alle Haken grün, startest du hier. Der Vorsprung beginnt, sobald alle den Sicherheitshinweis bestätigt haben.' },
]);

export default function GamePage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { session } = useAuth();
  const [game, setGame] = useState<Game | null>(null);
  const [roster, setRoster] = useState<RosterEntry[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  // Helfer in der Lobby (Host): beim ersten Mal von selbst, sonst über "?".
  const [guide, setGuide] = useState(() => { try { return !localStorage.getItem('hm-guide-lobby'); } catch { return false; } });
  const closeGuide = () => { setGuide(false); try { localStorage.setItem('hm-guide-lobby', '1'); } catch { /* egal */ } };
  const [starting, setStarting] = useState(false);
  const [hasField, setHasField] = useState<boolean | null>(null);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      const [g, r, f] = await Promise.all([
        getGame(id),
        getRoster(id),
        db().from('zones').select('id', { count: 'exact', head: true }).eq('game_id', id).eq('kind', 'spielfeld'),
      ]);
      setGame(g);
      setRoster(r);
      setHasField(f.error ? null : (f.count ?? 0) > 0);
    } catch (err) {
      setError(errorText(err));
    } finally {
      setLoaded(true);
    }
  }, [id]);

  useEffect(() => {
    void load();
    if (!id) return;
    const channel = db()
      .channel(`lobby:${id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'participants', filter: `game_id=eq.${id}` }, () => void load())
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'games', filter: `id=eq.${id}` }, () => void load())
      .subscribe();
    return () => {
      void db().removeChannel(channel);
    };
  }, [id, load]);

  useEffect(() => {
    if (game && ['vorsprung', 'laeuft', 'finale'].includes(game.status)) navigate(`/spiel/${game.id}/live`, { replace: true });
  }, [game?.status]); // eslint-disable-line react-hooks/exhaustive-deps

  const config = useMemo(() => (game ? parseConfig(game.config_json) : null), [game]);
  const me = roster.find((r) => r.user_id === session?.user.id);
  const isHost = !!game && game.host_id === session?.user.id;
  const inLobby = !!game && ['entwurf', 'geplant', 'lobby'].includes(game.status);

  const checks = useMemo(() => {
    if (!config) return null;
    const players = roster.filter((r) => r.role === 'spieler');
    const hunters = roster.filter((r) => r.role === 'hunter');
    const hasMinors = [...players, ...hunters].some((r) => !r.is_adult);
    const validation = validateConfig(config, { players: players.length, hunters: hunters.length, hasMinors });
    const lobby = lobbyIssues(
      { players: players.length, hunters: hunters.length, unassigned: roster.filter((r) => r.role === 'offen').length },
      config.roles,
      roster.filter((r) => !r.ready).length,
    );
    const issues = [...lobby.map((i) => ({ ...i, paths: [] })), ...validation.issues];
    return { issues, canStart: !issues.some((i) => i.level === 'error'), players: players.length, hunters: hunters.length, fixed: validation.config };
  }, [config, roster]);

  async function run(action: () => Promise<void>) {
    setError(null);
    try {
      await action();
      await load();
    } catch (err) {
      setError(errorText(err));
    }
  }

  function shuffleRoles() {
    if (!config) return;
    const result = distributeRoles(roster.map((r) => r.participant_id), config.roles);
    return run(async () => {
      for (const [pid, role] of Object.entries(result)) await setRole(pid, role);
    });
  }

  function applyWishes() {
    return run(async () => {
      for (const r of roster) if (r.wished_role && r.wished_role !== r.role) await setRole(r.participant_id, r.wished_role);
    });
  }

  async function startGame(test: boolean) {
    if (!game) return;
    setStarting(true);
    setError(null);
    try {
      // Automatisch korrigierte Zeiten vor dem Start speichern, damit die Engine stimmige Werte hat.
      if (config && checks) {
        const changes = diffConfig(config, checks.fixed);
        if (changes.length) await updateConfig(game.id, checks.fixed, changes);
      }
      await api.start(game.id, test);
      navigate(`/spiel/${game.id}/live`);
    } catch (err) {
      setError(errorText(err));
    } finally {
      setStarting(false);
    }
  }

  async function share() {
    if (!game) return;
    const url = appUrl(`/beitreten/${game.code}`);
    const text = t('Spiel "{0}" beitreten: Code {1}', { 0: game.name, 1: game.code });
    if (navigator.share) {
      try {
        await navigator.share({ title: 'Hunt Mode', text, url });
        return;
      } catch {
        // abgebrochen: auf Kopieren ausweichen
      }
    }
    await navigator.clipboard.writeText(`${text}\n${url}`);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  if (!loaded) return <Loader />;
  if (!game || !config || !checks) {
    return (
      <div className="app">
        <div className="notice error">{error ?? t('Spiel nicht gefunden oder du bist nicht dabei.')}</div>
        <Link to="/">{t('Zur Startseite')}</Link>
      </div>
    );
  }

  const preset = game.preset_id ? getPreset(game.preset_id) : undefined;
  const unassigned = roster.filter((r) => r.role === 'offen').length;
  const notReady = roster.filter((r) => !r.ready).length;
  const todos = [
    { done: hasField === true, title: t('Karte zeichnen'), text: hasField ? t('Spielfeld ist gesetzt.') : t('Spielfeld und Startpunkt festlegen.'), action: <Link to={`/spiel/${game.id}/karte`} className="button small">{hasField ? t('Ändern') : t('Zeichnen')}</Link> },
    { done: checks.players > 0 && checks.hunters > 0, title: t('Freunde einladen'), text: hasField ? t('{0} beigetreten · Code {1}', { 0: roster.length - 1, 1: game.code }) : t('Geht, sobald die Karte steht.'), action: hasField ? <button className="small" onClick={share}><Icon name="share" size={18} />{t('Teilen')}</button> : null },
    { done: roster.length > 1 && unassigned === 0, title: t('Rollen verteilen'), text: t('{0} Spieler · {1} Hunter{2}', { 0: checks.players, 1: checks.hunters, 2: unassigned ? ` · ${unassigned} offen` : '' }), action: <button className="small" onClick={shuffleRoles}>{t('Zufällig')}</button> },
    { done: roster.length > 1 && notReady === 0, title: t('Alle bereit'), text: notReady ? t('{0} noch nicht bereit', { 0: notReady }) : t('Alle haben die Regeln gelesen.'), action: null },
  ];

  return (
    <div className="app">
      <div className="topbar">
        <Link to="/" className="button ghost back" aria-label={t('Zurück')}><Icon name="back" /></Link>
        <h1>{game.name}</h1>
        <span className="badge">{STATUS_LABELS[game.status] ?? game.status}</span>
        {inLobby && isHost && <button type="button" className="ghost icon-btn" aria-label={t('Helfer')} onClick={() => setGuide(true)}><Icon name="help" /></button>}
      </div>
      {inLobby && isHost && guide && <Guide steps={LOBBY_GUIDE} onClose={closeGuide} />}

      {!inLobby && (
        <Link to={`/spiel/${game.id}/live`} className="button primary block big" style={{ marginBottom: 12 }}>
          {game.status === 'beendet' ? t('Ergebnis und Wiederholung') : t('Zum laufenden Spiel')}
        </Link>
      )}

      {inLobby && isHost && hasField === false && (
        <div className="hero stack" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: 34 }} aria-hidden="true">🗺️</div>
          <strong>{t('Zuerst die Karte')}</strong>
          <div className="muted small">{t('Lege das Spielfeld fest, bevor du Freunde einlädst. Danach erscheint hier der Code zum Beitreten.')}</div>
          <Link to={`/spiel/${game.id}/karte?neu=1`} className="button primary block">{t('Karte zeichnen')}</Link>
        </div>
      )}

      {inLobby && !(isHost && hasField === false) && (
        <div className="hero" style={{ textAlign: 'center' }}>
          <div className="muted small">{t('Mit diesem Code treten deine Freunde bei')}</div>
          <div className="code-big" style={{ margin: '6px 0 12px' }}>{game.code}</div>
          <button className="primary block" onClick={share}><Icon name="share" size={20} />{copied ? t('Link kopiert!') : t('Einladung teilen')}</button>
        </div>
      )}

      {inLobby && isHost && hasField !== false && (
        <div className="card">
          <div className="row" style={{ marginBottom: 4 }}><strong className="spacer">{t('Bereit zum Start?')}</strong><span className="muted small">{todos.filter((t) => t.done).length}/{todos.length}</span></div>
          {todos.map((t, i) => (
            <div key={t.title} className={`todo${t.done ? ' done' : ''}`} data-guide={`todo-${i}`}>
              <span className="tick"><Icon name="check" size={16} /></span>
              <div className="spacer"><div>{t.title}</div><div className="muted small">{t.text}</div></div>
              {t.action}
            </div>
          ))}
          {me?.role === 'offen' && (
            <div className="notice" style={{ marginTop: 8 }}>{t('Wähle unten bei deinem Namen auch deine eigene Rolle: Spieler, Hunter oder Zuschauer.')}</div>
          )}
        </div>
      )}

      {error && <div className="notice error" style={{ marginBottom: 12 }}>{error}</div>}

      {inLobby && me && !isHost && (
        <div className="card stack">
          <div className="row"><strong className="spacer">{t('Deine Rolle')}</strong><span className={`role-pill ${me.role}`}>{ROLE_LABELS[me.role]}</span></div>
          {me.role === 'offen' && <p className="muted small" style={{ margin: 0 }}>{t('Der Host verteilt die Rollen. Du kannst dir eine wünschen.')}</p>}
          <label className="field">
            {t('Wunschrolle')}
            <select
              value={me.wished_role ?? ''}
              onChange={(e) => run(() => setReady(game.id, me.ready, (e.target.value || null) as Role | null))}
            >
              <option value="">{t('Egal')}</option>
              {WISHABLE.map((role) => (
                <option key={role} value={role}>
                  {ROLE_LABELS[role]}
                </option>
              ))}
            </select>
          </label>
          <label className="check">
            <input type="checkbox" checked={me.ready} onChange={(e) => run(() => setReady(game.id, e.target.checked, null))} />
            <span><strong>{t('Ich bin bereit')}</strong><br /><span className="muted small">{t('Ich habe die Regeln gelesen.')}</span></span>
          </label>
        </div>
      )}

      <details className="acc" open={!isHost && inLobby}>
        <summary>
          <span className="ico" aria-hidden="true">📖</span>
          <span className="spacer"><span className="t">{t('So läuft das Spiel')}</span><span className="s" style={{ display: 'block' }}>{(preset ? t(preset.name) : t('Eigene Regeln'))} · {formatMinutes(config.game.duration_minutes)}</span></span>
          <Icon name="chevron" className="chev" />
        </summary>
        <div className="body">
          <RulesSummary config={config} />
          <div className="row">
            <Link to={`/spiel/${game.id}/regeln`} className="button small">{isHost && inLobby ? t('Regeln ändern') : t('Alle Regeln')}</Link>
            <Link to={`/spiel/${game.id}/karte`} className="button small">{t('Karte ansehen')}</Link>
          </div>
        </div>
      </details>

      {inLobby && <>
      <div className="section-title">{t('Dabei (')}{roster.length})</div>
      <div className="card" style={{ paddingTop: 4, paddingBottom: 4 }}>
        {roster.map((r) => (
          <div key={r.participant_id} className="person">
            <div className="avatar">{r.display_name.charAt(0).toUpperCase()}</div>
            <div className="spacer">
              <div style={{ fontWeight: 600 }}>
                {r.display_name} {r.user_id === game.host_id && <span className="badge">{t('Host')}</span>}
              </div>
              <div className="muted tiny">
                {r.ready ? t('✓ bereit') : t('nicht bereit')}
                {r.wished_role && r.wished_role !== r.role && t(' · möchte {0}', { 0: ROLE_LABELS[r.wished_role] })}
              </div>
            </div>
            {isHost && inLobby ? (
              <>
                <select
                  className={`role-pill ${r.role}`}
                  value={r.role}
                  aria-label={t('Rolle von {0}', { 0: r.display_name })}
                  onChange={(e) => run(() => setRole(r.participant_id, e.target.value as Role))}
                >
                  {ASSIGNABLE.map((role) => (
                    <option key={role} value={role}>
                      {ROLE_LABELS[role]}
                    </option>
                  ))}
                </select>
                {r.user_id !== game.host_id && (
                  <button className="ghost icon-btn" aria-label={`${r.display_name} entfernen`} onClick={() => run(() => removeParticipant(r.participant_id))}>
                    <Icon name="trash" size={18} />
                  </button>
                )}
              </>
            ) : (
              <span className={`role-pill ${r.role}`}>{ROLE_LABELS[r.role]}</span>
            )}
          </div>
        ))}
        {roster.length === 1 && inLobby && <p className="muted small">{t('Noch niemand beigetreten. Teile den Code oben.')}</p>}
      </div>
      </>}
      {inLobby && isHost && roster.some((r) => r.wished_role && r.wished_role !== r.role) && (
        <button className="block" style={{ marginBottom: 12 }} onClick={applyWishes}>{t('Wunschrollen übernehmen')}</button>
      )}

      {inLobby && me && <DeviceCheck gameId={game.id} minBattery={config.lobby.min_battery_percent} />}

      {inLobby && isHost && (
        <>
          <IssueList issues={checks.issues} compact />
          <div className="sticky-cta">
            <button className="primary block big" data-guide="start" disabled={!checks.canStart || starting} onClick={() => startGame(false)}>
              {starting ? t('Starte …') : t('Spiel starten')}
            </button>
            <button className="ghost block small" style={{ marginTop: 6 }} disabled={starting} onClick={() => startGame(true)}>
              {t('Probelauf mit Vorspulen (zum Ausprobieren)')}
            </button>
          </div>
        </>
      )}

      {inLobby && me && !isHost && (
        <button className="ghost block" style={{ marginTop: 8 }} onClick={() => run(async () => { await removeParticipant(me.participant_id); navigate('/'); })}>
          {t('Spiel verlassen')}
        </button>
      )}
    </div>
  );
}
