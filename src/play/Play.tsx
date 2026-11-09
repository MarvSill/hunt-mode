import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import Icon, { type IconName } from '../components/Icon';
import MapView, { type Marker } from '../components/MapView';
import RulesSummary from '../components/RulesSummary';
import { api, clock, countdown, SOURCE_LABELS, type MapFeature, type Notification } from '../lib/engine';
import { errorText } from '../lib/supabase';
import { useTracker } from '../lib/tracker';
import { useGameState, useNow } from '../lib/useGame';
import { alarmKindOf, ring, unlockAudio, VIBRATION } from '../lib/alarm';
import AlarmSettingsBox from './AlarmSettings';
import Chat from './Chat';
import EmergencyBox from './EmergencyBox';
import { colorFor, Confirm, nameOf, Section, tagOf } from './common';
import { CallButtons } from './EmergencyBox';
import HunterPanel from './HunterPanel';
import PlayerPanel from './PlayerPanel';
import Result from './Result';
import { t, lazy } from '../i18n';
import { isNative, nativeNotify, openAppSettings } from '../lib/native';

type Tab = 'karte' | 'aktionen' | 'meldungen' | 'chat';
const TABS: [Tab, string, IconName][] = lazy([['karte', 'Karte', 'map'], ['aktionen', 'Aktionen', 'bolt'], ['meldungen', 'Meldungen', 'bell'], ['chat', 'Chat', 'chat']]);

function beep(critical: boolean) {
  try {
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    const ctx = new Ctx();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.frequency.value = critical ? 880 : 660;
    g.gain.value = 0.15;
    o.connect(g).connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + (critical ? 0.6 : 0.2));
  } catch {
    // ohne Ton
  }
}

