import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import Icon from '../components/Icon';
import { appUrl, db, errorText } from '../lib/supabase';
import { t } from '../i18n';
import LanguagePicker from '../components/LanguagePicker';

type Mode = 'login' | 'register' | 'forgot';

export const MIN_PASSWORD = 10;

export default function LoginPage() {
  const [mode, setMode] = useState<Mode>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setInfo(null);
    if (mode === 'register' && password.length < MIN_PASSWORD) {
      setError(t('Das Passwort braucht mindestens {0} Zeichen.', { 0: MIN_PASSWORD }));
      return;
    }
    setBusy(true);
    try {
      const auth = db().auth;
      // Nach der Bestätigung zurück auf dieselbe Seite (z. B. Einladungslink).
      const redirectTo = window.location.href;
      if (mode === 'login') {
        const { error } = await auth.signInWithPassword({ email, password });
        if (error) throw error;
      } else if (mode === 'register') {
        const { data, error } = await auth.signUp({ email, password, options: { emailRedirectTo: redirectTo } });
        if (error) throw error;
        if (!data.session) {
          setInfo(t('Fast geschafft: Wir haben dir einen Bestätigungslink geschickt. Öffne ihn, dann bist du angemeldet.'));
        }
      } else {
        const { error } = await auth.resetPasswordForEmail(email, { redirectTo: appUrl() });
        if (error) throw error;
        setInfo(t('Falls es ein Konto mit dieser E-Mail gibt, ist ein Link zum Zurücksetzen unterwegs.'));
      }
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app center-screen">
      <div style={{ marginBottom: 12 }}><LanguagePicker /></div>
      <div className="hero">
        <div className="row"><div className="logo"><Icon name="target" size={26} /></div><span className="brand">{t('Hunt Mode')}</span></div>
        <h1>{t('Flucht durch die Stadt.')}</h1>
        <p>{t('Spieler verstecken sich, die Hunter jagen sie. Mitten in der Stadt, mit deinen Freunden.')}</p>
        <div className="summary-line" style={{ marginTop: 14 }}>
          <span>{t('🏃 Verstecken')}</span><span>{t('📍 Pings')}</span><span>{t('⚡ Blitzjagden')}</span><span>{t('🏁 Fluchtpunkt')}</span>
        </div>
      </div>

      {mode !== 'forgot' && (
        <div className="tabs" role="tablist">
          <button className={mode === 'login' ? 'active' : ''} onClick={() => setMode('login')}>
            {t('Anmelden')}
          </button>
          <button className={mode === 'register' ? 'active' : ''} onClick={() => setMode('register')}>
            {t('Registrieren')}
          </button>
        </div>
      )}

      <form className="stack" onSubmit={submit}>
        {mode === 'forgot' && <h2>{t('Passwort vergessen')}</h2>}
        <label className="field">
          {t('E-Mail')}
          <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        {mode !== 'forgot' && (
          <label className="field">
            {t('Passwort')} {mode === 'register' && <span>{t('(mindestens')} {MIN_PASSWORD} {t('Zeichen)')}</span>}
            <input
              type="password"
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              required
              minLength={mode === 'register' ? MIN_PASSWORD : undefined}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </label>
        )}
        {error && <div className="notice error">{error}</div>}
        {info && <div className="notice ok">{info}</div>}
        <button className="primary block" disabled={busy}>
          {mode === 'login' ? t('Anmelden') : mode === 'register' ? t('Konto erstellen') : t('Link senden')}
        </button>
        {mode === 'login' && (
          <button type="button" className="ghost" onClick={() => setMode('forgot')}>
            {t('Passwort vergessen?')}
          </button>
        )}
        {mode === 'forgot' && (
          <button type="button" className="ghost" onClick={() => setMode('login')}>
            {t('Zurück zur Anmeldung')}
          </button>
        )}
      </form>
      <p className="muted small" style={{ textAlign: 'center' }}>
        <Link to="/hilfe">{t('So funktioniert’s')}</Link> · <Link to="/datenschutz">{t('Datenschutz')}</Link>
      </p>
    </div>
  );
}
