import { useState } from 'react';
import { api } from '../lib/engine';
import { nameTag, type PanelProps } from './common';
import { t } from '../i18n';

/**
 * Blitzjagd direkt auf der Karte (nur Hunter): Knopf antippen, Ziel wählen, einmal bestätigen.
 * Beim Start kommt sofort der erste Ping; jede weitere Abfrage mit einem Tippen.
 */
export function SpeedhuntButtons({ s, act, onOpen }: Pick<PanelProps, 's' | 'act'> & { onOpen: () => void }) {
  const g = s.game;
  if (!g.config.speedhunt.enabled) return null;
  const live = ['laeuft', 'finale'].includes(g.status) && !g.paused;
  const running = s.speedhunts.filter((x) => x.status === 'laeuft');
  return (
    <>
      {running.map((sh) => {
        const left = sh.queries_total - sh.queries_used;
        return (
          <button key={sh.id} type="button" className="map-chip blitz" disabled={!live || left <= 0}
            onClick={() => void act(() => api.speedhuntQuery(sh.id), t('Standort abgefragt.'))}>
            ⚡ {t('Nächster Ping: {0} ({1} übrig)', { 0: nameTag(s, sh.target_id), 1: left })}
          </button>
        );
      })}
      <button type="button" className="map-chip blitz" disabled={!live || g.speedhunts_left <= 0} onClick={onOpen}>
        ⚡ {t('Blitzjagd')} ({g.speedhunts_left})
      </button>
    </>
  );
}

export function SpeedhuntDialog({ s, act, onClose }: Pick<PanelProps, 's' | 'act'> & { onClose: () => void }) {
  const [target, setTarget] = useState<string | null>(null);
  const players = s.participants.filter((p) => p.role === 'spieler' && ['aktiv', 'ausserhalb'].includes(p.state));
  // Die letzte Blitzjagd zuerst: dieselbe Person darf nicht zweimal hintereinander gejagt werden.
  const last = [...s.speedhunts].filter((x) => x.started_at).sort((a, b) => (b.started_at ?? '').localeCompare(a.started_at ?? ''))[0];
  const running = new Set(s.speedhunts.filter((x) => x.status === 'laeuft').map((x) => x.target_id));
  const why = (id: string, prot: boolean | null | undefined) =>
    running.has(id) ? t('läuft schon') : last?.target_id === id ? t('war gerade dran') : prot ? t('geschützt') : null;

  return (
    <div className="overlay" role="dialog" aria-label={t('Blitzjagd starten')} onClick={onClose}>
      <div className="card stack" style={{ maxWidth: 440, width: '100%', background: 'var(--surface)' }} onClick={(e) => e.stopPropagation()}>
        {!target ? (
          <>
            <strong style={{ fontSize: 20 }}>⚡ {t('Blitzjagd: auf wen?')}</strong>
            <span className="small muted">{t('Noch {0} Blitzjagden im Spiel. Dieselbe Person geht nicht zweimal hintereinander.', { 0: s.game.speedhunts_left })}</span>
            {players.map((p) => {
              const no = why(p.id, p.protected);
              return (
                <button key={p.id} type="button" className="block" disabled={!!no} onClick={() => setTarget(p.id)}>
                  {nameTag(s, p.id)}{no ? ` (${no})` : ''}
                </button>
              );
            })}
            {players.length === 0 && <div className="muted small">{t('Kein Spieler ist mehr frei.')}</div>}
            <button type="button" className="ghost block" onClick={onClose}>{t('Abbrechen')}</button>
          </>
        ) : (
          <>
            <strong style={{ fontSize: 20 }}>⚡ {t('Blitzjagd auf {0} starten?', { 0: nameTag(s, target) })}</strong>
            <span className="small">{t('Du bekommst sofort den ersten Ping. Die weiteren fragst du danach mit einem Tippen auf der Karte ab ({0} Abfragen).', { 0: s.game.config.speedhunt.queries })}</span>
            <button type="button" className="danger block big" onClick={() => {
              const id = target;
              onClose();
              void act(() => api.speedhuntStart(s.game.id, id), t('Blitzjagd läuft: erster Ping ist da.'));
            }}>{t('Ja, Blitzjagd starten')}</button>
            <button type="button" className="ghost block" onClick={() => setTarget(null)}>{t('Zurück')}</button>
          </>
        )}
      </div>
    </div>
  );
}
