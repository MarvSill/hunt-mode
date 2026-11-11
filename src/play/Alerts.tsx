import { useEffect, useState } from 'react';
import { vibrate } from '../lib/alarm';
import { isNative, notifyAllowed, openAppSettings, ensureNotifyPermission } from '../lib/native';
import type { TrackerInfo } from '../lib/tracker';
import { t } from '../i18n';

/** Ausserhalb des Spielfelds oder in einer Gefahrenzone: das Handy vibriert ohne Pause, bis man wieder drin ist. */
export function useOutsideVibration(active: boolean) {
  useEffect(() => {
    if (!active) return;
    const buzz = () => vibrate([700, 300, 700]);
    buzz();
    const i = setInterval(buzz, 2000);
    return () => clearInterval(i);
  }, [active]);
}

type Problem = 'gps_blockiert' | 'gps_fehlt' | 'gps_still' | 'ungenau' | 'benachrichtigung';

/**
 * Grosser Hinweis, sobald etwas Wichtiges nicht geht: GPS aus oder blockiert, seit langem kein Standort,
 * Benachrichtigungen ausgeschaltet. Verschwindet von selbst, wenn es wieder geht.
 */
export function DeviceAlert({ tracker, tracking }: { tracker: TrackerInfo; tracking: boolean }) {
  const [notifyOk, setNotifyOk] = useState<boolean | null>(null);
  const [snoozed, setSnoozed] = useState<Record<string, number>>({});
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const i = setInterval(() => setNow(Date.now()), 5000);
    return () => clearInterval(i);
  }, []);

  useEffect(() => {
    if (!isNative) return;
    const check = () => void notifyAllowed().then(setNotifyOk);
    check();
    const i = setInterval(check, 30000);
    document.addEventListener('visibilitychange', check);
    return () => {
      clearInterval(i);
      document.removeEventListener('visibilitychange', check);
    };
  }, []);

  // Wartet die App schon lange auf GPS? Erst nach 45 s melden (beim Start dauert der erste Standort etwas).
  const [waitSince, setWaitSince] = useState<number | null>(null);
  useEffect(() => {
    if (tracking && tracker.status === 'warte') setWaitSince((w) => w ?? Date.now());
    else setWaitSince(null);
  }, [tracking, tracker.status]);

  let problem: Problem | null = null;
  if (tracking && tracker.status === 'verweigert') problem = 'gps_blockiert';
  else if (tracking && tracker.status === 'fehler') problem = 'gps_fehlt';
  else if (tracking && waitSince && now - waitSince > 45000) problem = 'gps_fehlt';
  else if (tracking && tracker.status === 'ok' && tracker.sentAt && now - tracker.sentAt > 3 * 60000 && document.visibilityState === 'visible') problem = 'gps_still';
  else if (tracking && tracker.status === 'ok' && tracker.last && tracker.last.acc > 150) problem = 'ungenau';
  else if (isNative && notifyOk === false) problem = 'benachrichtigung';
  if (!problem || (snoozed[problem] ?? 0) > now) return null;

  const title = problem === 'benachrichtigung' ? t('Benachrichtigungen einschalten!') : problem === 'gps_still' ? t('Standort kommt nicht an!') : problem === 'ungenau' ? t('Standort ungenau!') : t('GPS einschalten!');
  const text = problem === 'gps_blockiert'
    ? t('Hunt Mode darf deinen Standort nicht sehen. Ohne Standort kannst du nicht mitspielen. Erlaube den Standort (am besten „Immer“).')
    : problem === 'gps_fehlt' ? t('Dein Handy findet gerade keinen Standort. Schalte die Ortung (GPS) ein und geh wenn möglich ins Freie.')
    : problem === 'ungenau' ? t('Dein Handy meldet den Standort nur auf {0} m genau. Schalte in den Einstellungen bei Hunt Mode „Genauer Standort“ ein (iPhone) bzw. „Genauen Standort verwenden“ (Android).', { 0: tracker.last?.acc ?? '?' })
    : problem === 'gps_still' ? t('Seit über 3 Minuten wurde dein Standort nicht mehr gesendet. Prüfe, ob Ortung und Internet eingeschaltet sind.')
    : t('Ohne Benachrichtigungen verpasst du Pings, Blitzjagden und Notfälle. Erlaube sie für Hunt Mode.');

  return (
    <div className="overlay" role="alertdialog" aria-modal="true" aria-label={title}>
      <div className="card stack emergency-card" style={{ maxWidth: 440, width: '100%', background: 'var(--surface)', textAlign: 'center' }}>
        <div style={{ fontSize: 48 }} aria-hidden="true">{problem === 'benachrichtigung' ? '🔔' : '📍'}</div>
        <strong style={{ fontSize: 22 }}>{title}</strong>
        <span>{text}</span>
        {(isNative || problem === 'benachrichtigung') && (
          <button className="primary block big" onClick={() => {
            if (problem === 'benachrichtigung') void ensureNotifyPermission().then((ok) => (ok ? setNotifyOk(true) : openAppSettings()));
            else openAppSettings();
          }}>{t('Einstellungen öffnen')}</button>
        )}
        {!isNative && problem !== 'benachrichtigung' && (
          <span className="small muted">{t('Im Browser: Tippe auf das Schloss neben der Adresse und erlaube den Standort. Danach die Seite neu laden.')}</span>
        )}
        <button className="ghost block" onClick={() => setSnoozed((x) => ({ ...x, [problem!]: Date.now() + 60000 }))}>{t('In 1 Minute erinnern')}</button>
      </div>
    </div>
  );
}
