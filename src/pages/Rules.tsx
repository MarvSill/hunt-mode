import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import ConfigEditor from '../components/ConfigEditor';
import ExtraRules from '../components/ExtraRules';
import Icon from '../components/Icon';
import IssueList from '../components/IssueList';
import QuickSettings from '../components/QuickSettings';
import RulesSummary from '../components/RulesSummary';
import { useAuth } from '../lib/auth';
import { diffConfig, getGame, updateConfig, type Game } from '../lib/games';
import { errorText } from '../lib/supabase';
import { gameConfigSchema, parseConfig, type GameConfig } from '../shared/config';
import { configFromPreset, getPreset } from '../shared/presets';
import { validateConfig } from '../shared/validation';
import Loader from '../components/Loader';
import { t } from '../i18n';

export default function RulesPage() {
  const { id } = useParams<{ id: string }>();
  const { session } = useAuth();
  const [game, setGame] = useState<Game | null>(null);
  const [saved, setSaved] = useState<GameConfig | null>(null);
  const [config, setConfig] = useState<GameConfig | null>(null);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!id) return;
    getGame(id).then(
      (g) => {
        setGame(g);
        if (g) {
          const c = parseConfig(g.config_json);
          setSaved(c);
          setConfig(c);
        }
      },
      (e) => setMsg({ kind: 'error', text: errorText(e) }),
    );
  }, [id]);

  const baseline = useMemo(() => {
    if (!game?.preset_id || !getPreset(game.preset_id) || !config) return undefined;
    const b = configFromPreset(game.preset_id);
    b.game.timezone = config.game.timezone;
    return b;
  }, [game?.preset_id, config?.game.timezone]);

  const result = useMemo(() => (config ? validateConfig(config) : null), [config]);
  const problemPaths = useMemo(
    () => new Set(result?.issues.filter((i) => i.level !== 'autofix').flatMap((i) => i.paths) ?? []),
    [result],
  );

  if (!game || !config || !saved || !result) {
    return <div className="app">{msg ? <div className="notice error">{msg.text}</div> : <Loader inline />}</div>;
  }

  const editable = game.host_id === session?.user.id && ['entwurf', 'geplant', 'lobby'].includes(game.status);
  const changes = diffConfig(saved, result.config);

  function edit(next: GameConfig) {
    const parsed = gameConfigSchema.safeParse(next);
    if (parsed.success) {
      setConfig(parsed.data);
      setMsg(null);
    } else {
      setMsg({ kind: 'error', text: t('Ungültiger Wert: ') + parsed.error.issues.map((i) => i.path.join('.')).join(', ') });
    }
  }

  async function save() {
    if (!game || !result) return;
    setBusy(true);
    try {
      await updateConfig(game.id, result.config, changes);
      setSaved(result.config);
      setConfig(result.config);
      setMsg({ kind: 'ok', text: t('{0} Änderung(en) gespeichert.', { 0: changes.length }) });
    } catch (err) {
      setMsg({ kind: 'error', text: errorText(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app">
      <div className="topbar">
        <Link to={`/spiel/${game.id}`} className="button ghost back" aria-label={t('Zurück')}><Icon name="back" /></Link>
        <h1>{t('Regeln')}</h1>
      </div>
      {!editable && (
        <div className="card">
          <RulesSummary config={config} />
        </div>
      )}
      {editable && (
        <>
          <p className="muted small" style={{ marginTop: 0 }}>{t('Tippe einen Bereich an, um ihn zu ändern. Zeiten passt die App automatisch an die Spieldauer an.')}</p>
          <QuickSettings config={result.config} onChange={edit} />
          <details className="acc">
            <summary>
              <span className="ico" aria-hidden="true">📌</span>
              <span className="spacer"><span className="t">{t('Eigene Zusatzregeln')}</span><span className="s" style={{ display: 'block' }}>{config.extras.rules.length ? t('{0} Regeln', { 0: config.extras.rules.length }) : t('keine')}</span></span>
              <Icon name="chevron" className="chev" />
            </summary>
            <div className="body">
              <ExtraRules bare rules={config.extras.rules} onChange={(rules) => edit({ ...config, extras: { ...config.extras, rules } })} />
            </div>
          </details>
        </>
      )}
      <details className="acc">
        <summary>
          <span className="ico" aria-hidden="true">🧰</span>
          <span className="spacer"><span className="t">{editable ? t('Expertenmodus') : t('Alle Einstellungen')}</span><span className="s" style={{ display: 'block' }}>{t('Jede Einstellung einzeln')}</span></span>
          <Icon name="chevron" className="chev" />
        </summary>
        <div className="body">
          <ConfigEditor config={result.config} baseline={baseline} readOnly={!editable} problemPaths={problemPaths} onChange={edit} />
        </div>
      </details>
      <div style={{ marginTop: 12 }}><IssueList issues={result.issues} compact /></div>
      {msg && <div className={`notice ${msg.kind}`} style={{ margin: '12px 0' }}>{msg.text}</div>}
      {editable && (
        <div className="sticky-cta">
          <button className="primary block" disabled={busy || changes.length === 0} onClick={save}>
            {changes.length === 0 ? t('Keine Änderungen') : t('{0} Änderung(en) speichern', { 0: changes.length })}
          </button>
        </div>
      )}
    </div>
  );
}
