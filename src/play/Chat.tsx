import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { api } from '../lib/engine';
import { db, errorText } from '../lib/supabase';
import type { GameState } from '../lib/engine';
import { t, locale } from '../i18n';

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

/** Nachrichten laden und live halten (RLS filtert die Kanäle). */
function useMessages(filter: { column: 'game_id' | 'group_id'; value: string }, channel: string[] | null, key = '') {
  const [msgs, setMsgs] = useState<Msg[]>([]);
  useEffect(() => {
    const fetchAll = () => {
      let q = db().from('messages').select('id,channel,sender_id,sender_name,body,at').eq(filter.column, filter.value).order('id', { ascending: false }).limit(150);
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
      .channel(`msg:${filter.value}:${channel?.join(',') ?? 'all'}:${key}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `${filter.column}=eq.${filter.value}` }, (p) => {
        const m = p.new as Msg;
        if (!channel || channel.includes(m.channel)) setMsgs((prev) => (prev.some((x) => x.id === m.id) ? prev : [...prev, m]));
      })
      .subscribe();
    return () => {
      clearInterval(poll);
      void db().removeChannel(sub);
    };
  }, [filter.column, filter.value, channel?.join(','), key]); // eslint-disable-line react-hooks/exhaustive-deps
  return msgs;
}

function useMe() {
  const [me, setMe] = useState<string | null>(null);
  useEffect(() => { void db().auth.getUser().then(({ data }) => setMe(data.user?.id ?? null)); }, []);
  return me;
}

const timeOf = (at: string) => new Date(at).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' });

/** Sprechblasen wie bei WhatsApp: eigene rechts, andere links mit Absender (nur beim ersten einer Folge), Uhrzeit in der Blase. */
function Bubbles({ msgs, me, labelOf, onPick }: { msgs: Msg[]; me: string | null; labelOf?: (c: string) => string | null; onPick?: (c: string) => void }) {
  return (
    <>
      {msgs.map((m, i) => {
        const mine = m.sender_id === me;
        const prev = msgs[i - 1];
        const first = !prev || prev.sender_id !== m.sender_id || prev.channel !== m.channel;
        const label = labelOf?.(m.channel);
        return (
          <div key={m.id} className={`bubble${mine ? ' mine' : ''}${first ? ' first' : ''}`} onClick={onPick ? () => onPick(m.channel) : undefined}>
            {label && <div className="bubble-tag">{label}</div>}
            {!mine && first && <div className="bubble-from">{m.sender_name ?? '?'}</div>}
            <span className="bubble-text">{m.body}</span>
            <span className="bubble-time">{timeOf(m.at)}</span>
          </div>
        );
      })}
    </>
  );
}

/** Eingabe unten: wächst mit dem Text (bis 5 Zeilen), Enter sendet, runder Senden-Knopf. */
function Composer({ onSend, onFocus }: { onSend: (body: string) => Promise<unknown>; onFocus?: () => void }) {
  const [text, setText] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ta = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const el = ta.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 120)}px`;
  }, [text]);
  async function send() {
    const body = text.trim();
    if (!body || busy) return;
    setErr(null);
    setBusy(true);
    try {
      await onSend(body);
      setText('');
    } catch (e) {
      setErr(errorText(e));
    } finally {
      setBusy(false);
      if (document.activeElement !== ta.current) ta.current?.focus();
    }
  }
  return (
    <form className="composer" onSubmit={(e) => { e.preventDefault(); void send(); }}>
      {err && <div className="composer-err">{err}</div>}
      <textarea ref={ta} rows={1} aria-label={t('Nachricht')} value={text} maxLength={2000} placeholder={t('Nachricht')}
        onChange={(e) => setText(e.target.value)} onFocus={onFocus}
        onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(); } }} />
      {/* Der Knopf darf dem Textfeld den Fokus nicht wegnehmen, sonst geht die Tastatur beim Senden kurz zu und wieder auf. */}
      <button type="button" className="composer-send" disabled={!text.trim() || busy} aria-label={t('Senden')}
        onPointerDown={(e) => e.preventDefault()} onMouseDown={(e) => e.preventDefault()}
        onTouchEnd={(e) => { e.preventDefault(); void send(); }}
        onClick={() => void send()}>➤</button>
    </form>
  );
}

/** Nachrichtenliste mit Eingabe in einer Karte (Gruppen-Chat ausserhalb des Spiels). */
export function MessageList({ filter, value, channel, onSend, height = '50dvh', labelOf, onPick }: {
  filter: { column: 'game_id' | 'group_id'; value: string };
  value?: string;
  /** Kanäle, deren Nachrichten gezeigt werden (null = alle). */
  channel: string[] | null;
  onSend: ((body: string) => Promise<unknown>) | null;
  height?: string;
  labelOf?: (channel: string) => string | null;
  onPick?: (channel: string) => void;
}) {
  const msgs = useMessages(filter, channel, value);
  const me = useMe();
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => { box.current?.scrollTo({ top: box.current.scrollHeight }); }, [msgs]);
  return (
    <div className="stack">
      <div ref={box} className="chat" style={{ maxHeight: height }}>
        {msgs.length === 0 && <div className="muted small" style={{ margin: 'auto' }}>{t('Noch keine Nachrichten.')}</div>}
        <Bubbles msgs={msgs} me={me} labelOf={labelOf} onPick={onPick} />
      </div>
      {onSend && <Composer onSend={onSend} />}
    </div>
  );
}

