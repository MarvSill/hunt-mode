import { useEffect, useMemo, useState } from 'react';
import ReplayAsk from '../components/ReplayAsk';
import MapView, { type Marker } from '../components/MapView';
import { api, clock, SOURCE_LABELS, STATE_LABELS, type GameState, type MapFeature, type Replay } from '../lib/engine';
import { errorText } from '../lib/supabase';
import { colorFor, nameOf, tagOf } from './common';
import { t as tr, lazy } from '../i18n';

const REASONS: Record<string, string> = lazy({
  zeit_abgelaufen: 'Die Zeit ist abgelaufen.', alle_gefangen: 'Alle Spieler wurden gefangen.', alle_im_ziel_oder_gefangen: 'Alle sind am Fluchtpunkt oder gefangen.',
  letzter_ueberlebender: 'Nur noch eine Person ist frei.', alle_ausgeschieden: 'Alle Spieler sind ausgeschieden.', abgebrochen: 'Das Spiel wurde abgebrochen.',
});

const EVENT_LABELS: Record<string, string> = lazy({
  game_created: 'Spiel erstellt', game_started: 'Spiel gestartet', hunt_begin: 'Jagd beginnt', speedhunt_start: 'Blitzjagd gestartet',
  game_ended: 'Spielende', day_reset: 'Neuer Abschnitt', catch: 'Fang', emergency: 'Notfall', item_used: 'Joker eingesetzt',
  map_saved: 'Karte gespeichert', config_changed: 'Regeln geändert', participant_joined: 'Beigetreten', participant_left: 'Ausgetreten',
  role_assigned: 'Rolle vergeben', paused: 'Unterbrochen', resumed: 'Weiter', emergency_contact_viewed: 'Notfallkontakt angesehen',
  tick_error: 'Fehler der Spiel-Engine', phase: 'Neue Phase',
});

