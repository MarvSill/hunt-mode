import { useState } from 'react';
import { api, clock, type GameState } from '../lib/engine';
import { Confirm, nameOf } from './common';

/** Notrufnummern Schweiz: 117 Polizei, 144 Sanität, 112 europaweit (funktioniert auch in der Schweiz). */
export const EMERGENCY_NUMBERS = [
  { n: '117', label: 'Polizei' },
  { n: '144', label: 'Sanität' },
  { n: '112', label: 'Notruf EU' },
];

export function CallButtons() {
  return (
    <div className="call-row">
      {EMERGENCY_NUMBERS.map((x, i) => (
        <a key={x.n} className={`button ${i === 0 ? 'danger' : ''}`} href={`tel:${x.n}`}>
          <strong>{x.n}</strong><span className="small">{x.label}</span>
        </a>
      ))}
    </div>
  );
}

/** Offene Notfälle: eigene (mit Abbrechen) und die anderer (alle sehen sie und sollen helfen). */
export default function EmergencyBox({ s, act, showMap }: {
  s: GameState; act: (fn: () => Promise<unknown>, ok?: string) => Promise<unknown>; showMap: () => void;
}) {
  const [contact, setContact] = useState<Record<string, string>>({});
  const role = s.me.role;
  // Den Notfallkontakt sehen nur die Hunter und wer das Spiel erstellt hat.
  const contactAllowed = role === 'hunter' || s.game.host;
  const mine = s.emergencies.find((e) => e.participant_id === s.me.id && e.status === 'offen');
  const others = s.emergencies.filter((e) => e.participant_id !== s.me.id && e.status === 'offen');
  if (!mine && others.length === 0) return null;
  return (
    <div className="stack" style={{ marginBottom: 12 }}>
      {mine && (
        <div className="card stack emergency-card">
          <strong>🚨 Dein Notfall ist gemeldet</strong>
          <span className="small">Alle sind alarmiert und sehen deinen Standort. Das Spiel ist unterbrochen.</span>
          <span className="small">Bei Gefahr sofort anrufen:</span>
          <CallButtons />
          <Confirm className="block" label="Fehlalarm / Notfall beenden" confirm="Notfall wirklich beenden? Alle bekommen die Meldung, dass alles in Ordnung ist."
            onYes={() => act(() => api.emergencyResolve(mine.id), 'Notfall beendet.')} />
        </div>
      )}
      {others.map((e) => (
        <div key={e.id} className="card stack emergency-card">
          <strong>🚨 NOTFALL: {nameOf(s, e.participant_id)} <span className="small muted">seit {clock(e.at)}</span></strong>
          <span className="small"><strong>Das Spiel ist unterbrochen. Geh sofort zum Standort auf der Karte und hilf.</strong> Bei Gefahr ruf direkt an.</span>
          {contact[e.participant_id] && <span>Notfallkontakt: <strong>{contact[e.participant_id]}</strong></span>}
          <div className="row">
            {e.lat != null && <button className="small" onClick={showMap}>📍 Auf der Karte</button>}
            {contactAllowed && !contact[e.participant_id] && (
              <button className="small" onClick={() => act(async () => {
                const c = await api.emergencyContact(s.game.id, e.participant_id);
                setContact((prev) => ({ ...prev, [e.participant_id]: c ? `${c.name} ${c.phone}` : 'nicht hinterlegt' }));
              })}>Notfallkontakt zeigen</button>
            )}
            {s.game.host && <button className="small primary" onClick={() => act(() => api.emergencyResolve(e.id), 'Notfall erledigt.')}>Erledigt</button>}
          </div>
          <CallButtons />
        </div>
      ))}
    </div>
  );
}