/**
 * Ein offener Chat im Spiel, wie bei WhatsApp über den ganzen Bildschirm: oben Kopf mit Zurück, unten das Eingabefeld.
 * Die Höhe folgt dem sichtbaren Bereich: geht die Tastatur auf, sitzt das Eingabefeld direkt darauf, und die neuesten
 * Nachrichten stehen gleich darüber.
 */
function ChatScreen({ s, chan, hint, avatar, onBack }: { s: GameState; chan: ChatThread; hint: string; avatar: string; onBack: () => void }) {
  const msgs = useMessages({ column: 'game_id', value: s.game.id }, chan.read, chan.id);
  const me = useMe();
  const box = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState(() => ({ top: 0, h: window.innerHeight }));
  const [kb, setKb] = useState(false);
  const toBottom = () => requestAnimationFrame(() => box.current?.scrollTo({ top: box.current.scrollHeight }));

  useEffect(() => {
    const vv = window.visualViewport;
    const upd = () => {
      const h = vv ? vv.height : window.innerHeight;
      setVp({ top: vv ? vv.offsetTop : 0, h });
      // Tastatur offen, wenn der sichtbare Bereich deutlich kleiner ist als das Fenster (nur danach, nicht nach dem Fokus:
      // der kann beim Schliessen der Tastatur kurz hinterherhinken).
      setKb(window.innerHeight - h > 120);
      toBottom();
    };
    // Nach Fokus-Wechseln (Tastatur auf/zu) nochmals nachmessen, wenn die Animation fertig ist.
    const later = () => { upd(); setTimeout(upd, 150); setTimeout(upd, 450); };
    upd();
    vv?.addEventListener('resize', upd);
    vv?.addEventListener('scroll', upd);
    window.addEventListener('resize', upd);
    document.addEventListener('focusin', later);
    document.addEventListener('focusout', later);
    document.body.classList.add('no-scroll');
    return () => {
      vv?.removeEventListener('resize', upd);
      vv?.removeEventListener('scroll', upd);
      window.removeEventListener('resize', upd);
      document.removeEventListener('focusin', later);
      document.removeEventListener('focusout', later);
      document.body.classList.remove('no-scroll');
    };
  }, []);
  useEffect(() => { toBottom(); }, [msgs]); // eslint-disable-line react-hooks/exhaustive-deps

  const labelOf = (c: string) => (c === 'spieler' && chan.id !== 'spieler' ? t('An alle Spieler') : null);
  return createPortal(
    <div className={`chat-screen${kb ? ' kb' : ''}`} style={{ top: vp.top, height: vp.h }}>
      <header className="chat-head">
        <button type="button" className="chat-back" aria-label={t('Zurück')} onClick={onBack}>‹</button>
        <span className="chat-avatar" aria-hidden="true">{avatar}</span>
        <div className="spacer" style={{ minWidth: 0 }}>
          <div className="chat-name">{chan.label}</div>
          <div className="chat-sub">{hint}</div>
        </div>
      </header>
      <div ref={box} className="chat-msgs">
        <div className="chat-msgs-inner">
          {msgs.length === 0 && <div className="chat-empty">💬 {t('Noch keine Nachrichten. Schreib die erste!')}</div>}
          <Bubbles msgs={msgs} me={me} labelOf={labelOf} />
        </div>
      </div>
      {chan.write ? <Composer onSend={(b) => api.send(s.game.id, chan.id, b)} onFocus={() => setTimeout(toBottom, 300)} />
        : <div className="composer muted small">{t('Hier kannst du nur lesen.')}</div>}
    </div>,
    document.body,
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
 * Chats wie bei WhatsApp: alle Chats untereinander (letzte Nachricht, Zeit, ungelesen). Antippen öffnet den Chat über
 * den ganzen Bildschirm, "‹" führt zurück. Spieler haben nur einen Chat (mit den Huntern): der öffnet sich direkt.
 */
export default function Chat({ s, open: openProp, onOpen, onLeave }: { s: GameState; open?: string | null; onOpen?: (id: string | null) => void; onLeave?: () => void }) {
  const chans = channelsFor(s).filter((c) => c.id !== '*');
  const [openState, setOpenState] = useState<string | null>(null);
  const open = chans.length === 1 ? chans[0].id : openProp !== undefined ? openProp : openState;
  const setOpen = (id: string | null) => (onOpen ? onOpen(id) : setOpenState(id));
  const [last, setLast] = useState<Msg[]>([]);
  const [read, setRead] = useState<Record<string, number>>(() => loadRead(s.game.id));
  const me = useMe();

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

  const avatarOf = (c: ChatThread) => (c.id === 'taskforce' ? '🎯' : c.id === 'spieler' ? '📣' : s.me.role === 'spieler' ? '🔴' : (s.participants.find((p) => `sp:${p.id}` === c.id)?.tag ?? '💬'));

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
            <span className="chat-avatar" aria-hidden="true">{avatarOf(c)}</span>
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
    ? t('Alle Hunter lesen mit')
    : cur.id === 'taskforce' ? t('Nur das Hunter-Team liest mit')
    : cur.id === 'spieler' ? t('Alle Spieler lesen mit')
    : t('Dieser Spieler und alle Hunter lesen mit');
  return <ChatScreen key={cur.id} s={s} chan={cur} hint={hint} avatar={avatarOf(cur)} onBack={() => (chans.length > 1 ? setOpen(null) : onLeave?.())} />;
}
