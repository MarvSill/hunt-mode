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

/** Meldung als Benachrichtigung zeigen, wenn die App im Hintergrund ist (mit Ton und Vibration des Handys). */
export async function nativeNotify(id: number, title: string, body: string) {
  if (!isNative || !(await ensureNotifyPermission())) return;
  const { LocalNotifications } = await import('@capacitor/local-notifications');
  await LocalNotifications.schedule({ notifications: [{ id: id % 2147483647, title, body, channelId: 'hunt-alarm' }] });
}

/** Kanal für Spiel-Alarme (Android): hohe Wichtigkeit, damit Ton und Vibration kommen. */
export async function setupNotifyChannel() {
  if (platform !== 'android') return;
  const { LocalNotifications } = await import('@capacitor/local-notifications');
  await LocalNotifications.createChannel({ id: 'hunt-alarm', name: t('Spiel-Alarme'), importance: 5, vibration: true, visibility: 1 }).catch(() => undefined);
}

/** Öffentliche Adresse der Web-App (für Einladungslinks auch aus der Handy-App). */
export const PUBLIC_URL = 'https://marvsill.github.io/hunt-mode';
