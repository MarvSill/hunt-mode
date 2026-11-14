import { useState } from 'react';
import { api, clock, countdown, SOURCE_LABELS, STATE_LABELS, TRANSPORT_LABELS, uploadProof } from '../lib/engine';
import { Confirm, nameOf, nameTag, Section, type PanelProps } from './common';
import { t } from '../i18n';
import Info from '../components/Info';

export default function HunterPanel({ s, now, act, pos }: PanelProps) {
  const g = s.game;
  const cfg = g.config;
  const [codeOpen, setCodeOpen] = useState(false);
  const [code, setCode] = useState('');
  const [claimOpen, setClaimOpen] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const players = s.participants.filter((p) => p.role === 'spieler');
  const free = players.filter((p) => ['aktiv', 'ausserhalb', 'notfall'].includes(p.state));
  const running = s.speedhunts.filter((x) => x.status === 'laeuft');
  const live = ['laeuft', 'finale'].includes(g.status) && !g.paused;
  const myProof = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_beweis');
  const myPending = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_bestaetigung');

  const myRejected = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'abgelehnt' && now - new Date(c.at).getTime() < 10 * 60000);

  function sendCode() {
    const c = code.replace(/\D/g, '');
    if (c.length !== 6) return;
    setCodeOpen(false);
    setCode('');
    void act(async () => {
      const r = await api.catchByCode(g.id, c, pos?.lat, pos?.lng);
      setResult(r.status === 'gueltig' ? t('{0} gefangen!', { 0: r.runner }) : t('{0}: Beweis nötig', { 0: r.runner }));
      return r;
    });
  }

  return (
    <div className="stack">
      {codeOpen && (
        <div className="overlay" role="dialog" aria-label={t('Fang-Code eingeben')} onClick={() => setCodeOpen(false)}>
          <form className="card stack" style={{ maxWidth: 400, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}
            onSubmit={(e) => { e.preventDefault(); sendCode(); }}>
            <strong style={{ fontSize: 20 }}>🔢 {t('Fang-Code eingeben')}</strong>
            <span className="small muted">{t('Der Spieler zeigt dir unter „Aktionen“ seinen 6-stelligen Code. Gib ihn hier ein, dann gilt der Fang sofort.')}</span>
            <input autoFocus inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="123 456" aria-label={t('Fang-Code')}
              value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} style={{ fontSize: 32, textAlign: 'center', letterSpacing: 6 }} />
            <button type="submit" className="primary block big" disabled={code.replace(/\D/g, '').length !== 6}>{t('Fang bestätigen')}</button>
            <button type="button" className="ghost block" onClick={() => setCodeOpen(false)}>{t('Abbrechen')}</button>
          </form>
        </div>
      )}
      {claimOpen && (
        <div className="overlay" role="dialog" aria-label={t('Fang melden')} onClick={() => setClaimOpen(false)}>
          <div className="card stack" style={{ maxWidth: 400, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}>
            <strong style={{ fontSize: 20 }}>🤚 {t('Wen hast du gefangen?')}</strong>
            <span className="small muted">{t('Der Spieler bekommt eine Meldung und bestätigt oder lehnt ab. Lehnt er ab, gilt der Fang nicht; dann lass dir den Fang-Code zeigen.')}</span>
            {free.filter((p) => p.state !== 'notfall').map((p) => (
              <button key={p.id} type="button" className="block" onClick={() => {
                setClaimOpen(false);
                void act(() => api.catchClaim(g.id, p.id, pos?.lat, pos?.lng), t('Fang gemeldet. {0} muss bestätigen.', { 0: p.tag ?? p.name }));
              }}>{nameTag(s, p.id)}</button>
            ))}
            {free.length === 0 && <div className="muted small">{t('Kein Spieler ist mehr frei.')}</div>}
            <button type="button" className="ghost block" onClick={() => setClaimOpen(false)}>{t('Abbrechen')}</button>
          </div>
        </div>
      )}
      {g.status === 'vorsprung' && <div className="notice">{t('Vorsprung der Spieler. Die Jagd beginnt in')} {countdown(g.hunt_start_at, now)}{t('. Wartet am Startpunkt.')}</div>}
      {result && <div className="notice success">{result}</div>}

      <div className="grid2">
        <button className="primary big" disabled={!live} onClick={() => setCodeOpen(true)}>🔢 {t('Code eingeben')}</button>
        <button className="primary big" disabled={!live} onClick={() => setClaimOpen(true)}>🤚 {t('Fang melden')}</button>
      </div>
      <div className="muted small">{t('Fangen')} <Info title={t('Fangen')} text={t('Zwei Wege, jeder geht für sich: den Fang-Code des Spielers eingeben, oder den Fang melden und der Spieler bestätigt.')} /></div>
      {myRejected.map((c) => <div key={c.id} className="notice error">{t('{0} hat den Fang abgelehnt. Lass dir den Fang-Code zeigen.', { 0: nameOf(s, c.runner_id) })}</div>)}

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

      {cfg.speedhunt.enabled && (
        <div className="card small">
          ⚡ {t('Blitzjagd: Knopf bei der Karte · noch {0}', { 0: g.speedhunts_left })}
          {running.map((sh) => <div key={sh.id} className="muted">{t('Läuft: {0} · {1}/{2} Abfragen', { 0: nameTag(s, sh.target_id), 1: sh.queries_used, 2: sh.queries_total })}</div>)}
        </div>
      )}

      <Section title={t('Spieler ({0} frei)', { 0: free.length })}>
        <ul className="list">
          {players.map((p) => {
            const last = [...s.pings].reverse().find((x) => x.participant_id === p.id && x.lat != null);
            const transit = s.transits.find((t) => t.participant_id === p.id);
            const livePos = s.positions.find((x) => x.participant_id === p.id && x.live);
            return (
              <li key={p.id}>
                <div className="spacer">
                  <div>{p.tag ? <span className="tag">{p.tag}</span> : p.name} {p.protected && <span className="badge">{t('geschützt')}</span>} {livePos && <span className="badge red">{t('LIVE')}</span>}</div>
                  <div className="muted small">
                    {STATE_LABELS[p.state] ?? p.state}
                    {last && ` · ${SOURCE_LABELS[last.source] ?? last.source} ${clock(last.at)}${last.stale_seconds ? t(' ({0} min alt)', { 0: Math.round(last.stale_seconds / 60) }) : ''}`}
                    {transit && t(' · fährt {0} {1}', { 0: TRANSPORT_LABELS[transit.mode] ?? transit.mode, 1: transit.line ?? '' })}
                    {p.next_ping_at && t(' · nächster Ping in {0}', { 0: countdown(p.next_ping_at, now) })}
                  </div>
                </div>
                {live && ['aktiv', 'ausserhalb'].includes(p.state) && (
                  <Confirm className="small" label={t('Gefangen')} confirm={t('{0} gefangen?', { 0: p.tag ?? p.name })} onYes={() => act(() => api.catchClaim(g.id, p.id, pos?.lat, pos?.lng), t('Fang gemeldet.'))} />
                )}
              </li>
            );
          })}
        </ul>
      </Section>

      <div className="card small">
        {cfg.taskforce.bounty_per_catch > 0 && <div>{t('Deine Punkte:')} <strong>{s.me.bounty}</strong></div>}
        {s.next_silent_ping_at && <div style={{ fontSize: 18 }}>⏱ {t('Nächster Ping in {0}', { 0: countdown(s.next_silent_ping_at, now) })} <span className="muted small">({clock(s.next_silent_ping_at)})</span></div>}
      </div>
    </div>
  );
}
