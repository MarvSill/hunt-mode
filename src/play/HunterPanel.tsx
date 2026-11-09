import { useCallback, useState } from 'react';
import { api, clock, countdown, SOURCE_LABELS, STATE_LABELS, TRANSPORT_LABELS, uploadProof } from '../lib/engine';
import { Confirm, nameOf, Section, type PanelProps } from './common';
import Scanner from './Scanner';

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
      setResult(r.status === 'gueltig' ? `${r.runner} gefangen!` : `${r.runner}: Beweis nötig`);
      return r;
    });
  }, [act, g.id, pos]);

  return (
    <div className="stack">
      {scan && <Scanner onCode={onCode} onClose={() => setScan(false)} />}
      {g.status === 'vorsprung' && <div className="notice">Vorsprung der Spieler. Die Jagd beginnt in {countdown(g.hunt_start_at, now)}. Bleibt im HQ.</div>}
      {result && <div className="notice success">{result}</div>}

      <button className="primary block big" disabled={!live} onClick={() => setScan(true)}>Fangen (Code scannen)</button>

      {myProof.map((c) => (
        <div key={c.id} className="notice stack">
          <strong>Beweis für den Fang von {nameOf(s, c.runner_id)} hochladen</strong>
          <span className="small">Bis {clock(c.expires_at)}</span>
          <label className="button primary">Foto/Video aufnehmen<input type="file" accept="image/*,video/*" capture="environment" hidden onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void act(async () => api.catchMedia(c.id, await uploadProof(g.id, f, f.name)), 'Fang bestätigt.');
          }} /></label>
        </div>
      ))}
      {myPending.map((c) => <div key={c.id} className="notice">Warte auf Bestätigung von {nameOf(s, c.runner_id)} (bis {clock(c.expires_at)}).</div>)}

      <Section title="Blitzjagd" badge={<span className="badge">{g.speedhunts_left} übrig</span>}>
        {running.map((sh) => (
          <div key={sh.id} className="stack sub">
            <div className="row">
              <strong className="spacer">{sh.is_penalty ? 'Straf-Blitzjagd' : 'Blitzjagd'}: {nameOf(s, sh.target_id)}</strong>
              <span className="badge red">{sh.queries_used}/{sh.queries_total}</span>
            </div>
            <div className="muted small">Ohne Zeitlimit: endet nach der letzten Abfrage oder beim Fang.</div>
            <button className="primary" disabled={!live || sh.queries_used >= sh.queries_total} onClick={() => act(() => api.speedhuntQuery(sh.id), 'Standort abgefragt.')}>
              Standort abfragen ({sh.queries_total - sh.queries_used} übrig)
            </button>
          </div>
        ))}
        {waiting.map((sh) => <div key={sh.id} className="muted small">Aufgeschoben: {nameOf(s, sh.target_id)}</div>)}
        {canTrigger ? (
          <div className="row">
            <select aria-label="Ziel" value={target} onChange={(e) => setTarget(e.target.value)} style={{ flex: 1 }}>
              <option value="">Ziel wählen …</option>
              {free.map((p) => <option key={p.id} value={p.id} disabled={!!p.protected}>{p.name}{p.protected ? ' (geschützt)' : ''}</option>)}
            </select>
            <Confirm className="primary" disabled={!live || !target || g.speedhunts_left <= 0} label="Starten" confirm="Blitzjagd starten?"
              onYes={() => act(() => api.speedhuntStart(g.id, target), 'Blitzjagd läuft.')} />
          </div>
        ) : <div className="muted small">In diesem Spiel gibt es keine Blitzjagden.</div>}
      </Section>

      <Section title={`Spieler (${free.length} frei)`}>
        <ul className="list">
          {players.map((p) => {
            const last = [...s.pings].reverse().find((x) => x.participant_id === p.id && x.lat != null);
            const transit = s.transits.find((t) => t.participant_id === p.id);
            const livePos = s.positions.find((x) => x.participant_id === p.id && x.live);
            return (
              <li key={p.id}>
                <div className="spacer">
                  <div>{p.name} {p.protected && <span className="badge">geschützt</span>} {livePos && <span className="badge red">LIVE</span>}</div>
                  <div className="muted small">
                    {STATE_LABELS[p.state] ?? p.state}
                    {last && ` · ${SOURCE_LABELS[last.source] ?? last.source} ${clock(last.at)}${last.stale_seconds ? ` (${Math.round(last.stale_seconds / 60)} min alt)` : ''}`}
                    {transit && ` · fährt ${TRANSPORT_LABELS[transit.mode] ?? transit.mode} ${transit.line ?? ''}`}
                    {p.next_ping_at && ` · nächster Ping ${clock(p.next_ping_at)}`}
                  </div>
                </div>
                {live && ['aktiv', 'ausserhalb'].includes(p.state) && cfg.catch.method.includes('touch_confirm') && (
                  <Confirm className="small" label="Gefangen" confirm={`${p.name} gefangen?`} onYes={() => act(() => api.catchClaim(g.id, p.id, pos?.lat, pos?.lng), 'Fang gemeldet.')} />
                )}
              </li>
            );
          })}
        </ul>
      </Section>

      <div className="card small">
        {cfg.taskforce.bounty_per_catch > 0 && <div>Deine Punkte: <strong>{s.me.bounty}</strong></div>}
        {s.next_silent_ping_at && <div>Nächster Ping: {clock(s.next_silent_ping_at)} (in {countdown(s.next_silent_ping_at, now)})</div>}
      </div>
    </div>
  );
}
