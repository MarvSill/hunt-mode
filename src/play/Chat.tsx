import { useEffect, useRef, useState } from 'react';
import { api } from '../lib/engine';
import { db, errorText } from '../lib/supabase';
import type { GameState } from '../lib/engine';
import { t, locale } from '../i18n';
import Info from '../components/Info';

interface Msg { id: number; channel: string; sender_id: string | null; sender_name: string | null; body: string; at: string }

/** Ein Chat-Verlauf: schreibt in `id`, zeigt die Nachrichten aller Kanäle in `read` (null = alle). */
export interface ChatThread { id: string; label: string; write: boolean; read: string[] | null }

/**
 * Chats im Spiel. Spieler schreiben nie mit anderen Spielern:
 * - Ein Spieler hat genau einen Verlauf mit den Huntern: seine Nachrichten, die Antworten der Hunter
 *   und was die Hunter allen Spielern schreiben, alles im selben Chat.
 * - Hunter haben je Spieler denselben Verlauf, dazu das Hunter-Team und "An alle Spieler".
 */
export function channelsFor(s: GameState): ChatThread[] {
  const r = s.me.role;
  if (r === 'spieler') {
    return [{ id: `sp:${s.me.id}`, label: t('Mit den Huntern'), write: true, read: [`sp:${s.me.id}`, 'spieler'] }];
  }
  if (r === 'hunter') {
    return [
      { id: '*', label: t('Alle Nachrichten'), write: false, read: null },
      { id: 'taskforce', label: t('Hunter-Team'), write: true, read: ['taskforce'] },
      { id: 'spieler', label: t('An alle Spieler'), write: true, read: ['spieler'] },
      ...s.participants.filter((p) => p.role === 'spieler').map((p) => ({
        id: `sp:${p.id}`, label: t('Mit {0}', { 0: p.tag ?? p.name }), write: true, read: [`sp:${p.id}`, 'spieler'],
      })),
    ];
  }
  return [];
}

