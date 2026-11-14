import { useState } from 'react';
import type { GameState, Participant } from '../lib/engine';
import { t } from '../i18n';

export interface PanelProps {
  s: GameState;
  now: number;
  act: (fn: () => Promise<unknown>, okText?: string) => Promise<boolean>;
  pos: { lat: number; lng: number } | null;
}

export function byId(s: GameState) {
  const m = new Map<string, Participant>();
  for (const p of s.participants) m.set(p.id, p);
  return m;
}

export function nameOf(s: GameState, id: string | null | undefined) {
  if (!id) return t('Unbekannt');
  return s.participants.find((p) => p.id === id)?.name ?? t('Unbekannt');
}

/** Zeichen einer Person (Spieler "A", Hunter "H1"), falls schon vergeben. */
export function tagOf(s: GameState, id: string | null | undefined): string | undefined {
  return s.participants.find((p) => p.id === id)?.tag ?? undefined;
}

/** Name mit Zeichen davor, z. B. "A · Anna". */
export function nameTag(s: GameState, id: string | null | undefined): string {
  // Im Spiel nur der Buchstabe (die Namen der anderen sieht niemand).
  return tagOf(s, id) ?? nameOf(s, id);
}

// Gut unterscheidbare Farben ohne Gelb und Rot (Gelb = letzter Ping, Rot = Blitzjagd und Hunter).
export const PLAYER_COLORS = ['#2ea043', '#1f6feb', '#a371f7', '#db6d28', '#f778ba', '#1b9aaa', '#8b5a2b', '#6e7781', '#0e4429', '#6639ba'];

export function colorFor(s: GameState, id: string) {
  const p = s.participants.find((x) => x.id === id);
  if (p?.color) return p.color;
  if (p && p.role === 'hunter') return '#f85149';
  const players = s.participants.filter((x) => x.role === 'spieler' || x.state === 'gefangen');
  const i = Math.max(0, players.findIndex((x) => x.id === id));
  return PLAYER_COLORS[i % PLAYER_COLORS.length];
}

export function Confirm({ label, confirm, onYes, className, disabled }: { label: string; confirm: string; onYes: () => void; className?: string; disabled?: boolean }) {
  const [ask, setAsk] = useState(false);
  if (!ask) return <button className={className} disabled={disabled} onClick={() => setAsk(true)}>{label}</button>;
  return (
    <div className="row">
      <span className="small">{confirm}</span>
      <button className="primary small" onClick={() => { setAsk(false); onYes(); }}>{t('Ja')}</button>
      <button className="small ghost" onClick={() => setAsk(false)}>{t('Nein')}</button>
    </div>
  );
}

export function Section({ title, children, badge }: { title: string; children: React.ReactNode; badge?: React.ReactNode }) {
  return (
    <div className="card stack">
      <div className="row"><h2 style={{ margin: 0 }} className="spacer">{title}</h2>{badge}</div>
      {children}
    </div>
  );
}
