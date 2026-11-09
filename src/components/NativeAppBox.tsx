import { t } from '../i18n';
import { isNative, platform } from '../lib/native';

const APK_URL = 'https://github.com/MarvSill/hunt-mode/releases/download/android-app/hunt-mode.apk';

/** Hinweis auf die echte Handy-App: dort wird der Standort auch im Hintergrund geteilt. */
export default function NativeAppBox() {
  if (isNative) {
    return <div className="muted small">{t('Du nutzt die Handy-App: dein Standort wird im Spiel auch im Hintergrund und bei gesperrtem Bildschirm geteilt.')}</div>;
  }
  const ios = /iPhone|iPad|iPod/i.test(navigator.userAgent);
  return (
    <div className="stack">
      <div className="small">{t('In der Handy-App wird dein Standort auch geteilt, wenn die App im Hintergrund oder der Bildschirm gesperrt ist. Im Browser geht das nur, solange die App offen ist.')}</div>
      {!ios && (
        <>
          <a className="button primary block" href={APK_URL}>{t('Android-App herunterladen')}</a>
          <div className="muted small">{t('Datei öffnen und installieren. Beim ersten Mal fragt Android, ob du Apps aus dieser Quelle erlauben willst: einmal erlauben. Danach Standort auf „Immer“ bzw. „Bei Nutzung“ und Benachrichtigungen erlauben.')}</div>
        </>
      )}
      {ios && <div className="muted small">{t('Fürs iPhone gibt es die App noch nicht zum Herunterladen. Sie wird über einen Mac mit Xcode aufs iPhone gespielt; frag den Ersteller deiner Spiele.')}</div>}
      {platform === 'web' && !ios && <div className="muted tiny">{t('Updates: einfach die neue Datei über die alte App installieren.')}</div>}
    </div>
  );
}