// Chat über die Tabelle messages (RLS filtert die Kanäle), neue Nachrichten per Realtime.
export function MessageList({ filter, value, channel, onSend, height = '50dvh', labelOf, onPick, fill = false }: {
  filter: { column: 'game_id' | 'group_id'; value: string };
  value?: string;
  /** Kanäle, deren Nachrichten gezeigt werden (null = alle). */
  channel: string[] | null;
  onSend: ((body: string) => Promise<unknown>) | null;
  height?: string;
  /** Bei "Alle Nachrichten": Name des Kanals über jeder Nachricht. */
  labelOf?: (channel: string) => string | null;
  /** Antippen einer Nachricht öffnet ihren Kanal (zum Antworten). */
  onPick?: (channel: string) => void;
  /** Ganze verfügbare Höhe nutzen: Nachrichten scrollen, das Eingabefeld bleibt immer unten sichtbar. */
  fill?: boolean;
}) {
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [text, setText] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [me, setMe] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    void db().auth.getUser().then(({ data }) => setMe(data.user?.id ?? null));
  }, []);

  useEffect(() => {
    const fetchAll = () => {
      let q = db().from('messages').select('id,channel,sender_id,sender_name,body,at').eq(filter.column, filter.value).order('id', { ascending: false }).limit(100);
      if (channel) q = q.in('channel', channel);
      void q.then(({ data, error }) => {
        if (error) return;
        const list = ((data ?? []) as Msg[]).reverse();
        // Nur ersetzen, wenn sich etwas geändert hat (sonst springt die Liste).
        setMsgs((prev) => (prev.length === list.length && prev[prev.length - 1]?.id === list[list.length - 1]?.id ? prev : list));
      });
    };
    fetchAll();
    // Falls die Live-Verbindung hängt: alle 10 s nachschauen.
    const poll = setInterval(fetchAll, 10000);
    const sub = db()
      .channel(`msg:${filter.value}:${channel?.join(',') ?? 'all'}:${value ?? ''}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `${filter.column}=eq.${filter.value}` }, (p) => {
        const m = p.new as Msg;
        if (!channel || channel.includes(m.channel)) setMsgs((prev) => (prev.some((x) => x.id === m.id) ? prev : [...prev, m]));
      })
      .subscribe();
    return () => {
      clearInterval(poll);
      void db().removeChannel(sub);
    };
  }, [filter.column, filter.value, channel?.join(','), value]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    box.current?.scrollTo({ top: box.current.scrollHeight });
  }, [msgs]);

  async function send() {
    if (!text.trim() || !onSend) return;
    setErr(null);
    try {
      await onSend(text.trim());
      setText('');
    } catch (e) {
      setErr(errorText(e));
    }
  }

  return (
    <div className="stack" style={fill ? { display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, gap: 8 } : undefined}>
      <div ref={box} className="chat" style={fill ? { flex: 1, minHeight: 0, maxHeight: 'none', overflowY: 'auto' } : { maxHeight: height }}>
        {msgs.length === 0 && <div className="muted small">{t('Noch keine Nachrichten.')}</div>}
        {msgs.map((m) => (
          <div key={m.id} className={`bubble${m.sender_id === me ? ' mine' : ''}`} onClick={onPick ? () => onPick(m.channel) : undefined} style={onPick ? { cursor: 'pointer' } : undefined}>
            {labelOf?.(m.channel) && <div className="tiny" style={{ fontWeight: 700 }}>{labelOf(m.channel)}</div>}
            <div className="small muted">{m.sender_name ?? '?'} · {new Date(m.at).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })}</div>
            <div>{m.body}</div>
          </div>
        ))}
      </div>
      {err && <div className="notice error">{err}</div>}
      {onSend && (
        <form className="row" onSubmit={(e) => { e.preventDefault(); void send(); }}>
          <input aria-label={t('Nachricht')} value={text} maxLength={2000} onChange={(e) => setText(e.target.value)} placeholder={t('Nachricht')} style={{ flex: 1 }}
            onFocus={() => setTimeout(() => box.current?.scrollTo({ top: box.current.scrollHeight }), 300)} />
          <button type="submit" className="primary" disabled={!text.trim()}>{t('Senden')}</button>
        </form>
      )}
    </div>
  );
}

/** Gelesen-Stand je Chat (nur auf diesem Gerät): höchste gelesene Nachrichten-Nummer. */
function readKey(game: string) { return `hm-chat-read-${game}`; }
function loadRead(game: string): Record<string, number> {
  try { return JSON.parse(localStorage.getItem(readKey(game)) ?? '{}') as Record<string, number>; } catch { return {}; }
}
function saveRead(game: string, v: Record<string, number>) {
  try { localStorage.setItem(readKey(game), JSON.stringify(v)); } catch { /* nur für diese Sitzung */ }
}

/**
 * Chats wie bei WhatsApp: alle Chats untereinander (letzte Nachricht, Zeit, ungelesen). Antippen öffnet den Chat,
 * "‹" führt zurück zur Liste. Spieler haben nur einen Chat (mit den Huntern) und sehen ihn direkt.
 */
export default function Chat({ s, open: openProp, onOpen }: { s: GameState; open?: string | null; onOpen?: (id: string | null) => void }) {
  const chans = channelsFor(s).filter((c) => c.id !== '*');
  const [openState, setOpenState] = useState<string | null>(null);
  // Spieler haben nur einen Chat: der ist immer offen. Hunter: Liste, Antippen öffnet (Zurück-Pfeil führt zur Liste).
  const open = chans.length === 1 ? chans[0].id : openProp !== undefined ? openProp : openState;
  const setOpen = (id: string | null) => (onOpen ? onOpen(id) : setOpenState(id));
  const thread = useRef<HTMLDivElement>(null);
  const [h, setH] = useState<number | null>(null);
  // Höhe bis zur Tastatur (bzw. bis zur Leiste unten): so bleibt das Eingabefeld immer sichtbar.
  useEffect(() => {
    if (!open) return;
    const vv = window.visualViewport;
    const calc = () => {
      const el = thread.current;
      if (!el) return;
      const top = el.getBoundingClientRect().top;
      const bottomOfView = vv ? vv.height + vv.offsetTop : window.innerHeight;
      const bar = document.body.classList.contains('kb-open') ? 0 : (document.querySelector('.tabbar') as HTMLElement | null)?.offsetHeight ?? 0;
      setH(Math.max(220, Math.floor(bottomOfView - top - bar - 10)));
    };
    calc();
    const tm = setTimeout(calc, 350);
    vv?.addEventListener('resize', calc);
    vv?.addEventListener('scroll', calc);
    window.addEventListener('resize', calc);
    document.addEventListener('focusin', calc);
    document.addEventListener('focusout', calc);
    return () => {
      clearTimeout(tm);
      vv?.removeEventListener('resize', calc);
      vv?.removeEventListener('scroll', calc);
      window.removeEventListener('resize', calc);
      document.removeEventListener('focusin', calc);
      document.removeEventListener('focusout', calc);
    };
  }, [open]);
  const [last, setLast] = useState<Msg[]>([]);
  const [read, setRead] = useState<Record<string, number>>(() => loadRead(s.game.id));
  const [me, setMe] = useState<string | null>(null);

  useEffect(() => {
    void db().auth.getUser().then(({ data }) => setMe(data.user?.id ?? null));
  }, []);

  // Für die Liste: die letzten Nachrichten aller Chats (RLS zeigt nur, was man lesen darf).
  useEffect(() => {
    const load = () => void db().from('messages').select('id,channel,sender_id,sender_name,body,at').eq('game_id', s.game.id)
      .order('id', { ascending: false }).limit(400).then(({ data }) => setLast((data ?? []) as Msg[]));
    load();
    const i = setInterval(load, 5000);
    return () => clearInterval(i);
  }, [s.game.id]);

  const cur = chans.find((c) => c.id === open) ?? null;
  // Beim Öffnen und solange offen: alles in diesem Chat als gelesen merken.
  useEffect(() => {
    if (!cur) return;
    const top = last.filter((m) => m.channel === cur.id).reduce((a, m) => Math.max(a, m.id), 0);
    if (top > (read[cur.id] ?? 0)) {
      const next = { ...read, [cur.id]: top };
      setRead(next);
      saveRead(s.game.id, next);
    }
  }, [cur, last]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!chans.length) return <div className="card muted">{t('Im Chat schreiben nur Spieler und Hunter. Wichtige Meldungen findest du unter „Meldungen“.')}</div>;

  if (!cur) {
    const rows = chans.map((c) => {
      // In der Liste zählt nur der eigene Kanal des Chats (sonst stünde "An alle Spieler" bei jedem Spieler-Chat).
      const msgs = last.filter((m) => m.channel === c.id);
      const newest = msgs[0];
      const unread = msgs.filter((m) => m.id > (read[c.id] ?? 0) && m.sender_id !== me).length;
      return { c, newest, unread };
    }).sort((a, b) => (b.newest?.id ?? 0) - (a.newest?.id ?? 0));
    return (
      <div className="card chat-list">
        {rows.map(({ c, newest, unread }) => (
          <button key={c.id} type="button" className="chat-row" onClick={() => setOpen(c.id)}>
            <span className="chat-avatar" aria-hidden="true">{c.id === 'taskforce' ? '🎯' : c.id === 'spieler' ? '📣' : (s.participants.find((p) => `sp:${p.id}` === c.id)?.tag ?? '💬')}</span>
            <span className="spacer" style={{ minWidth: 0, textAlign: 'left' }}>
              <span className="chat-name">{c.label}</span>
              <span className="chat-last">{newest ? `${newest.sender_id === me ? t('Du') : newest.sender_name ?? '?'}: ${newest.body}` : t('Noch keine Nachrichten.')}</span>
            </span>
            <span className="chat-meta">
              {newest && <span className="tiny muted">{new Date(newest.at).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })}</span>}
              {unread > 0 && <span className="chat-unread">{unread}</span>}
            </span>
          </button>
        ))}
      </div>
    );
  }

  const hint = s.me.role === 'spieler'
    ? t('Hier schreibst du mit den Huntern. Alle Hunter lesen mit, ihre Antworten erscheinen hier. Mit anderen Spielern kannst du nicht schreiben.')
    : cur.id === 'taskforce' ? t('Nur das Hunter-Team liest mit.')
    : cur.id === 'spieler' ? t('Alle Spieler lesen diese Nachricht.')
    : t('Dieser Spieler und alle Hunter lesen mit. Seine Antworten erscheinen hier.');
  const labelOf = (c: string) => (c === 'spieler' && cur.id !== 'spieler' ? t('An alle Spieler') : null);
  return (
    <div className="stack">
      <div className="row" style={{ alignItems: 'center' }}>
        {chans.length > 1 && <button type="button" className="ghost" aria-label={t('Zurück zu den Chats')} onClick={() => setOpen(null)}>‹ {t('Chats')}</button>}
        <strong className="spacer">💬 {cur.label} <Info title={cur.label} text={hint} /></strong>
      </div>
      <div ref={thread} style={{ height: h ?? undefined, minHeight: 220 }}>
        <MessageList filter={{ column: 'game_id', value: s.game.id }} channel={cur.read}
          onSend={cur.write ? (b) => api.send(s.game.id, cur.id, b) : null}
          labelOf={labelOf} fill />
      </div>
    </div>
  );
}
