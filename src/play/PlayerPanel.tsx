import { useState } from 'react';
import { api, clock, countdown, ITEM_HELP, ITEM_ICONS, ITEM_LABELS } from '../lib/engine';
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
          <span className="small">{t('Antwort bis')} {clock(pendingCatch.expires_at)}{t('. Lehnst du ab, gilt der Fang nicht. Ohne Antwort entscheidet der GPS-Abstand.')}</span>
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

      {me.radar && <RadarCard radar={me.radar} now={now} />}

      {g.exit_revealed && g.ends_at && (() => {
        const openAt = new Date(g.ends_at).getTime() - cfg.exit.usable_minutes_before_end * 60000;
        const open = now >= openAt;
        return (
          <div className={`notice ${open ? 'success' : ''} stack`} role="status">
            <strong>🏁 {open ? t('Fluchtpunkt noch offen bis {0}', { 0: clock(g.ends_at, g.timezone) }) : t('Fluchtpunkt bekannt, aber noch zu')}</strong>
            {!open && <div className="big-num">{t('öffnet in {0}', { 0: countdown(new Date(openAt).toISOString(), now) })}</div>}
            {open && <div className="big-num">{t('noch {0}', { 0: countdown(g.ends_at, now) })}</div>}
            <span className="small">{t('Gerettet ist, wer zwischen {0} und {1} (Spielende) frei im gestrichelten Kreis ist. Vorher zählt es noch nicht.', { 0: clock(new Date(openAt).toISOString(), g.timezone), 1: clock(g.ends_at, g.timezone) })}</span>
          </div>
        );
      })()}

      {cfg.joker.enabled && <JokerBox s={s} now={now} act={act} running={running} />}

      <button className="primary block big" onClick={() => setShowCode(true)}>{t('Fang-Code zeigen')}</button>

      <Section title={t('Status')}>
        <div className="grid2">
          {s.participants.find((p) => p.id === me.id)?.tag && <div><div className="muted small">{t('Dein Buchstabe')}</div><div className="big-num">{s.participants.find((p) => p.id === me.id)?.tag}</div></div>}
          <div><div className="muted small">{t('Nächster Ping')}</div><div className="big-num">{me.next_ping_at ? countdown(me.next_ping_at, now) : '–'}</div></div>
          {me.hideout && (
            <div><div className="muted small">{t('Verschanzt')} {me.hideout.inside ? t('(drinnen)') : t('(draussen)')}</div>
              <div className="big-num">{formatMinutes(Math.floor((me.hideout.max_s - me.hideout.accum_s) / 60))} {t('übrig')}</div></div>
          )}
          {me.live && <div><div className="muted small">{t('Sichtbarkeit')}</div><div className="big-num red">{t('LIVE')}</div></div>}
        </div>
        {me.effects.filter((e) => e.type !== 'fake_ping' && e.type !== 'hunter_snapshot' && e.type !== 'leo' && e.type !== 'naehe_radar').map((e) => (
          <div key={e.id} className="badge green">{ITEM_LABELS[e.type] ?? e.type} {t('bis')} {clock(e.ends_at)}</div>
        ))}
        {cfg.hideout.enabled && cfg.hideout.detection !== 'automatisch' && !me.hideout?.inside && running && (
          <button className="small" onClick={() => act(() => api.hideout(g.id, true), t('Verschanzen gemeldet.'))}>{t('Ich bin verschanzt (Haus/Wohnung)')}</button>
        )}
        {me.hideout?.inside && <button className="small" onClick={() => act(() => api.hideout(g.id, false))}>{t('Ich bin wieder draussen')}</button>}
      </Section>




      {g.exit_revealed && cfg.exit.confirm !== 'geofence' && g.ends_at && now >= new Date(g.ends_at).getTime() - cfg.exit.usable_minutes_before_end * 60000 && (
        <button className="block" onClick={() => act(() => api.confirmExit(g.id), t('Am Fluchtpunkt!'))}>{t('Ich bin am Fluchtpunkt')}</button>
      )}

      <Confirm className="ghost block" label={t('Aufgeben')} confirm={t('Wirklich aufgeben?')} onYes={() => act(() => api.giveUp(g.id))} />
    </div>
  );
}