export default function Result({ s, zones }: { s: GameState; zones: MapFeature[] }) {
  const r = s.game.result;
  const [replay, setReplay] = useState<Replay | null>(null);
  const [t, setT] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [replayAsk, setReplayAsk] = useState(false);
  /** Ping für Ping durchgehen: Nummer des gezeigten Pings (−1 = freie Zeit über den Regler). */
  const [step, setStep] = useState(-1);

  useEffect(() => {
    api.replay(s.game.id).then((x) => {
      setReplay(x);
      setT(new Date(x.start ?? x.end).getTime() / 1000);
    }, (e) => setErr(errorText(e)));
  }, [s.game.id]);

  const start = replay?.start ? new Date(replay.start).getTime() / 1000 : 0;
  const end = replay ? new Date(replay.end).getTime() / 1000 : 0;

  useEffect(() => {
    if (!playing) return;
    const i = setInterval(() => setT((x) => {
      const n = x + Math.max(60, (end - start) / 120);
      if (n >= end) { setPlaying(false); return end; }
      return n;
    }), 100);
    return () => clearInterval(i);
  }, [playing, start, end]);

  // Alle Pings in zeitlicher Reihenfolge, je Spieler nummeriert (A1, A2 …).
  const steps = useMemo(() => {
    if (!replay) return [];
    const count = new Map<string, number>();
    return [...replay.pings].sort((a, b) => a.at.localeCompare(b.at)).map((p) => {
      const n = (count.get(p.participant_id) ?? 0) + 1;
      count.set(p.participant_id, n);
      return { ...p, nr: `${tagOf(s, p.participant_id) ?? ''}${n}`, t: new Date(p.at).getTime() / 1000 };
    });
  }, [replay, s]);

  function goStep(i: number) {
    if (!steps.length) return;
    const k = Math.max(0, Math.min(steps.length - 1, i));
    setPlaying(false);
    setStep(k);
    setT(steps[k].t);
  }
  /** Nächster Ping ab der aktuellen Zeit (auch nach dem Ziehen am Regler). */
  function nextFromTime(dir: 1 | -1) {
    if (step >= 0) return goStep(step + dir);
    const i = dir > 0 ? steps.findIndex((p) => p.t > t) : steps.map((p) => p.t < t).lastIndexOf(true);
    goStep(i < 0 ? (dir > 0 ? steps.length - 1 : 0) : i);
  }

  const { markers, lines } = useMemo(() => {
    const markers: Marker[] = [];
    const lines: { id: string; points: [number, number][]; color: string }[] = [];
    if (!replay) return { markers, lines };
    for (const [pid, pts] of Object.entries(replay.tracks)) {
      const upto = pts.filter((p) => p[0] <= t);
      if (!upto.length) continue;
      const color = colorFor(s, pid);
      // Der ganze Weg bis zum gewählten Zeitpunkt (alle 10 s ein Punkt), nicht nur die Pings.
      lines.push({ id: pid, color, points: upto.map((p) => [p[1], p[2]]) });
      const last = upto[upto.length - 1];
      const p = s.participants.find((x) => x.id === pid);
      markers.push({ id: pid, lat: last[1], lng: last[2], color, label: p?.tag ?? p?.name ?? '?', kind: p?.role === 'spieler' ? 'player' : 'hunter' });
    }
    steps.forEach((pg, i) => {
      const current = step === i;
      if (!(pg.t <= t && pg.t > t - 3600) && !current) return;
      markers.push({
        id: `p${i}`, lat: pg.lat, lng: pg.lng, color: pg.is_fake ? '#8b949e' : colorFor(s, pg.participant_id), text: pg.nr,
        label: `${tr('Ping {0}', { 0: pg.nr })} · ${nameOf(s, pg.participant_id)} · ${SOURCE_LABELS[pg.source] ?? pg.source} · ${clock(pg.at, s.game.timezone)}${pg.is_fake ? tr(' (Fake)') : ''}`,
        kind: 'ping', opacity: current ? 1 : 0.7, ring: current ? '#ffd60a' : pg.source === 'speedhunt' ? '#ff3b30' : undefined,
      });
    });
    return { markers, lines };
  }, [replay, t, s, steps, step]);

  const players = s.participants.filter((p) => p.role === 'spieler' || p.state === 'gefangen');
  const winners = new Set(r?.winners ?? []);

  return (
    <div className="stack">
      <div className="card stack" style={{ textAlign: 'center' }}>
        <div className="brand">{tr('Spielende')}</div>
        <h1 style={{ margin: 0 }}>{r?.reason === 'abgebrochen' ? tr('Spiel abgebrochen: keiner hat gewonnen')
          : winners.size ? tr('Sieger: {0}', { 0: [...winners].map((w) => nameOf(s, w)).join(', ') }) : tr('Die Hunter gewinnen')}</h1>
        <div className="muted">{REASONS[r?.reason ?? ''] ?? ''}</div>
        {r && <div className="small">{r.hours} h · {r.catches} {tr('Fänge ·')} {r.speedhunts} {tr('Blitzjagden ·')} {r.pings} {tr('Pings')}</div>}
        <button type="button" className="small" style={{ alignSelf: 'center' }} onClick={() => setReplayAsk(true)}>🔁 {tr('Nochmal spielen')}</button>
        {replayAsk && <ReplayAsk gameId={s.game.id} name={s.game.name} onClose={() => setReplayAsk(false)} />}
        {s.game.config.win.prize && winners.size > 0 && <div className="badge green" style={{ alignSelf: 'center' }}>{tr('Preis:')} {s.game.config.win.prize}</div>}
      </div>
      <div className="card">
        <ul className="list">
          {players.map((p) => (
            <li key={p.id}>
              <span className="dot" style={{ background: colorFor(s, p.id) }} />
              <span className="spacer">{p.tag ? <span className="tag">{p.tag}</span> : p.name}</span>
              <span className={`badge${winners.has(p.id) ? ' green' : ''}`}>{winners.has(p.id) ? tr('Sieg') : r?.reason === 'abgebrochen' && ['aktiv', 'ausserhalb', 'notfall'].includes(p.state) ? tr('Abgebrochen') : STATE_LABELS[p.state] ?? p.state}</span>
              {r?.mode === 'punkte' && <span className="badge">{r.scores[p.id] ?? 0} P</span>}
            </li>
          ))}
          {s.participants.filter((p) => p.role === 'hunter').map((p) => (
            <li key={p.id}><span className="dot" style={{ background: '#f85149' }} /><span className="spacer">{p.tag ? <span className="tag hunter">{p.tag}</span> : p.name}</span><span className="badge red">{tr('Kopfgeld')} {p.bounty}</span></li>
          ))}
        </ul>
      </div>
      <h2>{tr('Wiederholung')}</h2>
      <div className="muted small" style={{ marginTop: -6, marginBottom: 8 }}>{tr('Die Linien zeigen den genauen Weg jeder Person (aufgezeichnet, solange der Standort gesendet wurde). Die Kästchen sind die Pings.')}</div>
      {err && <div className="notice error">{err}</div>}
      {replay && <KeepCard gameId={s.game.id} replay={replay} onChange={(keep) => setReplay({ ...replay, keep_forever: keep })} />}
      {replay && (
        <>
          <MapView zones={zones} markers={markers} lines={lines} fitKey="replay" height="50dvh" />
          <div className="row">
            <button className="small" onClick={() => { setStep(-1); if (t >= end) setT(start); setPlaying(!playing); }}>{playing ? tr('Pause') : tr('Schnelldurchlauf')}</button>
            <input type="range" min={start} max={end} value={t} onChange={(e) => { setStep(-1); setT(+e.target.value); }} style={{ flex: 1 }} aria-label={tr('Zeit')} />
            <span className="small">{clock(new Date(t * 1000).toISOString(), s.game.timezone)}</span>
          </div>
          {steps.length > 0 && (
            <div className="card stack">
              <div className="row" style={{ flexWrap: 'nowrap' }}>
                <button className="small" onClick={() => nextFromTime(-1)} disabled={step === 0} aria-label={tr('Vorheriger Ping')}>◀</button>
                <div className="spacer" style={{ textAlign: 'center' }}>
                  {step >= 0 ? (
                    <>
                      <strong>{tr('Ping {0}', { 0: steps[step].nr })}</strong> · {nameOf(s, steps[step].participant_id)}
                      <div className="small muted">{SOURCE_LABELS[steps[step].source] ?? steps[step].source} · {clock(steps[step].at, s.game.timezone)} · {step + 1}/{steps.length}</div>
                    </>
                  ) : <span className="small">{tr('Ping für Ping durchgehen ({0} Pings)', { 0: steps.length })}</span>}
                </div>
                <button className="small" onClick={() => nextFromTime(1)} disabled={step === steps.length - 1} aria-label={tr('Nächster Ping')}>▶</button>
              </div>
            </div>
          )}
          <details className="card">
            <summary>{tr('Ereignisse (')}{replay.events.length})</summary>
            <ul className="list small">
              {replay.events.map((e, i) => <li key={i}>{clock(e.at, s.game.timezone)} · {EVENT_LABELS[e.type] ?? e.type.replace(/_/g, ' ')}</li>)}
            </ul>
          </details>
        </>
      )}
    </div>
  );
}

