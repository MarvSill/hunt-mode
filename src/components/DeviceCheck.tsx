import { useState } from 'react';
import { api } from '../lib/engine';
import { errorText } from '../lib/supabase';
import { t } from '../i18n';

interface Result { gps: boolean; accuracy: number | null; battery: number | null; notifications: string; wakeLock: boolean; camera: boolean; clock_ms: number | null }

// Gerätecheck vor dem Start (6.2): GPS-Fix, Akku, Benachrichtigungen, Bildschirm-wach, Kamera.
export default function DeviceCheck({ gameId, minBattery }: { gameId: string; minBattery: number }) {
  const [res, setRes] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    setBusy(true);
    setErr(null);
    const r: Result = { gps: false, accuracy: null, battery: null, notifications: t('nicht unterstützt'), wakeLock: false, camera: false, clock_ms: null };
    try {
      const p = await new Promise<GeolocationPosition>((ok, fail) =>
        navigator.geolocation.getCurrentPosition(ok, fail, { enableHighAccuracy: true, timeout: 20000 }));
      r.gps = true;
      r.accuracy = Math.round(p.coords.accuracy);
      // Erster Standort gleich an den Server (Lobby-Position)
      await api.report(gameId, [{ lat: p.coords.latitude, lng: p.coords.longitude, acc: r.accuracy, age_s: 0 }]).catch(() => undefined);
    } catch {
      r.gps = false;
    }
    try {
      const b = await (navigator as Navigator & { getBattery?: () => Promise<{ level: number }> }).getBattery?.();
      if (b) r.battery = Math.round(b.level * 100);
    } catch {
      // kein Akku-Wert
    }
    if (typeof Notification !== 'undefined') {
      r.notifications = Notification.permission === 'default' ? await Notification.requestPermission() : Notification.permission;
    }
    r.wakeLock = 'wakeLock' in navigator;
    r.camera = !!navigator.mediaDevices?.getUserMedia;
    try {
      const t0 = Date.now();
      const s = await api.state(gameId);
      r.clock_ms = Math.round(new Date(s.server_now).getTime() - (t0 + Date.now()) / 2);
    } catch {
      // ohne Uhrvergleich
    }
    setRes(r);
    try {
      await api.deviceCheck(gameId, { ...r, ok: r.gps && (r.battery == null || r.battery >= minBattery) });
    } catch (e) {
      setErr(errorText(e));
    }
    setBusy(false);
  }

  const ok = (b: boolean) => (b ? '✓' : '✗');
  const allOk = !!res && res.gps && (res.battery == null || res.battery >= minBattery) && res.notifications === 'granted'
    && (res.clock_ms == null || Math.abs(res.clock_ms) < 30000);
  return (
    <div className="card stack">
      <div className="row" style={{ flexWrap: 'nowrap' }}>
        <span style={{ fontSize: 24 }} aria-hidden="true">{allOk ? '✅' : '📱'}</span>
        <div className="spacer">
          <strong>{t('Handy-Check')}</strong>
          <div className="muted small">{allOk ? t('Alles bereit: Standort, Akku und Benachrichtigungen.') : res ? t('Bitte die rot markierten Punkte beheben.') : t('Prüft Standort, Akku und Benachrichtigungen.')}</div>
        </div>
        <button className={res ? 'small' : 'small primary'} onClick={run} disabled={busy}>{busy ? t('Prüfe …') : res ? t('Nochmals prüfen') : t('Gerät prüfen')}</button>
      </div>
      {res && !allOk && (
        <ul className="list small">
          <li>{ok(res.gps)} {t('Standort')} {res.gps ? `(±${res.accuracy} m)` : t('nicht erlaubt: bitte im Browser freigeben')}</li>
          <li>{ok(res.battery == null || res.battery >= minBattery)} {t('Akku')} {res.battery != null ? `${res.battery} %` : 'unbekannt'}{res.battery != null && res.battery < minBattery && t(' (mind. {0} % nötig)', { 0: minBattery })}</li>
          <li>{ok(res.notifications === 'granted')} {t('Benachrichtigungen:')} {res.notifications === 'granted' ? 'erlaubt' : res.notifications === 'denied' ? 'blockiert' : res.notifications}</li>
          <li>{ok(res.wakeLock)} {t('Bildschirm bleibt an')}</li>
          <li>{ok(res.camera)} {t('Kamera für QR-Fang')}</li>
          {res.clock_ms != null && <li>{ok(Math.abs(res.clock_ms) < 30000)} {t('Uhr')} {Math.abs(res.clock_ms) < 30000 ? 'stimmt' : t('weicht {0} s ab', { 0: Math.round(res.clock_ms / 1000) })}</li>}
        </ul>
      )}
      {err && <div className="notice error">{err}</div>}
      <div className="muted tiny">{t('Während des Spiels die App offen lassen: der Standort wird nur gesendet, solange die App sichtbar ist.')}</div>
    </div>
  );
}
