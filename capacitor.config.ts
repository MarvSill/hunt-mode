import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Echte Handy-App (Android und iPhone) aus demselben Code wie die Web-App.
 * Unterschied zur Web-App: der Standort wird auch im Hintergrund und bei gesperrtem Bildschirm geteilt.
 */
const config: CapacitorConfig = {
  appId: 'ch.huntmode.app',
  appName: 'Hunt Mode',
  webDir: 'dist',
  android: {
    // Sonst stoppt Android die Standort-Updates nach 5 Minuten im Hintergrund.
    useLegacyBridge: true,
    // Vorübergehend: Fehlersuche per USB-Kabel (chrome://inspect), um das Standort-Problem zu finden.
    webContentsDebuggingEnabled: true,
  },
  plugins: {
    // Anfragen an den Server über die native Verbindung: Android bremst die WebView im Hintergrund.
    CapacitorHttp: { enabled: true },
    LocalNotifications: { iconColor: '#3fb950' },
  },
};

export default config;