/** Wiederholung behalten: sonst werden die Wege 30 Tage nach Spielende gelöscht. Jeder Teilnehmende kann es für dieses Spiel umschalten. */
function KeepCard({ gameId, replay, onChange }: { gameId: string; replay: Replay; onChange: (keep: boolean) => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const keep = !!replay.keep_forever;
  const endedAt = replay.ended_at ? new Date(replay.ended_at).getTime() : null;
  const purgeAt = endedAt ? endedAt + 30 * 86400000 : null;
  const old = purgeAt !== null && Date.now() > purgeAt;
  const gone = !keep && old;
  const toggle = async () => {
    setBusy(true);
    setErr(null);
    try {
      onChange(await api.keepGame(gameId, !keep));
    } catch (e) {
      setErr(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={`notice stack ${keep ? 'success' : ''}`}>
      <strong>{keep ? `⭐ ${tr('Dieses Spiel wird für immer behalten')}` : gone ? tr('Die Wege wurden 30 Tage nach Spielende gelöscht') : tr('Die Wege werden am {0} gelöscht', { 0: new Date(purgeAt ?? Date.now()).toLocaleDateString() })}</strong>
      <span className="small">{keep ? tr('Die Wiederholung bleibt erhalten, bis das Spiel gelöscht wird.') : tr('Nach 30 Tagen werden die aufgezeichneten Wege gelöscht, damit der Speicher reicht. Bei besonders guten Spielen: für immer behalten.')}</span>
      {!old && <button type="button" className={keep ? 'small' : 'small primary'} style={{ alignSelf: 'flex-start' }} disabled={busy} onClick={toggle}>{keep ? tr('Nicht mehr behalten') : `⭐ ${tr('Für immer behalten')}`}</button>}
      {err && <span className="small red">{err}</span>}
    </div>
  );
}
