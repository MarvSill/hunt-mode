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
import PlayerPanel, { JokerBox, PlayerAlerts, PlayerMore } from './PlayerPanel';
import CatchCode from './CatchCode';
import Result from './Result';
import { t, lazy } from '../i18n';
import { isNative, nativeNotify, openAppSettings } from '../lib/native';
import NumberField from '../components/NumberField';
import { SpeedhuntButtons, SpeedhuntDialog } from './SpeedhuntMap';
import Loader from '../components/Loader';
import Swipe from '../components/Swipe';
import SafetyNotice from './SafetyNotice';
import HunterDraw from './HunterDraw';
import Guide, { type GuideStep } from '../components/Guide';
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

// Leiste unten: Karte · Aktionen · Chat · Mehr (Meldungen, Alarm, Status, Regeln, Spiel steuern).
type Tab = 'karte' | 'aktionen' | 'chat' | 'mehr';
const TABS: [Tab, string, IconName][] = lazy([['karte', 'Karte', 'map'], ['aktionen', 'Aktionen', 'bolt'], ['chat', 'Chat', 'chat'], ['mehr', 'Mehr', 'more']]);

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

/** Hinweise beim ersten Spiel als Spieler. */
const TIPS_PLAYER: GuideStep[] = lazy([
  { target: 'me', title: 'Das bist du', text: 'Dein Buchstabe. So heissen deine Pings auf der Karte (A1, A2 …).' },
  { target: 'ping', title: 'Nächster Ping', text: 'Dann sehen die Hunter, wo du gerade bist. Nur diesen Moment, nicht live. Dein Handy klingelt.' },
  { target: 'map', title: 'Karte', text: 'Mit ⛶ oben rechts wird sie gross. Dort hast du auch Joker und Fang-Code.' },
  { target: 'tabs', title: 'Unten', text: 'Aktionen: Joker und Fang-Code. Chat: mit den Huntern. Mehr: Meldungen, Alarm, Regeln.' },
  { target: 'sos', title: 'SOS', text: 'Nur im echten Notfall. Das Spiel stoppt und alle kommen helfen.' },
]);

