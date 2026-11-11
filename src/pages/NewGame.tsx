import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import ConfigEditor from '../components/ConfigEditor';
import Guide, { type GuideStep } from '../components/Guide';
import ExtraRules from '../components/ExtraRules';
import Icon from '../components/Icon';
import IssueList from '../components/IssueList';
import QuickSettings from '../components/QuickSettings';
import { createGame, diffConfig } from '../lib/games';
import { db, errorText } from '../lib/supabase';
import { gameConfigSchema, parseConfig, type GameConfig } from '../shared/config';
import { useAuth } from '../lib/auth';
import { deleteTemplate, listTemplates, saveTemplate, type Template } from '../lib/games';
import { formatMinutes } from '../shared/format';
import { PRESETS, configFromPreset } from '../shared/presets';
import { validateConfig } from '../shared/validation';
import { t, lazy } from '../i18n';

const PRESET_ART: Record<string, string> = {
  schnell_90min: '⚡',
  stadtabend_3h: '🌆',
  wochenende_24h: '🏕️',
};
/** Kurze Spiele zuerst: die meisten Gruppen fangen klein an. */
const ORDER = ['schnell_90min', 'stadtabend_3h', 'wochenende_24h'];

function presetConfig(id: string): GameConfig {
  const c = configFromPreset(id);
  c.game.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || c.game.timezone;
  return c;
}

const GUIDE: GuideStep[] = lazy([
  { title: 'Willkommen!', text: 'In vier Schritten ist dein Spiel bereit. Du kannst den Helfer jederzeit schliessen und über "?" wieder öffnen.' },
  { target: 'name', title: '1. Name', text: 'Gib dem Spiel einen Namen, z. B. den Ort. Den sehen alle, die mitspielen.' },
  { target: 'presets', title: '2. Spielart', text: 'Wähle eine Vorlage. Sie stellt alle Regeln passend ein: Dauer, Pings, Blitzjagden, Joker. Für den Anfang ist "Schnell 90 min" oder "Stadtabend 3 h" ideal. Mit "Eigenes Spiel" stellst du alles selbst ein; sobald du etwas änderst, wird es automatisch ein eigenes Spiel.' },
  { target: 'adjust', title: '3. Anpassen (freiwillig)', text: 'Tippe einen Bereich an, um ihn zu ändern, z. B. die Anzahl Spieler oder wie oft gepingt wird. Bei jeder Einstellung erklärt das i, was sie bewirkt.' },
  { target: 'create', title: '4. Karte', text: 'Danach zeichnest du das Spielfeld auf der Karte. Erst dann bekommst du den Code, mit dem deine Freunde beitreten.' },
]);

/** Datum und Uhrzeit getrennt (das kombinierte Feld ist auf dem Handy zu breit). */
function splitLocal(v: string): [string, string] {
  const [d, tm] = v.split('T');
  return [d ?? '', (tm ?? '').slice(0, 5)];
}

