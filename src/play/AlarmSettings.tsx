import { useState } from 'react';
import { loadAlarm, ring, saveAlarm, TONE_LABELS, unlockAudio, type AlarmSettings, type Tone } from '../lib/alarm';
import { Section } from './common';
import { t } from '../i18n';
import { isNative } from '../lib/native';

/** Jeder Spieler stellt seinen Alarm für Pings und Blitzjagden selbst ein. */
export default function AlarmSettingsBox() {
  const [s, setS] = useState<AlarmSettings>(loadAlarm);
  function put(next: AlarmSettings) {
    setS(next);
    saveAlarm(next);
  }
  return (
    <Section title={t('Alarm bei Ping und Blitzjagd')} badge={<span className="badge">{s.sound ? `${TONE_LABELS[s.tone]} · ${Math.round(s.volume * 100)} %` : t('Ton aus')}{s.vibrate ? t(' · Vibration') : ''}</span>}>
      <div className="muted small">{isNative ? t('Bei jedem Ping und jeder Blitzjagd klingelt und vibriert dein Handy, und die Meldung erscheint, auch wenn die App im Hintergrund ist.') : t('Bei jedem Ping und jeder Blitzjagd klingelt und vibriert dein Handy, und die Meldung erscheint. Das gilt nur für dieses Handy und solange die App offen ist.')}</div>
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
        <button className="small" onClick={() => { unlockAudio(); ring('ping', s); }}>{t('Ping testen')}</button>
        <button className="small" onClick={() => { unlockAudio(); ring('blitzjagd', s); }}>{t('Blitzjagd testen')}</button>
      </div>
    </Section>
  );
}