/** Hinweise beim ersten Spiel als Hunter. */
const TIPS_HUNTER: GuideStep[] = lazy([
  { target: 'me', title: 'Das bist du', text: 'Dein Zeichen im Hunter-Team.' },
  { target: 'map', title: 'Pings', text: 'Die farbigen Punkte sind die Pings der Spieler (A1, A2 …). Gelb umrandet = der neueste. Mit ⛶ wird die Karte gross.' },
  { target: 'ping', title: 'Nächster Ping', text: 'Dann kommt der nächste Standort der Spieler.' },
  { target: 'tabs', title: 'Unten', text: 'Aktionen: fangen (Code eingeben oder Fang melden). Chat: mit jedem Spieler und dem Hunter-Team. Mehr: Meldungen, Alarm, Regeln.' },
  { target: 'sos', title: 'SOS', text: 'Nur im echten Notfall. Das Spiel stoppt und alle kommen helfen.' },
]);

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
  // Weggewischte Meldungen (nur auf diesem Gerät, je Spiel).
  const [hiddenNotes, setHiddenNotesState] = useState<Set<number>>(() => {
    try { return new Set(JSON.parse(localStorage.getItem(`hm-notes-hidden-${id}`) ?? '[]') as number[]); } catch { return new Set(); }
  });
  const setHiddenNotes = (v: Set<number>) => {
    setHiddenNotesState(v);
    try { localStorage.setItem(`hm-notes-hidden-${id}`, JSON.stringify([...v].slice(-500))); } catch { /* nur für diese Sitzung */ }
  };
  const hideNote = (n: number) => setHiddenNotes(new Set([...hiddenNotes, n]));
  const [seenChats, setSeenChats] = useState<number | null>(null);

  const roleRef = useRef<string | undefined>(undefined);
  const lastAlarm = useRef(0);
  useEffect(() => {
    // Browser spielen Töne erst nach einer Berührung der Seite ab. Bei jeder Berührung und beim Zurückkommen in die
    // App wieder einschalten (iOS stellt den Ton nach dem Hintergrund oft stumm).
    const onVisible = () => { if (document.visibilityState === 'visible') unlockAudio(); };
    document.addEventListener('pointerdown', unlockAudio);
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      document.removeEventListener('pointerdown', unlockAudio);
      document.removeEventListener('visibilitychange', onVisible);
    };
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
  const [fullMap, setFullMap] = useState(false);
  const [sheet, setSheet] = useState<null | 'joker' | 'code' | 'fangen'>(null);
  // Erstes Spiel in dieser Rolle: kurze Hinweise direkt auf der Karte (danach nie wieder).
  const [tipsDone, setTipsDone] = useState<Record<string, boolean>>({});
  const tipKey = `hm-tips-${s?.me.role ?? ''}`;
  const tips = !!s && (s.me.role === 'spieler' || s.me.role === 'hunter') && tab === 'karte' && !fullMap
    // Erst nach dem Sicherheitshinweis und wenn das Spiel wirklich läuft (nicht während "Warten auf alle").
    && ['vorsprung', 'laeuft', 'finale'].includes(s.game.status) && s.me.safety_ok && !s.game.paused && !tipsDone[tipKey] && (() => { try { return !localStorage.getItem(tipKey); } catch { return false; } })();
  const closeTips = () => { setTipsDone((d) => ({ ...d, [tipKey]: true })); try { localStorage.setItem(tipKey, '1'); } catch { /* egal */ } };
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
  useRadarAlarm(role === 'spieler' ? s?.me.radar : undefined, reload);

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
        label: `${isMe ? t('Du') : pp?.tag ?? pp?.name ?? '?'}${x.live && !isMe ? t(' (LIVE)') : ''} · ${clock(x.at)}`, pulse: x.live && tf && !isMe, text: pp?.tag ?? undefined,
      });
    }
    // Eigene Live-Position (schneller als der Server-Stand)
    if (pos && !s.positions.some((x) => x.participant_id === s.me.id)) {
      list.push({ id: 'me', lat: pos.lat, lng: pos.lng, color: '#58a6ff', kind: 'me', label: t('Du'), accuracy: tracker.last?.acc, text: s.participants.find((q) => q.id === s.me.id)?.tag ?? undefined });
    }
    for (const e of s.me.effects) {
      if (e.type === 'hunter_snapshot') {
        for (const h of (e.payload.hunters as { name: string; tag?: string; lat: number; lng: number; at?: string }[]) ?? []) {
          list.push({ id: `hs${e.id}${h.name}`, lat: h.lat, lng: h.lng, color: '#f85149', kind: 'hunter', label: t('Hunter {0} · Ping {1} (nicht live)', { 0: h.tag ?? h.name, 1: clock(h.at) }), text: h.tag });
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
  // Fluchtpunkt öffnet mit dem Ende der Spielzeit; danach läuft das Spiel bis alle da sind, höchstens bis deadline_at.
  const exitOpenAt = g.ends_at ? new Date(g.ends_at).getTime() : null;
  const finalEnd = g.deadline_at ?? g.ends_at;
  const headline = g.paused ? (g.pause_kind === 'host' ? t('PAUSE') : g.pause_kind === 'sicherheit' ? t('WARTEN AUF ALLE') : t('UNTERBROCHEN: NOTFALL'))
    : g.status === 'vorsprung' ? t('Jagd in {0}', { 0: countdown(g.hunt_start_at, now) })
    : g.status === 'finale' && exitOpenAt && now < exitOpenAt ? t('Fluchtpunkt öffnet in {0}', { 0: countdown(g.ends_at, now) })
    : g.config.exit.enabled && exitOpenAt && now >= exitOpenAt ? t('Fluchtpunkt offen · Schluss in {0}', { 0: countdown(finalEnd, now) })
    : ended ? t('Spiel beendet') : t('Ende in {0}', { 0: countdown(g.ends_at, now) });

  const myTag = s.participants.find((p) => p.id === s.me.id)?.tag;
  const roleLabel = role === 'spieler' ? t('Spieler') : role === 'zuschauer' ? t('Zuschauer') : t('Hunter');
  const canSos = !ended && role !== 'zuschauer' && s.me.state !== 'notfall';
  const unseen = tab === 'mehr' ? 0 : s.notifications.length - seenNotes;
  const chats = s.notifications.filter((n) => n.kind === 'chat').length;
  const unseenChat = tab === 'chat' || seenChats === null ? 0 : chats - seenChats;
  function openTab(next: Tab) {
    setTab(next);
    if (next === 'mehr' && s) setSeenNotes(s.notifications.length);
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
        {canSos && <button className="sos" data-guide="sos" aria-label={t('NOTFALL')} onClick={() => setSosAsk(true)}>{t('SOS')}</button>}
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
          <Swipe key={n.id} className={`toast ${n.priority}`} role="status" onDismiss={() => setToasts((t) => t.filter((x) => x.id !== n.id))}>
            <div onClick={() => setToasts((t) => t.filter((x) => x.id !== n.id))}>
              {toasts.length > 1 && <span className="more">+{toasts.length - 1}</span>}
              <strong>{n.title}</strong>{n.body && <div className="small">{n.body}</div>}
            </div>
          </Swipe>
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
          <nav className="tabbar" data-guide="tabs">
            {TABS.map(([id, label, icon]) => (
              <button key={id} className={tab === id ? 'active' : ''} onClick={() => openTab(id)}>
                <Icon name={icon} />{label}
                {id === 'mehr' && unseen > 0 && <span className="pip" aria-label={t('{0} neu', { 0: unseen })} />}
                {id === 'chat' && unseenChat > 0 && <span className="pip" aria-label={t('{0} neu', { 0: unseenChat })} />}
              </button>
            ))}
          </nav>
          <div style={{ display: tab === 'karte' ? 'block' : 'none' }}>
            {(() => {
              // Was rund um die Karte gehört: kleine Karte = über und unter der Karte, grosse Karte = auf der Karte.
              const next = role === 'spieler' ? s.me.next_ping_at : s.next_silent_ping_at;
              const showPing = !!next && !g.paused && g.status !== 'vorsprung' && !(role === 'spieler' && !['aktiv', 'ausserhalb'].includes(s.me.state));
              const blitzRunning = s.speedhunts.some((x) => x.status === 'laeuft');
              const info = (
                <>
                  {myTag && <span data-guide="me" className={`map-chip me ${role === 'spieler' ? 'spieler' : 'hunter'}`}>{t('Du: {0}', { 0: myTag })}</span>}
                  {fullMap && <span className={`map-chip timer${g.paused ? ' red' : ''}`}>{headline}</span>}
                  {showPing && <span data-guide="ping" className="map-chip timer" aria-live="off">⏱ {t('Ping in {0}', { 0: countdown(next, now) })}</span>}
                  {role === 'spieler' && s.me.radar && (
                    <span className={`map-chip${s.me.radar.near ? ' red pulse' : ' green'}`} role="status">
                      📡 {s.me.radar.near ? t('Hunter näher als {0} m!', { 0: s.me.radar.distance_m }) : s.me.radar.near === false ? t('Kein Hunter näher als {0} m', { 0: s.me.radar.distance_m }) : t('Nähe-Radar')}
                    </span>
                  )}
                  {blitzRunning && <span className="map-chip red pulse">⚡ {t('Blitzjagd läuft')}</span>}
                  {role === 'spieler' && s.me.state === 'ausserhalb' && <span className="map-chip red pulse">{t('Zurück ins Spielfeld!')}</span>}
                </>
              );
              const pingPick = s.pings.some((p) => p.lat != null) && (
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
              );
              const othersBtn = role === 'spieler' && s.pings.some((p) => p.participant_id !== s.me.id && p.lat != null) && (
                <button type="button" className="map-chip" aria-pressed={!othersHidden} onClick={() => setOthersHidden(!othersHidden)}>
                  👥 {othersHidden ? t('Andere Spieler: aus') : t('Andere Spieler: an')}
                </button>
              );
              const playerActive = role === 'spieler' && ['aktiv', 'ausserhalb'].includes(s.me.state);
              const actions = (
                <>
                  {role === 'hunter' && <SpeedhuntButtons s={s} act={act} onOpen={() => setBlitzOpen(true)} />}
                  {role === 'hunter' && fullMap && <button type="button" className="map-chip big" onClick={() => setSheet('fangen')}>🤚 {t('Fangen')}</button>}
                  {playerActive && fullMap && g.config.joker.enabled && <button type="button" className="map-chip big" onClick={() => setSheet('joker')}>🃏 {t('Joker')}{s.me.inventory.length > 0 ? ` (${s.me.inventory.length})` : ''}</button>}
                  {playerActive && fullMap && <button type="button" className="map-chip big" onClick={() => setSheet('code')}>🔢 {t('Fang-Code')}</button>}
                </>
              );
              return (
                <>
                  {!fullMap && <div className="map-info">{info}</div>}
                  {!fullMap && <PlayerAlerts s={s} now={now} act={act} />}
                  <div className="map-box" data-guide="map">
                    <MapView zones={zones} markers={markers} fitKey={g.id} height="58dvh" showDay={g.phase ?? g.current_day} onFullscreen={setFullMap}
                      overlay={role === 'hunter' && !ended ? (m, v) => <HunterDraw map={m} styleVer={v} gameId={g.id} /> : undefined}
                      fullTop={fullMap ? (
                        <div className="stack" style={{ gap: 6 }}>
                          <div className="map-info">{info}{canSos && <button type="button" className="sos small" onClick={() => setSosAsk(true)}>{t('SOS')}</button>}</div>
                          <PlayerAlerts s={s} now={now} act={act} compact />
                        </div>
                      ) : undefined}>
                      {fullMap ? <>{actions}{pingPick}{othersBtn}</> : null}
                    </MapView>
                  </div>
                  {!fullMap && (
                    <div className="map-under">
                      {actions}
                      {pingPick}
                      {othersBtn}
                      <span className="badge">{s.free_players}/{players.length} {t('Spieler frei')}</span>
                      {tracker.last && <span className="badge">{t('GPS ±')}{tracker.last.acc} m</span>}
                      {s.pings.some((p) => p.lat != null) && <span className="badge"><i className="ring-dot" style={{ borderColor: RING_LAST }} /> {t('letzter Ping')}</span>}
                      {s.pings.some((p) => p.source === 'speedhunt' && p.lat != null) && <span className="badge"><i className="ring-dot" style={{ borderColor: RING_BLITZ }} /> {t('Blitzjagd')}</span>}
                    </div>
                  )}
                </>
              );
            })()}
            {tips && <Guide steps={role === 'spieler' ? TIPS_PLAYER : TIPS_HUNTER} onClose={closeTips} />}
            {blitzOpen && <SpeedhuntDialog s={s} act={act} onClose={() => setBlitzOpen(false)} />}
            {sheet && (
              <div className="overlay sheet" role="dialog" onClick={() => setSheet(null)}>
                <div className="card stack sheet-card" onClick={(e) => e.stopPropagation()}>
                  {sheet === 'joker' && <JokerBox s={s} now={now} act={act} running={['laeuft', 'finale'].includes(g.status) && !g.paused} />}
                  {sheet === 'joker' && s.me.inventory.length === 0 && <div className="muted">{t('Noch keine Joker frei.')}</div>}
                  {sheet === 'fangen' && <HunterPanel s={s} now={now} act={act} pos={pos} />}
                  <button type="button" className="ghost block" onClick={() => setSheet(null)}>{t('Schliessen')}</button>
                </div>
              </div>
            )}
            {sheet === 'code' && <CatchCode gameId={g.id} onClose={() => setSheet(null)} />}
          </div>

          <div style={{ display: tab === 'aktionen' ? 'block' : 'none' }}>
            {role === 'spieler' && <PlayerPanel s={s} now={now} act={act} pos={pos} />}
            {role === 'hunter' && <HunterPanel s={s} now={now} act={act} pos={pos} />}
            {role === 'zuschauer' && <div className="card muted">{t('Du schaust zu. Positionen siehst du mit')} {g.config.spectator.delay_minutes} {t('min Verzögerung.')}</div>}
          </div>

          <div style={{ display: tab === 'mehr' ? 'block' : 'none' }}>
            <h2 className="section-h">🔔 {t('Meldungen')}</h2>
            <div className="card">
              {s.notifications.some((n) => !hiddenNotes.has(n.id)) && <div className="muted small" style={{ marginBottom: 6 }}>{t('Zur Seite wischen zum Entfernen.')}</div>}
              <ul className="list">
                {s.notifications.filter((n) => !hiddenNotes.has(n.id)).map((n) => (
                  <li key={n.id} style={{ display: 'block', padding: 0 }}>
                    <Swipe className={`note ${n.priority} swipe-row`} onDismiss={() => hideNote(n.id)}>
                      <div className="spacer">
                        <div><strong>{n.title}</strong></div>
                        {n.body && <div className="small">{n.body}</div>}
                      </div>
                      <span className="muted small">{clock(n.at, g.timezone)}</span>
                    </Swipe>
                  </li>
                ))}
                {s.notifications.every((n) => hiddenNotes.has(n.id)) && <li className="muted">{t('Noch keine Meldungen.')}</li>}
              </ul>
              {hiddenNotes.size > 0 && <button type="button" className="ghost small" onClick={() => setHiddenNotes(new Set())}>{t('Entfernte wieder zeigen')}</button>}
            </div>
            {role === 'spieler' && <PlayerMore s={s} act={act} />}
            {role !== 'zuschauer' && <AlarmSettingsBox hunter={role === 'hunter'} />}
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
                    <Link to={`/spiel/${g.id}/regeln`} className="button block">{t('⚙️ Regeln ändern')}</Link>
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

          {tab === 'chat' && <Chat s={s} />}

        </>
      )}
    </div>
  );
}