export default function NewGamePage() {
  const navigate = useNavigate();
  const { session } = useAuth();
  const [params] = useSearchParams();
  const fromGame = params.get('von');
  const [name, setName] = useState('');
  const [presetId, setPresetId] = useState('stadtabend_3h');
  const [baseline, setBaseline] = useState(() => presetConfig('stadtabend_3h'));
  const [config, setConfig] = useState(baseline);
  const [startAt, setStartAt] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const [groups, setGroups] = useState<{ id: string; name: string }[]>([]);
  const [groupId, setGroupId] = useState('');
  const [guide, setGuide] = useState(false);
  const [templates, setTemplates] = useState<Template[]>([]);
  const [origin, setOrigin] = useState<string | null>(null);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);
  /** "Nochmal spielen": auch die Karte des früheren Spiels übernehmen. */
  const [copyMap, setCopyMap] = useState(params.get('karte') !== '0');
  /** Hat die Person schon selbst etwas gewählt? Dann die geladenen Grundeinstellungen nicht mehr darüberschreiben. */
  const touched = useRef(false);

  useEffect(() => {
    void db().from('groups').select('id,name').then(({ data }) => setGroups((data ?? []) as { id: string; name: string }[]));
    void listTemplates().then(setTemplates, () => undefined);
  }, []);

  // Grundeinstellungen: die des zuletzt erstellten Spiels. "Nochmal spielen" (?von=…) übernimmt die eines bestimmten Spiels.
  useEffect(() => {
    const uid = session?.user.id;
    if (!uid) return;
    let q = db().from('games').select('id,name,preset_id,config_json,group_id');
    q = fromGame ? q.eq('id', fromGame) : q.eq('host_id', uid).order('created_at', { ascending: false }).limit(1);
    void q.then(({ data }) => {
      const g = (data ?? [])[0] as { id: string; name: string; preset_id: string | null; config_json: unknown; group_id: string | null } | undefined;
      if (!g || touched.current) return;
      const cfg = parseConfig(g.config_json);
      cfg.game.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || cfg.game.timezone;
      setBaseline(cfg);
      setConfig(cfg);
      setPresetId(g.preset_id && g.preset_id !== 'eigenes' && ORDER.includes(g.preset_id) ? g.preset_id : 'eigenes');
      setOrigin(g.name);
      if (fromGame) {
        setName((n) => n || g.name);
        if (g.group_id) setGroupId(g.group_id);
      }
    });
  }, [session?.user.id, fromGame]);

  function pickTemplate(tp: Template) {
    touched.current = true;
    const c = parseConfig(tp.config_json);
    c.game.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || c.game.timezone;
    setPresetId('eigenes');
    setBaseline(c);
    setConfig(c);
    setOrigin(null);
  }

  async function storeTemplate() {
    const label = window.prompt(t('Name für deine Variante:'), name.trim() || t('Meine Variante'));
    if (!label?.trim()) return;
    try {
      await saveTemplate(label.trim().slice(0, 60), result.config);
      setTemplates(await listTemplates());
      setSaveMsg(t('Variante „{0}“ gespeichert. Du findest sie oben bei der Spielart.', { 0: label.trim() }));
    } catch (e) {
      setSaveMsg(errorText(e));
    }
  }

  const result = useMemo(() => validateConfig(config), [config]);
  const problemPaths = useMemo(
    () => new Set(result.issues.filter((i) => i.level !== 'autofix').flatMap((i) => i.paths)),
    [result],
  );
  const changed = useMemo(() => diffConfig(baseline, result.config).length > 0, [baseline, result.config]);

  function pickPreset(id: string) {
    touched.current = true;
    setOrigin(null);
    const c = presetConfig(id);
    setPresetId(id);
    setBaseline(c);
    setConfig(c);
  }

  function edit(next: GameConfig) {
    const parsed = gameConfigSchema.safeParse(next);
    if (parsed.success) {
      touched.current = true;
      setConfig(parsed.data);
      // Wer etwas verstellt, spielt ein eigenes Spiel: dann ist klar, dass die eigenen Einstellungen gelten.
      setPresetId('eigenes');
      setEditError(null);
    } else {
      setEditError(t('Ungültiger Wert: ') + parsed.error.issues.map((i) => i.path.join('.')).join(', '));
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const game = await createGame(
        name.trim(),
        presetId === 'eigenes' || changed ? 'eigenes' : presetId,
        result.config,
        startAt ? new Date(startAt).toISOString() : null,
      );
      if (groupId) {
        const { error: gErr } = await db().rpc('set_game_group', { p_game_id: game.id, p_group_id: groupId });
        if (gErr) throw gErr;
      }
      if (fromGame && copyMap) {
        const { error: mErr } = await db().rpc('copy_map', { p_from: fromGame, p_to: game.id });
        if (mErr) throw mErr;
      }
      // Schritt 4: zuerst die Karte, erst danach gibt es den Code zum Einladen.
      navigate(`/spiel/${game.id}/karte?neu=1`, { replace: true });
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  }

  const presets = ORDER.map((id) => PRESETS.find((p) => p.id === id)).filter((p): p is (typeof PRESETS)[number] => !!p);
  const c = result.config;

  return (
    <div className="app">
      <div className="topbar">
        <Link to="/" className="button ghost back" aria-label={t('Zurück')}><Icon name="back" /></Link>
        <h1>{t('Neues Spiel')}</h1>
        <button type="button" className="ghost icon-btn" aria-label={t('Helfer')} onClick={() => setGuide(true)}><Icon name="help" /></button>
      </div>
      {guide && <Guide steps={GUIDE} onClose={() => setGuide(false)} />}

      <form onSubmit={submit}>
        <div className="step-head"><span className="n">1</span><h2>{t('Wie heisst euer Spiel?')}</h2></div>
        <label className="field" data-guide="name">
          <input required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder={t('z. B. Zürich Altstadt')} aria-label={t('Name des Spiels')} />
        </label>

        <div className="step-head"><span className="n">2</span><h2>{t('Spielart wählen')}</h2></div>
        <div className="preset-grid" data-guide="presets">
          {presets.map((p) => {
            const pc = presetConfig(p.id);
            return (
              <button type="button" key={p.id} className={`preset-card${p.id === presetId ? ' on' : ''}`} aria-pressed={p.id === presetId} onClick={() => pickPreset(p.id)}>
                <span className="emoji" aria-hidden="true">{PRESET_ART[p.id] ?? '🎯'}</span>
                <strong>{t(p.name)}</strong>
                <span className="muted">{t(p.description)}</span>
                <span className="facts">
                  <span>{formatMinutes(pc.game.duration_minutes)}</span>
                  <span>{p.suggested.players + p.suggested.hunters} {t('Pers.')}</span>
                </span>
              </button>
            );
          })}
          {templates.map((tp) => {
            const tc = parseConfig(tp.config_json);
            return (
              <div key={tp.id} className="preset-card" role="button" tabIndex={0} onClick={() => pickTemplate(tp)}
                onKeyDown={(e) => { if (e.key === 'Enter') pickTemplate(tp); }}>
                <span className="emoji" aria-hidden="true">⭐</span>
                <strong>{tp.name}</strong>
                <span className="muted">{t('Deine gespeicherte Variante')}</span>
                <span className="facts">
                  <span>{formatMinutes(tc.game.duration_minutes)}</span>
                  <span>{tc.roles.players_max + tc.roles.hunters_max} {t('Pers.')}</span>
                  <button type="button" className="ghost small" aria-label={t('Variante löschen')} style={{ marginLeft: 'auto', minHeight: 0, padding: '2px 6px' }}
                    onClick={(e) => {
                      e.stopPropagation();
                      if (!window.confirm(t('Variante „{0}“ löschen?', { 0: tp.name }))) return;
                      void deleteTemplate(tp.id).then(() => setTemplates((l) => l.filter((x) => x.id !== tp.id)), (er) => setSaveMsg(errorText(er)));
                    }}>🗑</button>
                </span>
              </div>
            );
          })}
          <button type="button" className={`preset-card${presetId === 'eigenes' ? ' on' : ''}`} aria-pressed={presetId === 'eigenes'} onClick={() => setPresetId('eigenes')}>
            <span className="emoji" aria-hidden="true">✏️</span>
            <strong>{t('Eigenes Spiel')}</strong>
            <span className="muted">{t('Alles selbst einstellen. Es gelten genau deine Einstellungen unten.')}</span>
            <span className="facts">
              <span>{formatMinutes(c.game.duration_minutes)}</span>
              <span>{c.roles.players_max + c.roles.hunters_max} {t('Pers.')}</span>
            </span>
          </button>
        </div>
        {origin && (
          <div className="notice small" style={{ marginTop: 8 }}>
            {fromGame ? t('Gleiche Einstellungen wie im Spiel „{0}“. Du kannst sie unten noch anpassen.', { 0: origin })
              : t('Übernommen vom letzten Spiel „{0}“. Tippe eine Vorlage an, um neu zu beginnen.', { 0: origin })}
            {fromGame && (
              <label className="check" style={{ marginTop: 8 }}>
                <input type="checkbox" checked={copyMap} onChange={(e) => setCopyMap(e.target.checked)} />
                <span><strong>{t('Karte übernehmen')}</strong><br /><span className="muted small">{t('Spielfeld, Gefahrenzonen, Startpunkt und Fluchtpunkte wie im Spiel „{0}“. Du kannst sie danach noch ändern.', { 0: origin })}</span></span>
              </label>
            )}
          </div>
        )}
        {presetId === 'eigenes' && <div className="muted small" style={{ marginTop: 8 }}>{t('Eigenes Spiel: Es gelten deine Einstellungen unter „Anpassen“. Tippe eine Vorlage an, um wieder mit ihr zu beginnen.')}</div>}
        <div className="summary-line" style={{ marginTop: 12 }}>
          <span>⏱️ {formatMinutes(c.game.duration_minutes)}</span>
          <span>👥 {c.roles.players_max} {t('Spieler ·')} {c.roles.hunters_max} {t('Hunter')}</span>
          <span>{t('📍 Ping alle')} {formatMinutes(c.ping.interval_minutes)}</span>
          <span>⚡ {c.speedhunt.enabled ? t('{0} Blitzjagden', { 0: c.speedhunt.quota_per_day[0] ?? 0 }) : t('ohne Blitzjagd')}</span>
          {c.joker.enabled && <span>{t('🃏 Joker')}</span>}
          {c.exit.enabled && <span>{t('🏁 Fluchtpunkt')}</span>}
          {presetId === 'eigenes' && <span style={{ borderColor: 'var(--yellow)', color: 'var(--yellow)' }}>{t('✏️ eigenes Spiel')}</span>}
        </div>

        <div className="step-head"><span className="n">3</span><h2>{t('Anpassen')} <span className="muted small" style={{ fontWeight: 400 }}>{t('(freiwillig)')}</span></h2></div>
        <div data-guide="adjust">
          <QuickSettings config={c} onChange={edit} />
          <button type="button" className="block" style={{ margin: '4px 0 10px' }} onClick={() => void storeTemplate()}>⭐ {t('Diese Einstellungen als Variante speichern')}</button>
          {saveMsg && <div className="notice small" style={{ marginBottom: 10 }} onClick={() => setSaveMsg(null)}>{saveMsg}</div>}
          <details className="acc">
            <summary>
              <span className="ico" aria-hidden="true">📌</span>
              <span className="spacer"><span className="t">{t('Eigene Zusatzregeln')}</span><span className="s" style={{ display: 'block' }}>{config.extras.rules.length ? t('{0} Regeln', { 0: config.extras.rules.length }) : t('z. B. „Kein Taxi“')}</span></span>
              <Icon name="chevron" className="chev" />
            </summary>
            <div className="body">
              <ExtraRules bare rules={config.extras.rules} onChange={(rules) => edit({ ...config, extras: { ...config.extras, rules } })} />
            </div>
          </details>
          <details className="acc">
            <summary>
              <span className="ico" aria-hidden="true">📅</span>
              <span className="spacer"><span className="t">{t('Termin')}{groups.length > 0 && t(' und Gruppe')}</span><span className="s" style={{ display: 'block' }}>{startAt ? new Date(startAt).toLocaleString('de-CH', { dateStyle: 'medium', timeStyle: 'short' }) : t('Start später in der Lobby')}</span></span>
              <Icon name="chevron" className="chev" />
            </summary>
            <div className="body">
              <div className="field">
                <span>{t('Geplanter Start (nur zur Info, gestartet wird in der Lobby)')}</span>
                <div className="date-row">
                  <input type="date" aria-label={t('Datum')} value={splitLocal(startAt)[0]}
                    onChange={(e) => setStartAt(e.target.value ? `${e.target.value}T${splitLocal(startAt)[1] || '18:00'}` : '')} />
                  <input type="time" aria-label={t('Uhrzeit')} value={splitLocal(startAt)[1]} disabled={!splitLocal(startAt)[0]}
                    onChange={(e) => setStartAt(`${splitLocal(startAt)[0]}T${e.target.value || '18:00'}`)} />
                </div>
              </div>
              {groups.length > 0 && (
                <label className="field">
                  {t('Gruppe')}
                  <select value={groupId} onChange={(e) => setGroupId(e.target.value)}>
                    <option value="">{t('Keine')}</option>
                    {groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
                  </select>
                </label>
              )}
            </div>
          </details>
          <details className="acc">
            <summary>
              <span className="ico" aria-hidden="true">🧰</span>
              <span className="spacer"><span className="t">{t('Expertenmodus')}</span><span className="s" style={{ display: 'block' }}>{t('Alle 150 Einstellungen einzeln')}</span></span>
              <Icon name="chevron" className="chev" />
            </summary>
            <div className="body">
              {editError && <div className="notice error">{editError}</div>}
              <ConfigEditor config={c} baseline={baseline} problemPaths={problemPaths} onChange={edit} />
            </div>
          </details>
        </div>

        <div className="step-head"><span className="n">4</span><h2>{t('Karte zeichnen')}</h2></div>
        <p className="muted small" style={{ marginTop: 0 }}>{t('Im nächsten Schritt legst du auf der Karte das Spielfeld fest. Danach bekommst du den Code zum Einladen.')}</p>

        <div style={{ marginTop: 12 }} data-guide="issues"><IssueList issues={result.issues} compact /></div>

        <div className="sticky-cta">
          {error && <div className="notice error" style={{ marginBottom: 8 }}>{error}</div>}
          <button className="primary block big" data-guide="create" disabled={busy || !name.trim()}>
            {busy ? t('Erstelle …') : !name.trim() ? t('Erst einen Namen eingeben') : fromGame && copyMap ? t('Weiter zur Karte (übernommen)') : t('Weiter zur Karte')}
          </button>
        </div>
      </form>
    </div>
  );
}
