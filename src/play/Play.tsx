import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import Icon, { type IconName } from '../components/Icon';
import MapView, { type Marker } from '../components/MapView';
import RulesSummary from '../components/RulesSummary';
import { api, clock, countdown, SOURCE_LABELS, type MapFeature, type Notification } from '../lib/engine';
import { errorText } from '../lib/supabase';
import { useTracker } from '../lib/tracker';
import { useGameState, useNow } from '../lib/useGame';
import { alarmKindOf, ring, unlockAudio, vibrate, VIBRATION } from '../lib/alarm';
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
import NumberField from '../components/NumberField';
import { SpeedhuntButtons, SpeedhuntDialog } from './SpeedhuntMap';
import Loader from '../components/Loader';
import SafetyNotice from './SafetyNotice';
import { DeviceAlert, useOutsideVibration, useRadarAlarm } from './Alerts';

/** Wie viele Pings je Spieler auf der Karte: 1 = nur der letzte, 0 = alle. Jeder wählt selbst (nur auf diesem Gerät). */
function loadPingCount(): number {
  try {
    const v = localStorage.getItem('hm-pings');
    if (v === 'last') return 1;
    if (v === 'all' || v === null) return 0;
    const n = Number(v);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

const RING_LAST = '#ffd60a';
const RING_BLITZ = '#ff3b30';

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
  const [seenChats, setSeenChats] = useState<number | null>(null);

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
    const player = roleRef.current === 'spieler';
    const alarm = sos ? 'blitzjagd' : player ? alarmKindOf(list.map((n) => n.kind)) : null;
    if (alarm) {
      if (Date.now() - lastAlarm.current > 3000) {
        lastAlarm.current = Date.now();
        ring(alarm);
      }
    } else if (high) {
      vibrate(crit ? [300, 100, 300, 100, 300] : [200]);
      beep(crit);
    }
    // Echte App: wichtige Meldungen immer auch als Benachrichtigung des Handys (Ton und Vibration kommen vom Handy,
    // das klappt auch, wenn der Ton der Seite gesperrt ist). Im Hintergrund jede Meldung.
    if (isNative) {
      const hidden = document.visibilityState !== 'visible';
      for (const n of list) {
        const important = n.priority !== 'normal' || n.kind === 'chat' || (player && !!alarmKindOf([n.kind]));
        if (hidden || important) void nativeNotify(n.id, n.title, n.body);
      }
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
  const [pingCount, setPingCountState] = useState(loadPingCount);
  const [pingCustom, setPingCustom] = useState(() => ![0, 1, 3].includes(loadPingCount()));
  const setPingCount = (v: number) => {
    setPingCountState(v);
    try { localStorage.setItem('hm-pings', String(v)); } catch { /* nur für diese Sitzung */ }
  };
  // Spieler: Pings der anderen Spieler zeigen oder ausblenden (nur auf diesem Gerät).
  const [othersHidden, setOthersHiddenState] = useState(() => { try { return localStorage.getItem('hm-pings-andere') === 'aus'; } catch { return false; } });
  const setOthersHidden = (v: boolean) => {
    setOthersHiddenState(v);
    try { localStorage.setItem('hm-pings-andere', v ? 'aus' : 'an'); } catch { /* nur für diese Sitzung */ }
  };
  const [blitzOpen, setBlitzOpen] = useState(false);
  const [pauseReason, setPauseReason] = useState('');
  const tracker = useTracker(id, tracking, kick);
  const pos = tracker.last ? { lat: tracker.last.lat, lng: tracker.last.lng } : null;
  // Handy-App im Hintergrund: nach jedem gesendeten Standort auch den Spielstand holen (neue Pings und Meldungen).
  useEffect(() => {
    if (isNative && tracker.sentAt && document.visibilityState !== 'visible') void reload();
  }, [tracker.sentAt, reload]);

  // Ausserhalb des Spielfelds oder in einer Gefahrenzone: Dauer-Vibration, bis man wieder drin ist.
  const outside = !!s && role === 'spieler' && !s.game.paused && ['vorsprung', 'laeuft', 'finale'].includes(s.game.status)
    && (s.me.out_pending || s.me.state === 'ausserhalb' || s.me.in_restricted);
  useOutsideVibration(outside);
  useRadarAlarm(role === 'spieler' ? s?.me.radar : undefined);

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

  // Beim Öffnen zählen die schon vorhandenen Nachrichten als gelesen.
  useEffect(() => {
    if (s && seenChats === null) setSeenChats(s.notifications.filter((n) => n.kind === 'chat').length);
  }, [s, seenChats]);

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
    // Pings je Spieler nummeriert (A1, A2 …), jeder Spieler in seiner Farbe. Der neueste Ping ist gelb umrandet,
    // Blitzjagd-Pings rot. Jeder wählt selbst, wie viele Pings je Spieler zu sehen sind.
    const byPlayer = new Map<string, typeof s.pings>();
    for (const p of [...s.pings].sort((a, b) => a.at.localeCompare(b.at))) {
      if (p.lat == null || p.lng == null) continue;
      if (role === 'spieler' && othersHidden && p.participant_id !== s.me.id) continue;
      byPlayer.set(p.participant_id, [...(byPlayer.get(p.participant_id) ?? []), p]);
    }
    for (const [pid, pings] of byPlayer) {
      const tag = tagOf(s, pid) ?? '';
      const shown = pingCount > 0 ? pings.slice(-pingCount) : pings;
      const first = pings.length - shown.length;
      shown.forEach((p, i) => {
        const nr = first + i + 1;
        const isLast = nr === pings.length;
        const blitz = p.source === 'speedhunt';
        const age = now - new Date(p.at).getTime();
        const label = `${t('Ping {0}', { 0: `${tag}${nr}` })} · ${nameOf(s, pid)} · ${SOURCE_LABELS[p.source] ?? p.source}${p.n ? ` ${p.n}` : ''} · ${clock(p.at)}${p.stale_seconds ? t(' ({0} min alt)', { 0: Math.round(p.stale_seconds / 60) }) : ''}${p.is_fake ? t(' · FAKE') : ''}`;
        list.push({
          id: p.id, lat: p.lat!, lng: p.lng!, color: colorFor(s, pid), label, kind: 'ping', accuracy: p.accuracy_m,
          opacity: isLast ? 1 : Math.max(0.45, 1 - age / Math.max(fade, 1)), text: `${tag}${nr}`,
          ring: isLast ? RING_LAST : blitz ? RING_BLITZ : undefined,
        });
      });
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
    for (const e of s.emergencies) {
      if (e.lat != null && e.lng != null) list.push({ id: `e${e.id}`, lat: e.lat, lng: e.lng, color: '#ff0000', kind: 'emergency', label: t('NOTFALL {0}', { 0: nameOf(s, e.participant_id) }), pulse: true });
    }
    return list;
  }, [s, now, pos, role, tracker.last?.acc, pingCount, othersHidden]);

  if (!s) {
    return (
      <div className="app">
        {error ? <div className="notice error">{error}</div> : <Loader inline text={t('Lade Spiel …')} />}
        <Link to={`/spiel/${id}`}>{t('Zurück')}</Link>
      </div>
    );
  }

  const g = s.game;
  const ended = ['beendet', 'archiviert'].includes(g.status);
  const players = s.participants.filter((p) => p.role === 'spieler');
  const live = ['vorsprung', 'laeuft', 'finale'].includes(g.status);
  const exitOpenAt = g.ends_at ? new Date(g.ends_at).getTime() - g.config.exit.usable_minutes_before_end * 60000 : null;
  const headline = g.paused ? (g.pause_kind === 'host' ? t('PAUSE') : g.pause_kind === 'sicherheit' ? t('WARTEN AUF ALLE') : t('UNTERBROCHEN: NOTFALL'))
    : g.status === 'vorsprung' ? t('Jagd in {0}', { 0: countdown(g.hunt_start_at, now) })
    : g.status === 'finale' && exitOpenAt && now < exitOpenAt ? t('Fluchtpunkt öffnet um {0} · Ende in {1}', { 0: clock(new Date(exitOpenAt).toISOString(), g.timezone), 1: countdown(g.ends_at, now) })
    : g.status === 'finale' ? t('Fluchtpunkt noch {0} offen', { 0: countdown(g.ends_at, now) })
    : ended ? t('Spiel beendet') : t('Ende in {0}', { 0: countdown(g.ends_at, now) });

  const roleLabel = role === 'spieler' ? t('Spieler') : role === 'zuschauer' ? t('Zuschauer') : t('Hunter');
  const canSos = !ended && role !== 'zuschauer' && s.me.state !== 'notfall';
  const unseen = tab === 'meldungen' ? 0 : s.notifications.length - seenNotes;
  const chats = s.notifications.filter((n) => n.kind === 'chat').length;
  const unseenChat = tab === 'chat' || seenChats === null ? 0 : chats - seenChats;
  function openTab(next: Tab) {
    setTab(next);
    if (next === 'meldungen' && s) setSeenNotes(s.notifications.length);
    if (next === 'chat' && s) setSeenChats(s.notifications.filter((n) => n.kind === 'chat').length);
  }

  return (
    <div className="app wide play">
      <div className="topbar">
        <Link to="/" className="button ghost back" aria-label={t('Zur Startseite')}><Icon name="back" /></Link>
        <div className="spacer play-head">
          <div className="sub-line">
            <span className={`role-pill ${role === 'spieler' ? 'spieler' : role === 'zuschauer' ? 'zuschauer' : 'hunter'}`} style={{ padding: '1px 8px', marginRight: 6 }}>{roleLabel}</span>
            {g.name}{g.is_test ? t(' · Probelauf') : ''}{(g.phase_count ?? 0) > 1 && g.config.zone.shrink_every_minutes > 0 && t(' · Spielfeld-Stufe {0}/{1}', { 0: g.phase, 1: g.phase_count })}
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

      {g.paused && g.pause_kind === 'host' && (
        <div className="notice pulse" role="alert" style={{ marginBottom: 8 }}>
          <strong>{t('Spiel pausiert.')}</strong> {g.pause_reason && g.pause_reason !== 'Pause' ? `${g.pause_reason}. ` : ''}{t('Die Zeit steht still. Sobald der Host fortsetzt, geht es genau dort weiter.')}
        </div>
      )}
      {g.paused && (g.pause_kind === 'notfall' || !g.pause_kind) && (
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
      {!ended && !isNative && notifPerm === 'default' && typeof Notification !== 'undefined' && (
        <button className="small block" style={{ marginBottom: 8 }} onClick={() => void Notification.requestPermission().then(setNotifPerm)}>{t('Benachrichtigungen erlauben')}</button>
      )}
      {msg && <div className={`notice ${msg.ok ? 'success' : 'error'}`} style={{ marginBottom: 8 }} onClick={() => setMsg(null)}>{msg.text}</div>}

      {!ended && <SafetyNotice s={s} act={act} />}
      {!ended && <DeviceAlert tracker={tracker} tracking={tracking} />}
      {ended ? <Result s={s} zones={zones} /> : (
        <>
          <EmergencyBox s={s} act={act} showMap={() => setTab('karte')} />
          <nav className="tabbar">
            {TABS.map(([id, label, icon]) => (
              <button key={id} className={tab === id ? 'active' : ''} onClick={() => openTab(id)}>
                <Icon name={icon} />{label}
                {id === 'meldungen' && unseen > 0 && <span className="pip" aria-label={t('{0} neu', { 0: unseen })} />}
                {id === 'chat' && unseenChat > 0 && <span className="pip" aria-label={t('{0} neu', { 0: unseenChat })} />}
              </button>
            ))}
          </nav>
          <div style={{ display: tab === 'karte' ? 'block' : 'none' }}>
            <div className="map-box">
              <MapView zones={zones} markers={markers} fitKey={g.id} height="62dvh" showDay={g.phase ?? g.current_day}>
                {(() => {
                  // Timer bis zum nächsten Ping (Hunter: nächster Ping irgendeines Spielers, Spieler: der eigene).
                  const next = role === 'spieler' ? s.me.next_ping_at : s.next_silent_ping_at;
                  if (!next || g.paused || g.status === 'vorsprung') return null;
                  return <span className="map-chip timer" aria-live="off">⏱ {t('Nächster Ping in {0}', { 0: countdown(next, now) })}</span>;
                })()}
                {role === 'hunter' && <SpeedhuntButtons s={s} act={act} onOpen={() => setBlitzOpen(true)} />}
                {s.pings.some((p) => p.lat != null) && (
                  <span className="map-chip">
                    📍
                    <select aria-label={t('Pings auf der Karte')} value={pingCustom ? 'x' : String(pingCount)}
                      onChange={(e) => {
                        if (e.target.value === 'x') { setPingCustom(true); setPingCount(pingCount > 1 && pingCount !== 3 ? pingCount : 5); return; }
                        setPingCustom(false);
                        setPingCount(Number(e.target.value));
                      }}>
                      <option value="1">{t('Nur letzter Ping')}</option>
                      <option value="3">{t('Letzte 3 Pings')}</option>
                      <option value="0">{t('Alle Pings')}</option>
                      <option value="x">{t('Eigene Anzahl …')}</option>
                    </select>
                    {pingCustom && <NumberField label={t('Pings je Spieler')} value={pingCount || 5} min={1} max={200} onChange={setPingCount} />}
                  </span>
                )}
                {role === 'spieler' && s.pings.some((p) => p.participant_id !== s.me.id && p.lat != null) && (
                  <button type="button" className="map-chip" aria-pressed={!othersHidden} onClick={() => setOthersHidden(!othersHidden)}>
                    👥 {othersHidden ? t('Andere Spieler: aus') : t('Andere Spieler: an')}
                  </button>
                )}
                {role === 'spieler' && s.me.radar && (
                  <span className={`map-chip${s.me.radar.near ? ' red pulse' : ''}`} role="status">
                    📡 {s.me.radar.near ? t('Hunter näher als {0} m!', { 0: s.me.radar.distance_m }) : s.me.radar.near === false ? t('Kein Hunter näher als {0} m', { 0: s.me.radar.distance_m }) : t('Nähe-Radar')}
                  </span>
                )}
              </MapView>
            </div>
            {blitzOpen && <SpeedhuntDialog s={s} act={act} onClose={() => setBlitzOpen(false)} />}
            <div className="row small" style={{ marginTop: 8 }}>
              {role === 'spieler' && s.me.next_ping_at && <span className="badge">{t('Nächster Ping')} {clock(s.me.next_ping_at)}</span>}
              {s.next_silent_ping_at && role !== 'spieler' && <span className="badge">{t('Nächster Ping')} {clock(s.next_silent_ping_at)}</span>}
              <span className="badge">{s.free_players}/{players.length} {t('Spieler frei')}</span>
              {s.speedhunts.some((x) => x.status === 'laeuft') && <span className="badge red pulse">{t('Blitzjagd')}</span>}
              {tracker.last && <span className="badge">{t('GPS ±')}{tracker.last.acc} m</span>}
              {tracking && <span className={`badge${tracker.sentAt && Date.now() - tracker.sentAt < 60000 ? '' : ' red'}`}>📡 {tracker.sentAt ? t('gesendet vor {0} s', { 0: Math.max(0, Math.round((Date.now() - tracker.sentAt) / 1000)) }) : t('noch nicht gesendet')}</span>}
              {s.pings.some((p) => p.lat != null) && <span className="badge"><i className="ring-dot" style={{ borderColor: RING_LAST }} /> {t('letzter Ping')}</span>}
              {s.pings.some((p) => p.source === 'speedhunt' && p.lat != null) && <span className="badge"><i className="ring-dot" style={{ borderColor: RING_BLITZ }} /> {t('Blitzjagd')}</span>}
            </div>
          </div>

          <div style={{ display: tab === 'aktionen' ? 'block' : 'none' }}>
            {role === 'spieler' && <PlayerPanel s={s} now={now} act={act} pos={pos} />}
            {role !== 'zuschauer' && <AlarmSettingsBox hunter={role === 'hunter'} />}
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
                {live && !g.paused && (
                  <div className="stack">
                    <input aria-label={t('Grund (freiwillig)')} placeholder={t('Grund (freiwillig)')} value={pauseReason} maxLength={80} onChange={(e) => setPauseReason(e.target.value)} />
                    <Confirm className="block" label={t('⏸ Spiel pausieren')} confirm={t('Spiel für alle anhalten? Die Zeit steht still, bis du fortsetzt.')}
                      onYes={() => act(() => api.pause(g.id, pauseReason), t('Spiel pausiert.')).then((ok) => { if (ok) setPauseReason(''); })} />
                  </div>
                )}
                {live && g.paused && g.pause_kind === 'host' && (
                  <div className="stack">
                    <button className="primary block big" onClick={() => act(() => api.resume(g.id), t('Das Spiel läuft wieder.'))}>{t('▶ Spiel fortsetzen')}</button>
                    <Link to={`/spiel/${g.id}/regeln`} className="button block">{t('Einstellungen ändern (nur wenn nötig)')}</Link>
                  </div>
                )}
                <Confirm className="ghost" disabled={!live} label={t('Spiel abbrechen')} confirm={t('Spiel jetzt für alle abbrechen? Dann hat keiner gewonnen.')} onYes={() => act(() => api.endGame(g.id))} />
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
