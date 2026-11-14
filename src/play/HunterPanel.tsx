import { useState } from 'react';
import { api, clock, countdown, SOURCE_LABELS, STATE_LABELS, TRANSPORT_LABELS, uploadProof } from '../lib/engine';
import { Confirm, nameOf, nameTag, Section, type PanelProps } from './common';
import { t } from '../i18n';

export default function HunterPanel({ s, now, act, pos }: PanelProps) {
  const g = s.game;
  const cfg = g.config;
  const [claimOpen, setClaimOpen] = useState(false);
  const players = s.participants.filter((p) => p.role === 'spieler');
  const free = players.filter((p) => ['aktiv', 'ausserhalb', 'notfall'].includes(p.state));
  const running = s.speedhunts.filter((x) => x.status === 'laeuft');
  const live = ['laeuft', 'finale'].includes(g.status) && !g.paused;
  const myProof = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_beweis');
  const myPending = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'wartet_auf_bestaetigung');

  const myRejected = s.catches.filter((c) => c.hunter_id === s.me.id && c.status === 'abgelehnt' && now - new Date(c.at).getTime() < 10 * 60000);

  return (
    <div className="stack">
      {claimOpen && (
        <div className="overlay" role="dialog" aria-label={t('Fang melden')} onClick={() => setClaimOpen(false)}>
          <div className="card stack" style={{ maxWidth: 400, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}>
            <strong style={{ fontSize: 20 }}>🤚 {t('Wen hast du gefangen?')}</strong>
            <span className="small muted">{t('Beim Spieler erscheint sofort die Frage. Bestätigt er, ist er gefangen. Lehnt er ab, gilt der Fang nicht.')}</span>
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

      <button className="primary block big" disabled={!live} onClick={() => setClaimOpen(true)}>🤚 {t('Fang melden')}</button>
      {myRejected.map((c) => <div key={c.id} className="notice error">{t('{0} hat den Fang abgelehnt.', { 0: nameOf(s, c.runner_id) })}</div>)}

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