export default function PlayPage() {
  const { id } = useParams<{ id: string }>();
  const [toasts, setToasts] = useState<Notification[]>([]);
  const [tab, setTab] = useState<Tab>('karte');
  const [zones, setZones] = useState<MapFeature[]>([]);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [notifPerm, setNotifPerm] = useState(typeof Notification !== 'undefined' ? Notification.permission : 'denied');
  const mapVersion = useRef<number | null>(null);
  const [sosAsk, setSosAsk] = useState(false);
  const [seenNotes, setSeenNotes] = useState(0);

  const roleRef = useRef<string | undefined>(undefined);
  const lastAlarm = useRef(0);
  useEffect(() => {
    // Browser spielen Töne erst nach einer Berührung der Seite ab.
    document.addEventListener('pointerdown', unlockAudio, { once: true });
    return () => document.removeEventListener('pointerdown', unlockAudio);
  }, []);

  const onNew = useCallback((list: Notification[]) => {
    setToasts((t) => [...[...list].reverse(), ...t].slice(0, 4));
    const crit = list.some((n) => n.priority === 'kritisch');
    const high = list.some((n) => n.priority !== 'normal');
    // Spieler: bei jedem Ping und jeder Blitzjagd klingeln (höchstens alle 3 s, falls mehrere gleichzeitig kommen).
    // Notfall: bei allen klingeln, egal welche Rolle.
    const sos = list.some((n) => n.kind === 'emergency');
    const alarm = sos ? 'blitzjagd' : roleRef.current === 'spieler' ? alarmKindOf(list.map((n) => n.kind)) : null;
    if (alarm) {
      if (Date.now() - lastAlarm.current > 3000) {
        lastAlarm.current = Date.now();
        ring(alarm);
      }
    } else if (high) {
      navigator.vibrate?.(crit ? [300, 100, 300, 100, 300] : [200]);
      beep(crit);
    }
    // Echte App im Hintergrund: Benachrichtigung des Handys (mit Ton und Vibration), auch bei gesperrtem Bildschirm.
    if (isNative && document.visibilityState !== 'visible') {
      for (const n of list) void nativeNotify(n.id, n.title, n.body);
    }
    // Web-App im Hintergrund: Systembenachrichtigung über den Service Worker (solange die App offen ist).
    else if (document.visibilityState !== 'visible' && typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      void navigator.serviceWorker?.getRegistration().then((reg) => {
        for (const n of list) {
          const kind = alarmKindOf([n.kind]);
          const opts = { body: n.body, tag: `hm-${n.id}`, icon: `${import.meta.env.BASE_URL}icon.svg`, requireInteraction: n.priority === 'kritisch' || !!kind, vibrate: kind ? VIBRATION[kind] : undefined };
          if (reg) void reg.showNotification(n.title, opts);
          else new Notification(n.title, opts);
        }
      });
    }
    for (const n of list) setTimeout(() => setToasts((t) => t.filter((x) => x.id !== n.id)), n.priority === 'kritisch' ? 15000 : 7000);
  }, []);

  const { state: s, error, reload, offsetMs } = useGameState(id, onNew);
  const now = useNow(offsetMs);
  const role = s?.me.role;
  roleRef.current = role;
  const tracking = !!s && role !== 'zuschauer' && !['beendet', 'archiviert'].includes(s.game.status)
    && !(role === 'spieler' && ['gefangen', 'disqualifiziert', 'aufgegeben', 'verloren'].includes(s.me.state) && !s.game.config.catch.track_after_catch);
  const [kick, setKick] = useState(0);
  const [onlyLastPing, setOnlyLastPingState] = useState(() => {
    try { return localStorage.getItem('hm-pings') === 'last'; } catch { return false; }
  });
  const setOnlyLastPing = (v: boolean) => {
    setOnlyLastPingState(v);
    try { localStorage.setItem('hm-pings', v ? 'last' : 'all'); } catch { /* nur für diese Sitzung */ }
  };
  const tracker = useTracker(id, tracking, kick);
  const pos = tracker.last ? { lat: tracker.last.lat, lng: tracker.last.lng } : null;

  // Karte neu laden, wenn sich Zonen ändern (Ankündigung, Exit, neue Sperrzone).
  useEffect(() => {
    if (!s || !id) return;
    if (mapVersion.current === s.game.map_version) return;
    mapVersion.current = s.game.map_version;
    void api.map(id).then(setZones, () => undefined);
  }, [s, id]);

  useEffect(() => {
    if (s?.me.location_requested) setKick((k) => k + 1);
  }, [s?.me.location_requested]);

  const act = useCallback(async (fn: () => Promise<unknown>, okText?: string) => {
    setMsg(null);
    try {
      await fn();
      if (okText) setMsg({ ok: true, text: okText });
      await reload();
      return true;
    } catch (err) {
      setMsg({ ok: false, text: errorText(err) });
      return false;
    }
  }, [reload]);

  const markers = useMemo<Marker[]>(() => {
    if (!s) return [];
    const list: Marker[] = [];
    const tf = role === 'hunter';
    const fade = s.game.config.ping.fade_after_minutes * 60000;
    // Hunter wählen: alle bisherigen Pings oder nur den letzten je Spieler.
    const lastPing = new Map<string, string>();
    for (const p of s.pings) {
      if (p.lat == null) continue;
      const prev = s.pings.find((x) => x.id === lastPing.get(p.participant_id));
      if (!prev || new Date(p.at) >= new Date(prev.at)) lastPing.set(p.participant_id, p.id);
    }
    for (const p of s.pings) {
      if (p.lat == null || p.lng == null) continue;
      if (onlyLastPing && role !== 'spieler' && lastPing.get(p.participant_id) !== p.id) continue;
      if (role === 'spieler' && p.participant_id === s.me.id && p.source === 'proximity') continue;
      const age = now - new Date(p.at).getTime();
      const label = `${nameOf(s, p.participant_id)} · ${SOURCE_LABELS[p.source] ?? p.source}${p.n ? ` ${p.n}` : ''} · ${clock(p.at)}${p.stale_seconds ? t(' ({0} min alt)', { 0: Math.round(p.stale_seconds / 60) }) : ''}${p.is_fake ? t(' · FAKE') : ''}`;
      list.push({ id: p.id, lat: p.lat, lng: p.lng, color: colorFor(s, p.participant_id), label, kind: 'ping', opacity: Math.max(0.3, 1 - age / Math.max(fade, 1)), accuracy: p.accuracy_m, text: tagOf(s, p.participant_id) });
    }
    for (const x of s.positions) {
      const isMe = x.participant_id === s.me.id;
      const pp = s.participants.find((q) => q.id === x.participant_id);
      list.push({
        id: `pos${x.participant_id}`, lat: x.lat, lng: x.lng, accuracy: x.accuracy_m,
        color: isMe ? '#58a6ff' : colorFor(s, x.participant_id), kind: isMe ? 'me' : pp?.role === 'spieler' ? 'player' : 'hunter',
        label: `${isMe ? t('Du') : pp?.name ?? '?'}${x.live && !isMe ? t(' (LIVE)') : ''} · ${clock(x.at)}`, pulse: x.live && tf && !isMe, text: pp?.tag ?? undefined,
      });
    }
    // Eigene Live-Position (schneller als der Server-Stand)
    if (pos && !s.positions.some((x) => x.participant_id === s.me.id)) {
      list.push({ id: 'me', lat: pos.lat, lng: pos.lng, color: '#58a6ff', kind: 'me', label: t('Du'), accuracy: tracker.last?.acc, text: s.participants.find((q) => q.id === s.me.id)?.tag ?? undefined });
    }
    for (const e of s.me.effects) {
      if (e.type === 'hunter_snapshot') {
        for (const h of (e.payload.hunters as { name: string; tag?: string; lat: number; lng: number; at?: string }[]) ?? []) {
          list.push({ id: `hs${e.id}${h.name}`, lat: h.lat, lng: h.lng, color: '#f85149', kind: 'hunter', label: t('Hunter {0} · Ping {1} (nicht live)', { 0: h.tag ? `${h.tag} ${h.name}` : h.name, 1: clock(h.at) }), text: h.tag });
        }
      }
    }
    for (const n of s.notifications.slice(0, 10)) {
      if (n.kind === 'proximity_self' && n.payload.lat != null && now - new Date(n.at).getTime() < 15 * 60000) {
        list.push({ id: `px${n.id}`, lat: n.payload.lat as number, lng: n.payload.lng as number, color: '#d29922', kind: 'player', label: t('{0} (in der Nähe)', { 0: n.payload.name }) });
      }
    }
    for (const e of s.emergencies) {
      if (e.lat != null && e.lng != null) list.push({ id: `e${e.id}`, lat: e.lat, lng: e.lng, color: '#ff0000', kind: 'emergency', label: t('NOTFALL {0}', { 0: nameOf(s, e.participant_id) }), pulse: true });
    }
    return list;
  }, [s, now, pos, role, tracker.last?.acc, onlyLastPing]);

  if (!s) {
    return (
      <div className="app">
        {error ? <div className="notice error">{error}</div> : <div className="muted">{t('Lade Spiel …')}</div>}
        <Link to={`/spiel/${id}`}>{t('Zurück')}</Link>
      </div>
    );
  }

  const g = s.game;
  const ended = ['beendet', 'archiviert'].includes(g.status);
  const players = s.participants.filter((p) => p.role === 'spieler');
  const live = ['vorsprung', 'laeuft', 'finale'].includes(g.status);
  const headline = g.paused ? t('UNTERBROCHEN: NOTFALL') : g.status === 'vorsprung' ? t('Jagd in {0}', { 0: countdown(g.hunt_start_at, now) })
    : g.status === 'finale' ? t('Fluchtpunkt bis {0} · {1}', { 0: clock(g.deadline_at, g.timezone), 1: countdown(g.deadline_at, now) })
    : ended ? t('Spiel beendet') : t('Ende in {0}', { 0: countdown(g.ends_at, now) });

  const roleLabel = role === 'spieler' ? t('Spieler') : role === 'zuschauer' ? t('Zuschauer') : t('Hunter');
  const canSos = !ended && role !== 'zuschauer' && s.me.state !== 'notfall';
  const unseen = tab === 'meldungen' ? 0 : s.notifications.length - seenNotes;
  function openTab(t: Tab) {
    setTab(t);
    if (t === 'meldungen' && s) setSeenNotes(s.notifications.length);
  }

  return (
    <div className="app wide play">
      <div className="topbar">
        <Link to="/" className="button ghost back" aria-label={t('Zur Startseite')}><Icon name="back" /></Link>
        <div className="spacer play-head">
          <div className="sub-line">
            <span className={`role-pill ${role === 'spieler' ? 'spieler' : role === 'zuschauer' ? 'zuschauer' : 'hunter'}`} style={{ padding: '1px 8px', marginRight: 6 }}>{roleLabel}</span>
            {g.name}{g.is_test ? t(' · Probelauf') : ''}{(g.phase_count ?? 0) > 1 && g.config.zone.shrink_every_minutes > 0 && t(' · Phase {0}/{1}', { 0: g.phase, 1: g.phase_count })}
          </div>
          <div className="headline">{headline}</div>
        </div>
        {canSos && <button className="sos" aria-label={t('NOTFALL')} onClick={() => setSosAsk(true)}>{t('SOS')}</button>}
      </div>

      {sosAsk && (
        <div className="overlay" role="dialog" aria-label={t('Notfall melden')} onClick={() => setSosAsk(false)}>
          <div className="card stack emergency-card" style={{ maxWidth: 440, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}>
            <strong style={{ fontSize: 20 }}>{t('🚨 Notfall melden?')}</strong>
            <span className="small">{t('Das ganze Spiel wird sofort unterbrochen. Alle werden alarmiert, sehen deinen Standort und kommen helfen. Die Hunter sehen auch deinen Notfallkontakt. Bei einem Versehen kannst du den Notfall danach wieder beenden; dann geht das Spiel weiter.')}</span>
            <button className="danger block big" onClick={() => {
              setSosAsk(false);
              void act(() => api.emergency(g.id, pos?.lat, pos?.lng), t('Notfall gemeldet. Bei Gefahr: 117 (Polizei) oder 112 anrufen.'));
            }}>{t('Ja, Notfall melden')}</button>
            <div className="muted small">{t('Bei Gefahr direkt anrufen:')}</div>
            <CallButtons />
            <button className="ghost block" onClick={() => setSosAsk(false)}>{t('Abbrechen')}</button>
          </div>
        </div>
      )}

      <div className="toasts">
        {toasts.slice(0, 1).map((n) => (
          <div key={n.id} className={`toast ${n.priority}`} role="status" onClick={() => setToasts((t) => t.filter((x) => x.id !== n.id))}>
            {toasts.length > 1 && <span className="more">+{toasts.length - 1}</span>}
            <strong>{n.title}</strong>{n.body && <div className="small">{n.body}</div>}
          </div>
        ))}
      </div>

      {g.paused && (
        <div className="notice error pulse" role="alert" style={{ marginBottom: 8 }}>
          <strong>{t('Spiel unterbrochen.')}</strong> {g.pause_reason ?? t('Notfall')}{t('. Geht zum Standort auf der Karte und helft. Sobald der Notfall beendet ist, geht das Spiel weiter.')}
        </div>
      )}
      {tracking && tracker.status !== 'ok' && (
        <div className="notice error" style={{ marginBottom: 8 }}>
          {tracker.status === 'verweigert' && isNative ? (
            <>{t('Standort ist blockiert. Erlaube den Standort für Hunt Mode auf „Immer“, sonst kannst du nicht mitspielen.')} <button className="small" onClick={openAppSettings}>{t('Einstellungen öffnen')}</button></>
          ) : tracker.status === 'verweigert' ? t('Standort ist blockiert. Erlaube den Standort in den Browser-Einstellungen, sonst kannst du nicht mitspielen.')
            : tracker.status === 'warte' ? t('Warte auf GPS …') : t('GPS-Problem: {0}', { 0: tracker.error ?? '' })}
        </div>
      )}
      {tracking && tracker.sendError && (
        <div className="notice error" style={{ marginBottom: 8 }}>{t('Standort wird nicht gesendet: {0}', { 0: tracker.sendError })}</div>
      )}
      {tracker.queued > 3 && <div className="notice" style={{ marginBottom: 8 }}>{t('Offline:')} {tracker.queued} {t('Standorte warten auf Verbindung.')}</div>}
      {!ended && notifPerm === 'default' && typeof Notification !== 'undefined' && (
        <button className="small block" style={{ marginBottom: 8 }} onClick={() => void Notification.requestPermission().then(setNotifPerm)}>{t('Benachrichtigungen erlauben')}</button>
      )}
      {msg && <div className={`notice ${msg.ok ? 'success' : 'error'}`} style={{ marginBottom: 8 }} onClick={() => setMsg(null)}>{msg.text}</div>}

      {ended ? <Result s={s} zones={zones} /> : (
        <>
          <EmergencyBox s={s} act={act} showMap={() => setTab('karte')} />
          <nav className="tabbar">
            {TABS.map(([t, label, icon]) => (
              <button key={t} className={tab === t ? 'active' : ''} onClick={() => openTab(t)}>
                <Icon name={icon} />{label}
                {t === 'meldungen' && unseen > 0 && <span className="pip" aria-label={`${unseen} neu`} />}
              </button>
            ))}
          </nav>
          <div style={{ display: tab === 'karte' ? 'block' : 'none' }}>
            <div className="map-box"><MapView zones={zones} markers={markers} fitKey={g.id} height="62dvh" showDay={g.phase ?? g.current_day} /></div>
            <div className="row small" style={{ marginTop: 8 }}>
              {role === 'spieler' && s.me.next_ping_at && <span className="badge">{t('Nächster Ping')} {clock(s.me.next_ping_at)}</span>}
              {s.next_silent_ping_at && role !== 'spieler' && <span className="badge">{t('Nächster Ping')} {clock(s.next_silent_ping_at)}</span>}
              <span className="badge">{s.free_players}/{players.length} {t('Spieler frei')}</span>
              {s.speedhunts.some((x) => x.status === 'laeuft') && <span className="badge red pulse">{t('Blitzjagd')}</span>}
              {tracker.last && <span className="badge">{t('GPS ±')}{tracker.last.acc} m</span>}
              {tracking && <span className={`badge${tracker.sentAt && Date.now() - tracker.sentAt < 60000 ? '' : ' red'}`}>📡 {tracker.sentAt ? t('gesendet vor {0} s', { 0: Math.max(0, Math.round((Date.now() - tracker.sentAt) / 1000)) }) : t('noch nicht gesendet')}</span>}
              {role !== 'spieler' && s.pings.some((p) => p.lat != null) && (
                <button className="small" onClick={() => setOnlyLastPing(!onlyLastPing)}>{onlyLastPing ? t('Nur letzter Ping je Spieler') : t('Alle Pings')} ⇄</button>
              )}
            </div>
          </div>

          <div style={{ display: tab === 'aktionen' ? 'block' : 'none' }}>
            {role === 'spieler' && <PlayerPanel s={s} now={now} act={act} pos={pos} />}
            {role === 'spieler' && <AlarmSettingsBox />}
            {role === 'hunter' && <HunterPanel s={s} now={now} act={act} pos={pos} />}
            {role === 'zuschauer' && <div className="card muted">{t('Du schaust zu. Positionen siehst du mit')} {g.config.spectator.delay_minutes} {t('min Verzögerung.')}</div>}
            {g.host && (
              <Section title={t('Spiel steuern')} badge={g.is_test ? <span className="badge">{t('Probelauf')}</span> : undefined}>
                <div className="muted small">{t('Du hast das Spiel erstellt. Es läuft am Stück bis')} {clock(g.ends_at, g.timezone)} ({countdown(g.ends_at, now)}).</div>
                {g.is_test && live && (
                  <>
                    <div className="muted small">{t('Probelauf: Spielzeit vorspulen (Timer laufen sofort ab).')}</div>
                    <div className="row">
                      {[1, 5, 15, 60].map((m) => <button key={m} className="small" onClick={() => act(() => api.advance(g.id, m))}>+{m} {t('min')}</button>)}
                    </div>
                  </>
                )}
                <Confirm className="ghost" disabled={!live} label={t('Spiel abbrechen')} confirm={t('Spiel jetzt für alle beenden?')} onYes={() => act(() => api.endGame(g.id))} />
              </Section>
            )}
            <details className="acc">
              <summary>
                <span className="ico" aria-hidden="true">📖</span>
                <span className="spacer"><span className="t">{t('Spielregeln')}</span><span className="s" style={{ display: 'block' }}>{t('Alles Wichtige in Kürze')}</span></span>
                <Icon name="chevron" className="chev" />
              </summary>
              <div className="body"><RulesSummary config={g.config} /></div>
            </details>
          </div>

          <div style={{ display: tab === 'meldungen' ? 'block' : 'none' }}>
            <div className="card">
              <ul className="list">
                {s.notifications.map((n) => (
                  <li key={n.id} className={`note ${n.priority}`}>
                    <div className="spacer">
                      <div><strong>{n.title}</strong></div>
                      {n.body && <div className="small">{n.body}</div>}
                    </div>
                    <span className="muted small">{clock(n.at, g.timezone)}</span>
                  </li>
                ))}
                {s.notifications.length === 0 && <li className="muted">{t('Noch keine Meldungen.')}</li>}
              </ul>
            </div>
          </div>

          {tab === 'chat' && <Chat s={s} />}

        </>
      )}
    </div>
  );
}
