import { useEffect, useRef, useState } from 'react';
import { api } from '../lib/engine';
import { db, errorText } from '../lib/supabase';
import type { GameState } from '../lib/engine';
import { t, locale } from '../i18n';

interface Msg { id: number; channel: string; sender_id: string | null; sender_name: string | null; body: string; at: string }

/**
 * Kanäle im Spiel. Spieler schreiben nie mit anderen Spielern:
 * - Ein Spieler schreibt den Huntern (alle Hunter lesen mit) und liest, was die Hunter allen Spielern schreiben.
 * - Hunter haben ihren eigenen Kanal, schreiben allen Spielern oder einem Spieler.
 */
export function channelsFor(s: GameState): { id: string; label: string; write: boolean }[] {
  const r = s.me.role;
  if (r === 'spieler') {
    return [
      { id: `sp:${s.me.id}`, label: t('Mit den Huntern'), write: true },
      { id: 'spieler', label: t('Von den Huntern an alle'), write: false },
    ];
  }
  if (r === 'hunter') {
    return [
      { id: '*', label: t('Alle Nachrichten'), write: false },
      { id: 'taskforce', label: t('Hunter-Team'), write: true },
      { id: 'spieler', label: t('An alle Spieler'), write: true },
      ...s.participants.filter((p) => p.role === 'spieler').map((p) => ({ id: `sp:${p.id}`, label: t('Mit {0}', { 0: p.name }), write: true })),
    ];
  }
  return [];
}

// Chat über die Tabelle messages (RLS filtert die Kanäle), neue Nachrichten per Realtime.
export function MessageList({ filter, value, channel, onSend, height = '50dvh', labelOf, onPick }: {
  filter: { column: 'game_id' | 'group_id'; value: string };
  value?: string;
  channel: string | null;
  onSend: ((body: string) => Promise<unknown>) | null;
  height?: string;
  /** Bei "Alle Nachrichten": Name des Kanals über jeder Nachricht. */
  labelOf?: (channel: string) => string;
  /** Antippen einer Nachricht öffnet ihren Kanal (zum Antworten). */
  onPick?: (channel: string) => void;
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
      if (channel) q = q.eq('channel', channel);
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
      .channel(`msg:${filter.value}:${channel ?? 'all'}:${value ?? ''}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages', filter: `${filter.column}=eq.${filter.value}` }, (p) => {
        const m = p.new as Msg;
        if (!channel || m.channel === channel) setMsgs((prev) => (prev.some((x) => x.id === m.id) ? prev : [...prev, m]));
      })
      .subscribe();
    return () => {
      clearInterval(poll);
      void db().removeChannel(sub);
    };
  }, [filter.column, filter.value, channel, value]);

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
    <div className="stack">
      <div ref={box} className="chat" style={{ maxHeight: height }}>
        {msgs.length === 0 && <div className="muted small">{t('Noch keine Nachrichten.')}</div>}
        {msgs.map((m) => (
          <div key={m.id} className={`bubble${m.sender_id === me ? ' mine' : ''}`} onClick={onPick ? () => onPick(m.channel) : undefined} style={onPick ? { cursor: 'pointer' } : undefined}>
            {labelOf && <div className="tiny" style={{ fontWeight: 700 }}>{labelOf(m.channel)}</div>}
            <div className="small muted">{m.sender_name ?? '?'} · {new Date(m.at).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })}</div>
            <div>{m.body}</div>
          </div>
        ))}
      </div>
      {err && <div className="notice error">{err}</div>}
      {onSend && (
        <form className="row" onSubmit={(e) => { e.preventDefault(); void send(); }}>
          <input aria-label={t('Nachricht')} value={text} maxLength={2000} onChange={(e) => setText(e.target.value)} placeholder={t('Nachricht')} style={{ flex: 1 }} />
          <button type="submit" className="primary" disabled={!text.trim()}>{t('Senden')}</button>
        </form>
      )}
    </div>
  );
}

export default function Chat({ s }: { s: GameState }) {
  const chans = channelsFor(s);
  const [ch, setCh] = useState(chans[0]?.id ?? '');
  const cur = chans.find((c) => c.id === ch) ?? chans[0];
  if (!cur) return <div className="card muted">{t('Im Chat schreiben nur Spieler und Hunter. Wichtige Meldungen findest du unter „Meldungen“.')}</div>;
  const hint = s.me.role === 'spieler'
    ? (cur.write ? t('Deine Nachricht lesen alle Hunter. Mit anderen Spielern kannst du nicht schreiben.') : t('Hier schreiben nur die Hunter.'))
    : cur.id === '*' ? t('Hier siehst du alle Nachrichten, auch die der Spieler. Tippe eine Nachricht an, um im passenden Chat zu antworten.')
    : cur.id === 'taskforce' ? t('Nur das Hunter-Team liest mit.')
    : cur.id === 'spieler' ? t('Alle Spieler lesen diese Nachricht.')
    : t('Dieser Spieler und alle Hunter lesen mit.');
  return (
    <div className="stack">
      <select aria-label={t('Kanal')} value={cur.id} onChange={(e) => setCh(e.target.value)}>
        {chans.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
      </select>
      <div className="muted small">{hint}</div>
      <MessageList filter={{ column: 'game_id', value: s.game.id }} channel={cur.id === '*' ? null : cur.id}
        onSend={cur.write ? (b) => api.send(s.game.id, cur.id, b) : null}
        labelOf={cur.id === '*' ? (c) => chans.find((x) => x.id === c)?.label ?? c : undefined}
        onPick={cur.id === '*' ? (c) => { if (chans.some((x) => x.id === c && x.write)) setCh(c); } : undefined} />
    </div>
  );
}
