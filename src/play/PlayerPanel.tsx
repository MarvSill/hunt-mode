import { api, clock, countdown, ITEM_HELP, ITEM_ICONS, ITEM_LABELS } from '../lib/engine';
import { formatMinutes } from '../shared/format';
import { Confirm, nameOf, Section, type PanelProps } from './common';
import { t } from '../i18n';

/**
 * Spieler-Bereich, aufgeteilt (Runde 17):
 * - PlayerAlerts: was gerade wichtig ist, direkt bei der Karte (Fang bestätigen, ausserhalb, Gefahrenzone, Blitzjagd,
 *   Fluchtpunkt). Erscheint nur, wenn es gerade gilt.
 * - PlayerPanel ("Aktionen"): Joker (und Nähe-Radar, wenn aktiv).
 * - PlayerMore ("Mehr"): Status, Aufgeben.
 */
export function PlayerAlerts({ s, now, act, compact = false }: Pick<PanelProps, 's' | 'now' | 'act'> & { compact?: boolean }) {
  const cfg = s.game.config;
  const me = s.me;
  const g = s.game;
  if (me.role !== 'spieler' || !['aktiv', 'ausserhalb'].includes(me.state)) return null;
  const shOnMe = s.speedhunts.some((x) => x.status === 'laeuft' && x.target_id === me.id);
  const exit = g.exit_revealed && g.ends_at ? (() => {
    const openAt = new Date(g.ends_at).getTime();
    const endAt = g.deadline_at ?? g.ends_at;
    return { openAt, endAt, open: now >= openAt };
  })() : null;
  const danger = me.in_restricted ? (() => {
    const warn = s.notifications.find((n) => n.kind === 'danger_warning' || n.kind === 'danger_live');
    const deadline = warn?.kind === 'danger_warning' ? (warn.payload.deadline as string | undefined) : undefined;
    return { deadline, live: !deadline || new Date(deadline).getTime() <= now };
  })() : null;
  return (
    <div className="stack alerts">
      {me.state === 'ausserhalb' && !compact && (
        <div className="notice error pulse stack" role="alert">
          <strong style={{ fontSize: 20 }}>{t('Zurück ins Spielfeld!')}</strong>
          <span>{t('Die Hunter sehen dich live, bis du wieder drin bist. Zeit draussen:')} {formatMinutes(Math.floor(me.out_accum_s / 60))} {t('von')} {formatMinutes(cfg.out_of_bounds.max_minutes)}.</span>
        </div>
      )}
      {danger && (
        <div className="notice error pulse stack" role="alert">
          <strong style={{ fontSize: compact ? 16 : 20 }}>{t('Gefahrenzone! Sofort raus')}{!danger.live && danger.deadline ? ` · ${countdown(danger.deadline, now)}` : ''}</strong>
          {!compact && <span className="small">{danger.live ? t('Die Hunter sehen dich live, bis du die Gefahrenzone verlassen hast.') : t('Bist du bis dann nicht draussen, sehen dich die Hunter live. Ab dem 3. Mal gibt es keinen Countdown mehr.')}</span>}
        </div>
      )}
      {shOnMe && <div className="notice error pulse"><strong>⚡ {t('BLITZJAGD läuft')}{t(' auf DICH')}!</strong></div>}
      {exit && (
        <div className={`notice ${exit.open ? 'success' : ''} stack`} role="status">
          <strong>🏁 {exit.open ? t('Fluchtpunkt offen: jetzt hin!') : t('Fluchtpunkt bekannt, aber noch zu')} · {exit.open ? t('noch {0}', { 0: countdown(exit.endAt, now) }) : t('öffnet in {0}', { 0: countdown(new Date(exit.openAt).toISOString(), now) })}</strong>
          {!compact && <span className="small">{t('Er öffnet um {0}, wenn die Spielzeit abgelaufen ist. Wer bis {1} frei in den gestrichelten Kreis kommt, ist gerettet.', { 0: clock(new Date(exit.openAt).toISOString(), g.timezone), 1: clock(exit.endAt, g.timezone) })}</span>}
          {exit.open && cfg.exit.confirm !== 'geofence' && (
            <button className="primary" onClick={() => act(() => api.confirmExit(g.id), t('Am Fluchtpunkt!'))}>{t('Ich bin am Fluchtpunkt')}</button>
          )}
        </div>
      )}
    </div>
  );
}

