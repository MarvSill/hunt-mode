import { useEffect, useState } from 'react';
import { loadAlarm, ring, saveAlarm, TONE_LABELS, unlockAudio, type AlarmSettings, type Tone } from '../lib/alarm';
import { Section } from './common';
import { t } from '../i18n';
import { isNative, nativeNotify, notifyAllowed, openAppSettings } from '../lib/native';

/** Jede Person stellt ihren Alarm (Pings, Blitzjagden, Meldungen) selbst ein. */
export default function AlarmSettingsBox({ hunter = false }: { hunter?: boolean }) {
  const [s, setS] = useState<AlarmSettings>(loadAlarm);
  const [allowed, setAllowed] = useState<boolean | null>(null);
  useEffect(() => {
    void notifyAllowed().then(setAllowed);
  }, []);
  function test(kind: 'ping' | 'blitzjagd') {
    unlockAudio();
    ring(kind, s);
    if (isNative) {
      void nativeNotify(Date.now() % 100000, kind === 'ping' ? t('Test: Ping') : t('Test: Blitzjagd'), t('So klingt und vibriert dein Handy im Spiel.'))
        .then((ok) => { void notifyAllowed().then(setAllowed); return ok; });
    }
  }
  function put(next: AlarmSettings) {
    setS(next);
    saveAlarm(next);
  }
  return (
    <Section title={hunter ? t('Alarm bei Meldungen') : t('Alarm bei Ping und Blitzjagd')} badge={<span className="badge">{s.sound ? `${TONE_LABELS[s.tone]} · ${Math.round(s.volume * 100)} %` : t('Ton aus')}{s.vibrate ? t(' · Vibration') : ''}</span>}>
      {allowed === false && (
        <div className="notice error small">
          {t('Benachrichtigungen sind für Hunt Mode ausgeschaltet. Ohne sie kommt kein Alarm, wenn die App im Hintergrund ist.')}{' '}
          <button className="small" onClick={openAppSettings}>{t('Einstellungen öffnen')}</button>
        </div>
      )}
      <div className="muted small">{hunter ? t('Bei wichtigen Meldungen (neuer Ping, Blitzjagd, Nachricht, Notfall) klingelt und vibriert dein Handy.') : isNative ? t('Bei jedem Ping und jeder Blitzjagd klingelt und vibriert dein Handy, und die Meldung erscheint, auch wenn die App im Hintergrund ist.') : t('Bei jedem Ping und jeder Blitzjagd klingelt und vibriert dein Handy, und die Meldung erscheint. Das gilt nur für dieses Handy und solange die App offen ist.')}</div>
      <label className="check">
        <input type="checkbox" checked={s.sound} onChange={(e) => put({ ...s, sound: e.target.checked })} />
        <span>{t('Klingelton')}</span>
      </label>
      {s.sound && (
        <>
          <label className="field">
            {t('Klingelton')}
            <select value={s.tone} onChange={(e) => put({ ...s, tone: e.target.value as Tone })}>
              {(Object.keys(TONE_LABELS) as Tone[]).map((t) => <option key={t} value={t}>{TONE_LABELS[t]}</option>)}
            </select>
          </label>
          <label className="field">
            {t('Lautstärke:')} {Math.round(s.volume * 100)} %
            <input type="range" min={0.1} max={1} step={0.05} value={s.volume} onChange={(e) => put({ ...s, volume: Number(e.target.value) })} />
          </label>
        </>
      )}
      <label className="check">
        <input type="checkbox" checked={s.vibrate} onChange={(e) => put({ ...s, vibrate: e.target.checked })} />
        <span>{t('Vibration')}</span>
      </label>
      <div className="row">
        <button className="small" onClick={() => test('ping')}>{t('Ping testen')}</button>
        <button className="small" onClick={() => test('blitzjagd')}>{t('Blitzjagd testen')}</button>
      </div>
    </Section>
  );
}
