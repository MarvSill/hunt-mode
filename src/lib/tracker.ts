import { useEffect, useRef, useState } from 'react';
import { api } from './engine';
import { t } from '../i18n';
import { isNative, watchNative } from './native';

// Standort-Erfassung (23.4): watchPosition, Puffer bei Funkloch, Senden im
// Server-Takt (schneller bei Live-Fenster oder Standort-Anfrage), Wake Lock.

interface Sample { lat: number; lng: number; acc: number; speed: number | null; heading: number | null; t: number; battery: number | null }

export interface TrackerInfo {
  status: 'aus' | 'warte' | 'ok' | 'fehler' | 'verweigert';
  last: Sample | null;
  queued: number;
  error: string | null;
  wakeLock: boolean;
  /** Zeitpunkt, an dem der Server den letzten Standort angenommen hat. */
  sentAt: number | null;
  /** Fehler beim letzten Senden (null = ok). */
  sendError: string | null;
}

interface BatteryManager { level: number; charging: boolean; addEventListener(t: string, f: () => void): void }

export function useTracker(gameId: string | undefined, enabled: boolean, kick = 0) {
  const [info, setInfo] = useState<TrackerInfo>({ status: 'aus', last: null, queued: 0, error: null, wakeLock: false, sentAt: null, sendError: null });
  const queue = useRef<Sample[]>([]);
  const lastSent = useRef(0);
  const interval = useRef(15);
  const battery = useRef<number | null>(null);
  const sending = useRef(false);
  const latest = useRef<Sample | null>(null);
  const flushRef = useRef<((force?: boolean) => Promise<void>) | null>(null);

  // Standort-Anfrage vom Server (Ping, Blitzjagd-Abfrage): sofort senden.
  useEffect(() => {
    if (kick > 0) {
      interval.current = 5;
      void flushRef.current?.(true);
    }
  }, [kick]);

  useEffect(() => {
    const nav = navigator as Navigator & { getBattery?: () => Promise<BatteryManager> };
    nav.getBattery?.().then((b) => {
      battery.current = Math.round(b.level * 100);
      b.addEventListener('levelchange', () => (battery.current = Math.round(b.level * 100)));
    }).catch(() => undefined);
  }, []);

  useEffect(() => {
    if (!enabled || !gameId) {
      setInfo((i) => ({ ...i, status: 'aus' }));
      return;
    }
    if (!isNative && !('geolocation' in navigator)) {
      setInfo((i) => ({ ...i, status: 'fehler', error: t('Dieses Gerät hat kein GPS im Browser.') }));
      return;
    }
    let stopped = false;
    let lock: { release: () => Promise<void> } | null = null;
    const wake = async () => {
      try {
        const wl = (navigator as Navigator & { wakeLock?: { request: (t: string) => Promise<{ release: () => Promise<void> }> } }).wakeLock;
        if (wl && document.visibilityState === 'visible') {
          lock = await wl.request('screen');
          setInfo((i) => ({ ...i, wakeLock: true }));
        }
      } catch {
        setInfo((i) => ({ ...i, wakeLock: false }));
      }
    };
    void wake();
    const onVis = () => {
      if (document.visibilityState === 'visible') {
        void wake();
        void flush(true);
      }
    };
    document.addEventListener('visibilitychange', onVis);

    async function flush(force = false) {
      if (sending.current || stopped) return;
      const due = Date.now() - lastSent.current >= interval.current * 1000 - 500;
      if (!force && !due) return;
      // Kein neuer GPS-Punkt (Gerät steht still): letzten Punkt als aktuell senden.
      if (queue.current.length === 0 && latest.current) queue.current.push({ ...latest.current, t: Date.now() });
      if (queue.current.length === 0) return;
      sending.current = true;
      const batch = queue.current.slice(-20);
      const now = Date.now();
      try {
        const res = await api.report(gameId!, batch.map((s) => ({
          lat: s.lat, lng: s.lng, acc: s.acc, speed: s.speed, heading: s.heading, battery: s.battery,
          age_s: Math.max(0, Math.round((now - s.t) / 1000)),
        })));
        queue.current = [];
        lastSent.current = Date.now();
        if (res?.interval_s) interval.current = res.interval_s;
        if (res?.request_now) interval.current = 5;
        setInfo((i) => ({ ...i, queued: 0, error: null, sentAt: Date.now(), sendError: null }));
      } catch (err) {
        // Offline: Punkte behalten und später senden (max. 200).
        queue.current = queue.current.slice(-200);
        const m = (err as Error)?.message || t('Senden fehlgeschlagen');
        console.warn('[hm-track] Senden fehlgeschlagen', m);
        setInfo((i) => ({ ...i, queued: queue.current.length, sendError: m }));
      } finally {
        sending.current = false;
      }
    }

    flushRef.current = flush;
    setInfo((i) => ({ ...i, status: 'warte' }));
    const onSample = (s: Sample) => {
      latest.current = s;
      // Pro 5 s höchstens ein Punkt im Puffer.
      const lastQ = queue.current[queue.current.length - 1];
      if (!lastQ || s.t - lastQ.t >= 5000) queue.current.push(s);
      setInfo((i) => ({ ...i, status: 'ok', last: s, queued: queue.current.length }));
      void flush();
    };
    let stopWatch: () => void = () => undefined;
    let webId: number | null = null;
    const startWeb = () => {
      if (webId != null || stopped || !('geolocation' in navigator)) return;
      webId = navigator.geolocation.watchPosition(
        (p) => onSample({
          lat: p.coords.latitude, lng: p.coords.longitude, acc: Math.round(p.coords.accuracy),
          speed: p.coords.speed, heading: p.coords.heading, t: p.timestamp || Date.now(), battery: battery.current,
        }),
        (err) => {
          console.warn('[hm-track] GPS-Fehler', err.code, err.message);
          setInfo((i) => (i.last ? i : { ...i, status: err.code === err.PERMISSION_DENIED ? 'verweigert' : 'fehler', error: err.message }));
        },
        { enableHighAccuracy: true, maximumAge: 5000, timeout: 30000 },
      );
    };
    if (isNative) {
      // Echte App: Standort auch im Hintergrund und bei gesperrtem Bildschirm.
      // Bei einem Fehler (z. B. Erlaubnis erst später erteilt) neu versuchen; kommt nach 20 s
      // kein Standort, zusätzlich den Standort der Web-Ansicht nutzen.
      let nativeStop: (() => void) | null = null;
      let gotNative = false;
      let retry: ReturnType<typeof setTimeout> | undefined;
      const startNative = () => {
        watchNative(
          (f) => {
            gotNative = true;
            onSample({ ...f, battery: battery.current });
          },
          (code, message) => {
            console.warn('[hm-track] Standort-Fehler', code, message);
            setInfo((i) => ({ ...i, status: code === 'NOT_AUTHORIZED' ? 'verweigert' : 'fehler', error: message }));
            nativeStop?.();
            nativeStop = null;
            if (!stopped) retry = setTimeout(startNative, 8000);
          },
        ).then((stop) => {
          if (stopped) stop();
          else nativeStop = stop;
        }, (err) => {
          console.warn('[hm-track] Standort-Plugin fehlt', err);
          startWeb();
        });
      };
      startNative();
      const fallback = setTimeout(() => { if (!gotNative) startWeb(); }, 20000);
      stopWatch = () => {
        clearTimeout(fallback);
        clearTimeout(retry);
        nativeStop?.();
        if (webId != null) navigator.geolocation.clearWatch(webId);
      };
    } else {
      startWeb();
      stopWatch = () => { if (webId != null) navigator.geolocation.clearWatch(webId); };
    }
    const timer = setInterval(() => void flush(), 2500);
    return () => {
      stopped = true;
      flushRef.current = null;
      stopWatch();
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVis);
      void lock?.release().catch(() => undefined);
    };
  }, [gameId, enabled]);

  return info;
}

// Einmalige Position (für Fang, Notfall).
export function currentPosition(timeoutMs = 8000): Promise<{ lat: number; lng: number; acc: number } | null> {
  return new Promise((resolve) => {
    if (!('geolocation' in navigator)) return resolve(null);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 10000 },
    );
  });
}