/** "Aktionen" der Spieler: Joker (und Nähe-Radar, wenn aktiv). */
export default function PlayerPanel({ s, now, act }: PanelProps) {
  const cfg = s.game.config;
  const me = s.me;
  const g = s.game;
  const active = ['aktiv', 'ausserhalb'].includes(me.state);
  const running = ['laeuft', 'finale'].includes(g.status) && !g.paused;

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
      {me.radar && <RadarCard radar={me.radar} now={now} />}
      {cfg.joker.enabled && <JokerBox s={s} now={now} act={act} running={running} />}
      {cfg.joker.enabled && s.me.inventory.length === 0 && <div className="muted small">{t('Noch keine Joker frei.')}</div>}
    </div>
  );
}

/** "Mehr" der Spieler: Status (Joker-Wirkungen, live) und Aufgeben. */
export function PlayerMore({ s, act }: Pick<PanelProps, 's' | 'act'>) {
  const me = s.me;
  const g = s.game;
  const active = ['aktiv', 'ausserhalb'].includes(me.state);
  const effects = me.effects.filter((e) => e.type !== 'fake_ping' && e.type !== 'hunter_snapshot' && e.type !== 'leo' && e.type !== 'naehe_radar');
  return (
    <Section title={`📊 ${t('Status')}`}>
      <div className="grid2">
        {me.live && <div><div className="muted small">{t('Sichtbarkeit')}</div><div className="big-num red">{t('LIVE')}</div></div>}
      </div>
      {effects.map((e) => (
        <div key={e.id} className="badge green">{ITEM_LABELS[e.type] ?? e.type} {t('bis')} {clock(e.ends_at)}</div>
      ))}
      {active && <Confirm className="ghost block" label={`🏳️ ${t('Aufgeben')}`} confirm={t('Wirklich aufgeben?')} onYes={() => act(() => api.giveUp(g.id))} />}
    </Section>
  );
}

/** Joker gut sichtbar: grosser Titel, darunter jeder Joker mit eigenem Zeichen. Noch gesperrte mit Uhrzeit. */
export function JokerBox({ s, now, act, running }: Pick<PanelProps, 's' | 'now' | 'act'> & { running: boolean }) {
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

/** Ein Hunter meldet einen Fang: Fenster mitten auf dem Bildschirm (über allem, auch über Chat und grosser Karte). */
export function CatchAsk({ s, act }: Pick<PanelProps, 's' | 'act'>) {
  const pendingCatch = s.me.role === 'spieler' ? s.catches.find((c) => c.runner_id === s.me.id && c.status === 'wartet_auf_bestaetigung') : undefined;
  if (!pendingCatch) return null;
  return (
    <div className="overlay catch-ask" role="alertdialog" aria-modal="true" aria-label={t('Wurdest du gefangen?')}>
      <div className="card stack" style={{ maxWidth: 420, width: '100%', background: 'var(--surface)', textAlign: 'center' }}>
        <div style={{ fontSize: 52 }} aria-hidden="true">🤚</div>
        <strong style={{ fontSize: 22 }}>{t('{0} meldet: Du bist gefangen.', { 0: nameOf(s, pendingCatch.hunter_id) })}</strong>
        <span className="small muted">{t('Stimmt das? Antwort bis {0}. Ohne Antwort entscheidet der GPS-Abstand.', { 0: clock(pendingCatch.expires_at) })}</span>
        <button className="danger block big" onClick={() => act(() => api.catchRespond(pendingCatch.id, true))}>{t('Ja, gefangen')}</button>
        <button className="block big" onClick={() => act(() => api.catchRespond(pendingCatch.id, false))}>{t('Nein, stimmt nicht')}</button>
      </div>
    </div>
  );
}
