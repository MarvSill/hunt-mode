import { useState } from 'react';
import { api, clock, countdown, ITEM_HELP, ITEM_LABELS } from '../lib/engine';
import { formatMinutes } from '../shared/format';
import CatchCode from './CatchCode';
import { Confirm, nameOf, Section, type PanelProps } from './common';
import { t } from '../i18n';

export default function PlayerPanel({ s, now, act }: PanelProps) {
  const cfg = s.game.config;
  const me = s.me;
  const g = s.game;
  const [showCode, setShowCode] = useState(false);
  const active = ['aktiv', 'ausserhalb'].includes(me.state);
  const running = ['laeuft', 'finale'].includes(g.status) && !g.paused;
  const pendingCatch = s.catches.find((c) => c.runner_id === me.id && c.status === 'wartet_auf_bestaetigung');
  const shOnMe = s.speedhunts.some((x) => x.status === 'laeuft' && x.target_id === me.id);
  const shRunning = s.speedhunts.filter((x) => x.status === 'laeuft');

  if (!active) {
    return (
      <Section title={me.state === 'im_ziel' ? t('Geschafft!') : me.state === 'notfall' ? t('Notfall gemeldet') : t('Du bist raus')}>
        <p className="muted">
          {me.state === 'gefangen' && t('Du wurdest gefangen. Du kannst weiter zuschauen.')}
          {me.state === 'im_ziel' && t('Du hast den Fluchtpunkt erreicht. Warte auf das Spielende.')}
          {me.state === 'notfall' && t('Alle sind informiert und kommen helfen. Das Spiel ist unterbrochen. Beenden kannst du den Notfall oben.')}
          {['disqualifiziert', 'aufgegeben', 'verloren'].includes(me.state) && t('Du nimmst nicht mehr am Spiel teil.')}
        </p>
      </Section>
    );
  }

  return (
    <div className="stack">
      {showCode && <CatchCode gameId={g.id} onClose={() => setShowCode(false)} />}

      {pendingCatch && (
        <div className="notice error stack">
          <strong>{nameOf(s, pendingCatch.hunter_id)} {t('meldet, dass du gefangen wurdest.')}</strong>
          <span className="small">{t('Antwort bis')} {clock(pendingCatch.expires_at)}{t('. Ohne Antwort entscheidet der GPS-Abstand.')}</span>
          <div className="row">
            <button className="primary" onClick={() => act(() => api.catchRespond(pendingCatch.id, true))}>{t('Ja, gefangen')}</button>
            <button onClick={() => act(() => api.catchRespond(pendingCatch.id, false))}>{t('Nein, stimmt nicht')}</button>
          </div>
        </div>
      )}

      {me.hideout_prompt && (
        <div className="notice stack">
          <strong>{t('Bist du verschanzt?')}</strong>
          <span className="small">{t('Du bist schon länger am selben Ort. In Wohnungen, Häusern oder anderen nicht öffentlichen Orten zählt die Zeit (max.')} {formatMinutes(cfg.hideout.max_minutes)}).</span>
          <div className="row">
            <button className="primary" onClick={() => act(() => api.hideout(g.id, true))}>{t('Ja, ich bin drinnen')}</button>
            <button onClick={() => act(() => api.hideout(g.id, false))}>{t('Nein, draussen')}</button>
          </div>
        </div>
      )}


      {(() => {
        // Nähe-Alarm: Countdown, solange die Warnung gilt.
        const near = s.notifications.find((n) => n.kind === 'proximity_self');
        const deadline = near?.payload.deadline as string | undefined;
        if (!near || !deadline || new Date(deadline).getTime() <= now || s.game.exit_revealed) return null;
        return (
          <div className="notice error stack" role="alert">
            <strong>{near.title}</strong>
            <div className="big-num red">{countdown(deadline, now)}</div>
            <span className="small">{t('Entfernt euch voneinander. Seid ihr dann noch zu nahe, bekommen die Hunter euren Ping. Wo')} {String(near.payload.name ?? t('der andere'))} {t('ist, siehst du auf der Karte.')}</span>
          </div>
        );
      })()}

      {me.out_pending && me.state !== 'ausserhalb' && (() => {
        // Countdown aus der letzten Warnung: so lange Zeit, um ins Spielfeld zurückzukehren.
        const warn = s.notifications.find((n) => n.kind === 'outside_warning');
        const deadline = warn?.payload.deadline as string | undefined;
        return (
          <div className="notice error pulse stack" role="alert">
            <strong style={{ fontSize: 20 }}>{t('Zurück ins Spielfeld!')}</strong>
            {deadline && <div className="big-num red">{countdown(deadline, now)}</div>}
            <span className="small">{t('Bist du bis dann nicht zurück, sehen dich die Hunter live. Ab dem 3. Verlassen gibt es keinen Countdown mehr.')}</span>
          </div>
        );
      })()}

      {me.state === 'ausserhalb' && (
        <div className="notice error">
          <strong>{t('Du bist ausserhalb des Spielfelds!')}</strong> {t('Die Hunter sehen dich live. Zeit draussen:')} {formatMinutes(Math.floor(me.out_accum_s / 60))} {t('von')} {formatMinutes(cfg.out_of_bounds.max_minutes)}.
        </div>
      )}
      {me.in_restricted && (() => {
        // Gefahrenzone: gleicher Countdown wie beim Verlassen des Spielfelds.
        const warn = s.notifications.find((n) => n.kind === 'danger_warning' || n.kind === 'danger_live');
        const deadline = warn?.kind === 'danger_warning' ? (warn.payload.deadline as string | undefined) : undefined;
        const live = !deadline || new Date(deadline).getTime() <= now;
        return (
          <div className="notice error pulse stack" role="alert">
            <strong style={{ fontSize: 20 }}>{t('Gefahrenzone! Sofort raus')}</strong>
            {!live && deadline && <div className="big-num red">{countdown(deadline, now)}</div>}
            <span className="small">{live ? t('Die Hunter sehen dich live, bis du die Gefahrenzone verlassen hast.') : t('Bist du bis dann nicht draussen, sehen dich die Hunter live. Ab dem 3. Mal gibt es keinen Countdown mehr.')}</span>
          </div>
        );
      })()}

      {shRunning.length > 0 && (
        <div className="notice error pulse">
          <strong>{t('BLITZJAGD läuft')}{shOnMe ? t(' auf DICH') : ''}!</strong>{' '}
          {shRunning.map((x) => t('Abfrage {0}/{1}', { 0: x.queries_used, 1: x.queries_total })).join(' · ')}
        </div>
      )}

      <button className="primary block big" onClick={() => setShowCode(true)}>{t('Fang-Code zeigen')}</button>

      <Section title={t('Status')}>
        <div className="grid2">
          <div><div className="muted small">{t('Nächster Ping')}</div><div className="big-num">{me.next_ping_at ? countdown(me.next_ping_at, now) : '–'}</div></div>
          {me.hideout && (
            <div><div className="muted small">{t('Verschanzt')} {me.hideout.inside ? t('(drinnen)') : t('(draussen)')}</div>
              <div className="big-num">{formatMinutes(Math.floor((me.hideout.max_s - me.hideout.accum_s) / 60))} {t('übrig')}</div></div>
          )}
          {me.live && <div><div className="muted small">{t('Sichtbarkeit')}</div><div className="big-num red">{t('LIVE')}</div></div>}
        </div>
        {me.effects.filter((e) => e.type !== 'fake_ping' && e.type !== 'hunter_snapshot' && e.type !== 'leo').map((e) => (
          <div key={e.id} className="badge green">{ITEM_LABELS[e.type] ?? e.type} {t('bis')} {clock(e.ends_at)}</div>
        ))}
        {cfg.hideout.enabled && cfg.hideout.detection !== 'automatisch' && !me.hideout?.inside && running && (
          <button className="small" onClick={() => act(() => api.hideout(g.id, true), t('Verschanzen gemeldet.'))}>{t('Ich bin verschanzt (Haus/Wohnung)')}</button>
        )}
        {me.hideout?.inside && <button className="small" onClick={() => act(() => api.hideout(g.id, false))}>{t('Ich bin wieder draussen')}</button>}
      </Section>

      {(me.inventory.length > 0) && (
        <Section title={t('Joker')}>
          {me.inventory.map((i) => (
            <div key={i.id} className="row">
              <span className="spacer">
                {ITEM_LABELS[i.type] ?? i.type}{i.minutes ? ` (${formatMinutes(i.minutes)})` : ''}
                {ITEM_HELP[i.type] && <span className="muted tiny" style={{ display: 'block' }}>{ITEM_HELP[i.type]}</span>}
              </span>
              {i.type === 'wahl' ? (
                <select aria-label={t('Joker wählen')} disabled={!running} defaultValue="" onChange={(e) => e.target.value && act(() => api.useItem(i.id, { type: e.target.value }), t('Joker aktiv.'))}>
                  <option value="">{t('Einsetzen …')}</option>
                  {cfg.joker.types.map((t) => <option key={t.type} value={t.type}>{ITEM_LABELS[t.type]}</option>)}
                </select>
              ) : (
                <Confirm className="small" disabled={!running} label={t('Einsetzen')} confirm={t('Jetzt einsetzen?')} onYes={() => act(() => api.useItem(i.id), t('Eingesetzt.'))} />
              )}
            </div>
          ))}
        </Section>
      )}



      {g.exit_revealed && cfg.exit.confirm !== 'geofence' && (
        <button className="block" onClick={() => act(() => api.confirmExit(g.id), t('Am Fluchtpunkt!'))}>{t('Ich bin am Fluchtpunkt')}</button>
      )}

      <Confirm className="ghost block" label={t('Aufgeben')} confirm={t('Wirklich aufgeben?')} onYes={() => act(() => api.giveUp(g.id))} />
    </div>
  );
}
