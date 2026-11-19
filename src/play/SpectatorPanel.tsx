import { countdown, ITEM_LABELS, STATE_LABELS, type GameState, type Participant } from '../lib/engine';
import { t } from '../i18n';
import { colorFor } from './common';

/** Tempo in km/h (GPS liefert m/s). Unter 1 km/h = steht. */
export function speedText(mps: number | null | undefined): string {
  if (mps == null || !Number.isFinite(mps)) return '–';
  const kmh = mps * 3.6;
  return kmh < 1 ? t('steht') : t('{0} km/h', { 0: Math.round(kmh) });
}

/** Wie alt ein Standort ist, kurz. */
function ageText(at: string | undefined, now: number): string {
  if (!at) return t('kein Standort');
  const s = Math.max(0, Math.round((now - new Date(at).getTime()) / 1000));
  if (s < 60) return t('vor {0} s', { 0: s });
  return t('vor {0} min', { 0: Math.round(s / 60) });
}

/** Zuschauer: alles live, nichts zu tun. Wer wo ist, wie schnell, welche Joker, laufende Blitzjagd. */
export default function SpectatorPanel({ s, now }: { s: GameState; now: number }) {
  const pos = new Map(s.positions.map((p) => [p.participant_id, p]));
  const players = s.participants.filter((p) => p.role === 'spieler');
  const hunters = s.participants.filter((p) => p.role === 'hunter');
  const blitz = s.speedhunts.filter((x) => x.status === 'laeuft');
  const tag = (id: string | null) => s.participants.find((p) => p.id === id)?.tag ?? '?';

  const row = (p: Participant) => {
    const x = pos.get(p.id);
    return (
      <li key={p.id} style={{ display: 'block' }}>
        <div className="row" style={{ gap: 8 }}>
          <span className="map-chip" style={{ background: colorFor(s, p.id), borderColor: colorFor(s, p.id), color: '#fff', fontWeight: 700 }}>{p.tag ?? '?'}</span>
          <span className="spacer">
            <strong>{speedText(x?.speed_mps)}</strong>
            <span className="muted small"> · {ageText(x?.at, now)}{p.battery != null ? ` · 🔋 ${Math.round(p.battery)} %` : ''}</span>
          </span>
          {p.role === 'spieler' && <span className={`badge${['aktiv'].includes(p.state) ? ' green' : ''}`}>{STATE_LABELS[p.state] ?? p.state}</span>}
        </div>
        {p.role === 'spieler' && (
          <div className="muted small" style={{ marginTop: 4 }}>
            {p.next_ping_at && ['aktiv', 'ausserhalb'].includes(p.state) && !s.game.paused && <span>⏱ {t('Ping in {0}', { 0: countdown(p.next_ping_at, now) })} </span>}
            {(p.effects ?? []).map((e, i) => (
              <span key={i} className="badge red" style={{ marginLeft: 4 }}>🃏 {ITEM_LABELS[e.type] ?? e.type}{e.ends_at ? ` · ${countdown(e.ends_at, now)}` : ''}</span>
            ))}
            {(p.jokers ?? []).length > 0 && <span style={{ marginLeft: 4 }}>{t('Joker bereit: {0}', { 0: (p.jokers ?? []).map((j) => ITEM_LABELS[j] ?? j).join(', ') })}</span>}
          </div>
        )}
      </li>
    );
  };

  return (
    <div className="stack">
      <div className="card muted small">{t('Du schaust zu: Du siehst alles live, kannst aber nichts tun. Verrate niemandem, was du siehst.')}</div>
      {blitz.map((b) => (
        <div key={b.id} className="notice error pulse">
          ⚡ <strong>{t('Blitzjagd auf {0}', { 0: tag(b.target_id) })}</strong>
          {b.queries_total > 0 && <span className="small"> · {t('{0} von {1} Pings', { 0: b.queries_used, 1: b.queries_total })}</span>}
        </div>
      ))}
      <div className="card stack">
        <h2 style={{ margin: 0 }}>{t('Spieler')} <span className="muted small">{s.free_players}/{players.length} {t('frei')}</span></h2>
        <ul className="list">{players.map(row)}</ul>
      </div>
      <div className="card stack">
        <h2 style={{ margin: 0 }}>{t('Hunter-Team')}</h2>
        <ul className="list">{hunters.map(row)}</ul>
      </div>
    </div>
  );
}
