/**
 * Leichtes Vibrieren beim Antippen von Knöpfen, nur in der Handy-App und nur, wenn es auf dem Handy eingeschaltet ist:
 * - iPhone: Haptics-Modul (UIImpactFeedbackGenerator); iOS lässt es weg, wenn "System-Haptik" aus ist.
 * - Android: System-Funktion performHapticFeedback; Android lässt es weg, wenn "Haptisches Feedback" aus ist.
 * In der Web-App gibt es kein Antippen-Vibrieren (der Browser kennt die Einstellung des Handys nicht).
 * Alarme (Ping, Blitzjagd) vibrieren weiterhin nach den eigenen Alarm-Einstellungen.
 */
import { Capacitor, registerPlugin } from '@capacitor/core';

const SystemHaptics = registerPlugin<{ tap: () => Promise<void> }>('SystemHaptics');
const platform = Capacitor.getPlatform();
let last = 0;

export function tapFeedback() {
  const now = Date.now();
  if (now - last < 60) return;
  last = now;
  if (platform === 'android') void SystemHaptics.tap().catch(() => undefined);
  else if (platform === 'ios') void import('@capacitor/haptics').then(({ Haptics, ImpactStyle }) => Haptics.impact({ style: ImpactStyle.Light })).catch(() => undefined);
}

/** Einmal beim Start: jedes Antippen eines Knopfs, Links, Schalters oder einer Auswahl gibt ein kurzes Feedback. */
export function installTapFeedback() {
  if (platform !== 'android' && platform !== 'ios') return;
  document.addEventListener('click', (e) => {
    const el = (e.target as HTMLElement | null)?.closest('button, a, [role="button"], input[type="checkbox"], input[type="radio"], select, summary, .chip');
    if (el && !(el as HTMLButtonElement).disabled) tapFeedback();
  }, { capture: true, passive: true });
}
