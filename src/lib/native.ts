/**
 * Echte Handy-App (Capacitor): Standort im Hintergrund und Benachrichtigungen bei geschlossener App.
 * In der Web-App sind diese Funktionen leer; dort gilt weiterhin: nur solange die App offen ist.
 */
import { Capacitor, registerPlugin } from '@capacitor/core';
import type { BackgroundGeolocationPlugin } from '@capacitor-community/background-geolocation';
import { t } from '../i18n';

export const isNative = Capacitor.isNativePlatform();
export const platform = Capacitor.getPlatform(); // 'android' | 'ios' | 'web'

const BackgroundGeolocation = registerPlugin<BackgroundGeolocationPlugin>('BackgroundGeolocation');

export interface NativeFix { lat: number; lng: number; acc: number; speed: number | null; heading: number | null; t: number }

/** Standort laufend erfassen, auch im Hintergrund. Gibt eine Funktion zum Beenden zurück. */
export async function watchNative(onFix: (f: NativeFix) => void, onError: (code: string, message: string) => void): Promise<() => void> {
  const id = await BackgroundGeolocation.addWatcher(
    {
      backgroundTitle: t('Hunt Mode teilt deinen Standort'),
      backgroundMessage: t('Das Spiel läuft. Dein Standort wird auch bei gesperrtem Bildschirm geteilt.'),
      requestPermissions: true,
      stale: false,
      distanceFilter: 5,
    },
    (loc, err) => {
      if (err) {
        onError(err.code ?? 'ERROR', err.message ?? '');
        return;
      }
      if (!loc) return;
      onFix({ lat: loc.latitude, lng: loc.longitude, acc: Math.round(loc.accuracy), speed: loc.speed ?? null, heading: loc.bearing ?? null, t: loc.time ?? Date.now() });
    },
  );
  return () => void BackgroundGeolocation.removeWatcher({ id });
}

/** Einstellungen der App öffnen (z. B. wenn der Standort verweigert wurde). */
export function openAppSettings() {
  void BackgroundGeolocation.openSettings();
}

let notifyReady: Promise<boolean> | null = null;

/** Erlaubnis für Benachrichtigungen (Android 13+, iPhone) einmal anfragen. */
export function ensureNotifyPermission(): Promise<boolean> {
  if (!isNative) return Promise.resolve(false);
  notifyReady ??= import('@capacitor/local-notifications').then(async ({ LocalNotifications }) => {
    const p = await LocalNotifications.checkPermissions();
    if (p.display === 'granted') return true;
    return (await LocalNotifications.requestPermissions()).display === 'granted';
  }).catch(() => false);
  return notifyReady;
}

/** Kanal für Spiel-Alarme (Android). Ein Kanal behält seine ersten Einstellungen, darum ein neuer Name. */
const CHANNEL = 'hunt-alarm-v2';

/** Meldung als Benachrichtigung des Handys zeigen (Ton und Vibration kommen vom Handy, auch bei gesperrtem Bildschirm). */
export async function nativeNotify(id: number, title: string, body: string): Promise<boolean> {
  if (!isNative) return false;
  try {
    if (!(await ensureNotifyPermission())) return false;
    const { LocalNotifications } = await import('@capacitor/local-notifications');
    await LocalNotifications.schedule({ notifications: [{ id: id % 2147483647, title, body, channelId: CHANNEL, autoCancel: true }] });
    return true;
  } catch (err) {
    console.warn('[hm-notify]', err);
    return false;
  }
}

/** Kanal für Spiel-Alarme (Android): höchste Wichtigkeit, damit Ton, Vibration und Banner kommen. */
export async function setupNotifyChannel() {
  if (platform !== 'android') return;
  const { LocalNotifications } = await import('@capacitor/local-notifications');
  await LocalNotifications.deleteChannel({ id: 'hunt-alarm' }).catch(() => undefined);
  await LocalNotifications.createChannel({
    id: CHANNEL, name: t('Spiel-Alarme'), description: t('Pings, Blitzjagden, Notfälle und Nachrichten im Spiel'),
    importance: 5, vibration: true, lights: true, lightColor: '#3fb950', visibility: 1,
  }).catch((err) => console.warn('[hm-notify] Kanal', err));
}

/** Sind Benachrichtigungen erlaubt? null = Web-App (dort regelt es der Browser). */
export async function notifyAllowed(): Promise<boolean | null> {
  if (!isNative) return null;
  try {
    const { LocalNotifications } = await import('@capacitor/local-notifications');
    return (await LocalNotifications.checkPermissions()).display === 'granted';
  } catch {
    return false;
  }
}

/** Öffentliche Adresse der Web-App (für Einladungslinks auch aus der Handy-App). */
export const PUBLIC_URL = 'https://marvsill.github.io/hunt-mode';
