import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Echte Handy-App (Android und iPhone) aus demselben Code wie die Web-App.
 * Unterschied zur Web-App: der Standort wird auch im Hintergrund und bei gesperrtem Bildschirm geteilt.
 */
const config: CapacitorConfig = {
  appId: 'ch.huntmode.app',
  appName: 'Hunt Mode',
  webDir: 'dist',
  // Hintergrund hinter der App (sichtbar beim Laden und hinter den Leisten), wie --bg in styles.css.
  backgroundColor: '#0a0d13',
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
    // Android: helle Symbole in Status- und Navigationsleiste (die App ist dunkel).
    SystemBars: { style: 'DARK' },
  },
};

export default config;
