import { useCallback, useState } from 'react';
import { api, clock, countdown, SOURCE_LABELS, STATE_LABELS, TRANSPORT_LABELS, uploadProof } from '../lib/engine';
import { Confirm, nameOf, Section, type PanelProps } from './common';
import Scanner from './Scanner';
import { t } from '../i18n';

export default function HunterPanel({ s, now, act, pos }: PanelProps) {
  const g = s.game;
  const cfg = g.config;
  const [scan, setScan] = useState(false);
  const [target, setTarget] = useState('');
  const [result, setResult] = useState<string | null>(null);
  const players = s.participants.filter((p) => p.role === 'spieler');
  const free = players.filter((p) => ['aktiv', 'ausserhalb', 'notfall'].includes(p.state));
  const running = s.speedhunts.filter((x) => x.status === 'laeuft');
  const waiting = s.speedhunts.filter((x) => x.status === 'aufgeschoben');
  const live = ['laeuft', 'finale'].includes(g.status) && !g.paused;
  const myProof = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_beweis');
  const myPending = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_bestaetigung');
  const canTrigger = cfg.speedhunt.enabled;

  const onCode = useCallback((code: string) => {
    setScan(false);
    void act(async () => {
      const r = await api.catchByCode(g.id, code, pos?.lat, pos?.lng);
      setResult(r.status === 'gueltig' ? t('{0} gefangen!', { 0: r.runner }) : t('{0}: Beweis nötig', { 0: r.runner }));
      return r;
    });
  }, [act, g.id, pos]);

  return (
    <div className="stack">
      {scan && <Scanner onCode={onCode} onClose={() => setScan(false)} />}
      {g.status === 'vorsprung' && <div className="notice">{t('Vorsprung der Spieler. Die Jagd beginnt in')} {countdown(g.hunt_start_at, now)}{t('. Wartet am Startpunkt.')}</div>}
      {result && <div className="notice success">{result}</div>}

      <button className="primary block big" disabled={!live} onClick={() => setScan(true)}>{t('Fangen (Code scannen)')}</button>

      {myProof.map((c) => (
        <div key={c.id} className="notice stack">
          <strong>{t('Beweis für den Fang von {0} hochladen', { 0: nameOf(s, c.runner_id) })}</strong>
          <span className="small">{t('Bis')} {clock(c.expires_at)}</span>
          <label className="button primary">{t('Foto/Video aufnehmen')}<input type="file" accept="image/*,video/*" capture="environment" hidden onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void act(async () => api.catchMedia(c.id, await uploadProof(g.id, f, f.name)), t('Fang bestätigt.'));
          }} /></label>
        </div>
      ))}
      {myPending.map((c) => <div key={c.id} className="notice">{t('Warte auf Bestätigung von')} {nameOf(s, c.runner_id)} {t('(bis')} {clock(c.expires_at)}).</div>)}

      <Section title={t('Blitzjagd')} badge={<span className="badge">{g.speedhunts_left} {t('übrig')}</span>}>
        {running.map((sh) => (
          <div key={sh.id} className="stack sub">
            <div className="row">
              <strong className="spacer">{sh.is_penalty ? t('Straf-Blitzjagd') : t('Blitzjagd')}: {nameOf(s, sh.target_id)}</strong>
              <span className="badge red">{sh.queries_used}/{sh.queries_total}</span>
            </div>
            <div className="muted small">{t('Ohne Zeitlimit: endet nach der letzten Abfrage oder beim Fang.')}</div>
            <button className="primary" disabled={!live || sh.queries_used >= sh.queries_total} onClick={() => act(() => api.speedhuntQuery(sh.id), t('Standort abgefragt.'))}>
              {t('Standort abfragen (')}{sh.queries_total - sh.queries_used} {t('übrig)')}
            </button>
          </div>
        ))}
        {waiting.map((sh) => <div key={sh.id} className="muted small">{t('Aufgeschoben:')} {nameOf(s, sh.target_id)}</div>)}
        {canTrigger ? (
          <div className="row">
            <select aria-label={t('Ziel')} value={target} onChange={(e) => setTarget(e.target.value)} style={{ flex: 1 }}>
              <option value="">{t('Ziel wählen …')}</option>
              {free.map((p) => <option key={p.id} value={p.id} disabled={!!p.protected}>{p.tag ? `${p.tag} · ` : ''}{p.name}{p.protected ? t(' (geschützt)') : ''}</option>)}
            </select>
            <Confirm className="primary" disabled={!live || !target || g.speedhunts_left <= 0} label={t('Starten')} confirm={t('Blitzjagd starten?')}
              onYes={() => act(() => api.speedhuntStart(g.id, target), t('Blitzjagd läuft.'))} />
          </div>
        ) : <div className="muted small">{t('In diesem Spiel gibt es keine Blitzjagden.')}</div>}
      </Section>

      <Section title={t('Spieler ({0} frei)', { 0: free.length })}>
        <ul className="list">
          {players.map((p) => {
            const last = [...s.pings].reverse().find((x) => x.participant_id === p.id && x.lat != null);
            const transit = s.transits.find((t) => t.participant_id === p.id);
            const livePos = s.positions.find((x) => x.participant_id === p.id && x.live);
            return (
              <li key={p.id}>
                <div className="spacer">
                  <div>{p.tag && <span className="tag">{p.tag}</span>}{p.name} {p.protected && <span className="badge">{t('geschützt')}</span>} {livePos && <span className="badge red">{t('LIVE')}</span>}</div>
                  <div className="muted small">
                    {STATE_LABELS[p.state] ?? p.state}
                    {last && ` · ${SOURCE_LABELS[last.source] ?? last.source} ${clock(last.at)}${last.stale_seconds ? t(' ({0} min alt)', { 0: Math.round(last.stale_seconds / 60) }) : ''}`}
                    {transit && t(' · fährt {0} {1}', { 0: TRANSPORT_LABELS[transit.mode] ?? transit.mode, 1: transit.line ?? '' })}
                    {p.next_ping_at && t(' · nächster Ping {0}', { 0: clock(p.next_ping_at) })}
                  </div>
                </div>
                {live && ['aktiv', 'ausserhalb'].includes(p.state) && cfg.catch.method.includes('touch_confirm') && (
                  <Confirm className="small" label={t('Gefangen')} confirm={t('{0} gefangen?', { 0: p.name })} onYes={() => act(() => api.catchClaim(g.id, p.id, pos?.lat, pos?.lng), t('Fang gemeldet.'))} />
                )}
              </li>
            );
          })}
        </ul>
      </Section>

      <div className="card small">
        {cfg.taskforce.bounty_per_catch > 0 && <div>{t('Deine Punkte:')} <strong>{s.me.bounty}</strong></div>}
        {s.next_silent_ping_at && <div>{t('Nächster Ping:')} {clock(s.next_silent_ping_at)} {t('(in')} {countdown(s.next_silent_ping_at, now)})</div>}
      </div>
    </div>
  );
}
