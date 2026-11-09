import { useState } from 'react';
import { loadAlarm, ring, saveAlarm, TONE_LABELS, unlockAudio, type AlarmSettings, type Tone } from '../lib/alarm';
import { Section } from './common';

/** Jeder Spieler stellt seinen Alarm für Pings und Blitzjagden selbst ein. */
export default function AlarmSettingsBox() {
  const [s, setS] = useState<AlarmSettings>(loadAlarm);
  function put(next: AlarmSettings) {
    setS(next);
    saveAlarm(next);
  }
  return (
    <Section title="Alarm bei Ping und Blitzjagd" badge={<span className="badge">{s.sound ? `${TONE_LABELS[s.tone]} · ${Math.round(s.volume * 100)} %` : 'Ton aus'}{s.vibrate ? ' · Vibration' : ''}</span>}>
      <div className="muted small">Bei jedem Ping und jeder Blitzjagd klingelt und vibriert dein Handy, und die Meldung erscheint. Das gilt nur für dieses Handy und solange die App offen ist.</div>
      <label className="check">
        <input type="checkbox" checked={s.sound} onChange={(e) => put({ ...s, sound: e.target.checked })} />
        <span>Klingelton</span>
      </label>
      {s.sound && (
        <>
          <label className="field">
            Klingelton
            <select value={s.tone} onChange={(e) => put({ ...s, tone: e.target.value as Tone })}>
              {(Object.keys(TONE_LABELS) as Tone[]).map((t) => <option key={t} value={t}>{TONE_LABELS[t]}</option>)}
            </select>
          </label>
          <label className="field">
            Lautstärke: {Math.round(s.volume * 100)} %
            <input type="range" min={0.1} max={1} step={0.05} value={s.volume} onChange={(e) => put({ ...s, volume: Number(e.target.value) })} />
          </label>
        </>
      )}
      <label className="check">
        <input type="checkbox" checked={s.vibrate} onChange={(e) => put({ ...s, vibrate: e.target.checked })} />
        <span>Vibration</span>
      </label>
      <div className="row">
        <button className="small" onClick={() => { unlockAudio(); ring('ping', s); }}>Ping testen</button>
        <button className="small" onClick={() => { unlockAudio(); ring('blitzjagd', s); }}>Blitzjagd testen</button>
      </div>
    </Section>
  );
}