/** Joker gut sichtbar: grosser Titel, darunter jeder Joker mit eigenem Zeichen. Noch gesperrte mit Uhrzeit. */
function JokerBox({ s, now, act, running }: Pick<PanelProps, 's' | 'now' | 'act'> & { running: boolean }) {
  const g = s.game;
  const cfg = g.config;
  const huntStart = g.hunt_start_at ? new Date(g.hunt_start_at).getTime() : null;
  const locked = huntStart == null ? cfg.joker.types : cfg.joker.types.filter((j) => huntStart + j.after_minutes * 60000 > now);
  if (s.me.inventory.length === 0 && locked.length === 0) return null;
  return (
    <div className="joker-box">
      <h2 className="joker-title">🃏 {t('Deine Joker')}</h2>
      <div className="joker-grid">
        {s.me.inventory.map((i) => (
          <div key={i.id} className="joker-card">
            <div className="joker-icon" aria-hidden="true">{ITEM_ICONS[i.type] ?? '🃏'}</div>
            <div className="joker-name">{ITEM_LABELS[i.type] ?? i.type}{i.minutes ? ` · ${formatMinutes(i.minutes)}` : ''}{i.distance_m ? ` · ${i.distance_m} m` : ''}</div>
            {ITEM_HELP[i.type] && <div className="muted tiny">{ITEM_HELP[i.type]}</div>}
            {i.type === 'wahl' ? (
              <select aria-label={t('Joker wählen')} disabled={!running} defaultValue="" onChange={(e) => e.target.value && act(() => api.useItem(i.id, { type: e.target.value }), t('Joker aktiv.'))}>
                <option value="">{t('Einsetzen …')}</option>
                {cfg.joker.types.map((j) => <option key={j.type} value={j.type}>{ITEM_LABELS[j.type]}</option>)}
              </select>
            ) : (
              <Confirm className="primary small" disabled={!running} label={t('Einsetzen')} confirm={t('Jetzt einsetzen?')} onYes={() => act(() => api.useItem(i.id), t('Eingesetzt.'))} />
            )}
          </div>
        ))}
        {locked.map((j, k) => (
          <div key={`l${k}`} className="joker-card locked">
            <div className="joker-icon" aria-hidden="true">{ITEM_ICONS[j.type] ?? '🃏'}</div>
            <div className="joker-name">{ITEM_LABELS[j.type] ?? j.type}{j.minutes ? ` · ${formatMinutes(j.minutes)}` : ''}{j.type === 'naehe_radar' ? ` · ${j.distance_m ?? 500} m` : ''}</div>
            <div className="muted tiny">🔒 {huntStart != null
              ? t('frei ab {0}', { 0: clock(new Date(huntStart + j.after_minutes * 60000).toISOString(), g.timezone) })
              : t('frei {0} nach Jagdbeginn', { 0: formatMinutes(j.after_minutes) })}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Nähe-Radar (Joker): gross und klar, ob ein Hunter nah ist. Wo er ist, zeigt er nie. */
function RadarCard({ radar, now }: { radar: NonNullable<PanelProps['s']['me']['radar']>; now: number }) {
  const near = radar.near;
  return (
    <div className={`notice stack ${near ? 'error pulse' : near === false ? 'success' : ''}`} role="status" aria-live="polite">
      <strong style={{ fontSize: 18 }}>📡 {near
        ? t('Hunter näher als {0} m!', { 0: radar.distance_m })
        : near === false ? t('Kein Hunter näher als {0} m', { 0: radar.distance_m }) : t('Nähe-Radar: dein Standort fehlt noch')}</strong>
      <span className="small">{t('Nähe-Radar noch {0}. Es zeigt nur, ob ein Hunter nah ist, nicht wo.', { 0: countdown(radar.ends_at, now) })}</span>
    </div>
  );
}
