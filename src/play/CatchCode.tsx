import { useEffect, useState } from 'react';
import { api } from '../lib/engine';
import { errorText } from '../lib/supabase';
import { t } from '../i18n';

// Rotierender Fang-Code (alle 30 s neu) als grosse Zahl. Der Hunter tippt ihn ein.
export default function CatchCode({ gameId, onClose }: { gameId: string; onClose: () => void }) {
  const [code, setCode] = useState<string | null>(null);
  const [left, setLeft] = useState(0);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const load = async () => {
      try {
        const c = await api.catchCode(gameId);
        setCode(c.code);
        setLeft(c.valid_s);
        timer = setTimeout(load, c.valid_s * 1000 + 300);
      } catch (e) {
        setErr(errorText(e));
      }
    };
    void load();
    return () => clearTimeout(timer);
  }, [gameId]);

  useEffect(() => {
    const i = setInterval(() => setLeft((l) => Math.max(0, l - 1)), 1000);
    return () => clearInterval(i);
  }, []);

  return (
    <div className="overlay" onClick={onClose}>
      <div className="card stack" style={{ width: '100%', maxWidth: 380, textAlign: 'center', background: '#fff', color: '#000' }}>
        <strong>{t('Du wurdest erwischt? Zeig dem Hunter diesen Code.')}</strong>
        {err && <div className="notice error">{err}</div>}
        <div className="code-big" style={{ color: '#000', fontSize: 56, letterSpacing: 6 }} data-testid="catch-code">{code ? `${code.slice(0, 3)} ${code.slice(3)}` : '··· ···'}</div>
        <div className="small">{t('Neuer Code in')} {left} s</div>
        <button className="block" onClick={onClose}>{t('Schliessen')}</button>
      </div>
    </div>
  );
}
