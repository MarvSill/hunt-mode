import { useEffect, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import Icon from '../components/Icon';
import { useAuth } from '../lib/auth';
import { db, errorText } from '../lib/supabase';
import { t } from '../i18n';
import LanguagePicker from '../components/LanguagePicker';
import MapSettingsBox from '../components/MapSettingsBox';
import NativeAppBox from '../components/NativeAppBox';

export default function ProfilePage() {
  const { session, profile, refresh } = useAuth();
  const [displayName, setDisplayName] = useState(profile?.display_name ?? '');
  const [contactName, setContactName] = useState('');
  const [contactPhone, setContactPhone] = useState('');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);
  const [delAsk, setDelAsk] = useState(false);
  const [delText, setDelText] = useState('');
  const [delError, setDelError] = useState<string | null>(null);

  async function deleteAccount() {
    setDelError(null);
    const { error } = await db().rpc('delete_my_account');
    if (error) {
      setDelError(errorText(error));
      return;
    }
    await db().auth.signOut();
  }

  useEffect(() => {
    db()
      .from('profile_private')
      .select('*')
      .maybeSingle()
      .then(({ data }) => {
        if (data) {
          setContactName(data.emergency_contact_name);
          setContactPhone(data.emergency_contact_phone);
        }
      });
  }, []);

  async function save(e: FormEvent) {
    e.preventDefault();
    setMsg(null);
    const userId = session!.user.id;
    const a = await db().from('profiles').update({ display_name: displayName.trim() }).eq('user_id', userId);
    const b = await db()
      .from('profile_private')
      .upsert({ user_id: userId, emergency_contact_name: contactName.trim(), emergency_contact_phone: contactPhone.trim() });
    const err = a.error ?? b.error;
    setMsg(err ? { kind: 'error', text: errorText(err) } : { kind: 'ok', text: t('Gespeichert.') });
    await refresh();
  }

  return (
    <div className="app">
      <div className="topbar">
        <h1>{t('Profil')}</h1>
      </div>
      <div className="card">
        <div className="row">
          <div className="avatar">{profile?.display_name.charAt(0).toUpperCase()}</div>
          <div>
            <div>{profile?.display_name}</div>
            <div className="muted small">@{profile?.username} · {session?.user.email}</div>
          </div>
        </div>
      </div>
      <div className="card stack">
        <strong>{t('Sprache')}</strong>
        <LanguagePicker userId={session?.user.id} />
      </div>
      <div className="card stack">
        <strong>{t('Karte')}</strong>
        <MapSettingsBox />
      </div>
      <div className="card stack">
        <strong>{t('Handy-App')}</strong>
        <NativeAppBox />
      </div>
      <form className="stack" onSubmit={save}>
        <label className="field">
          {t('Anzeigename')}
          <input required maxLength={40} value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
        </label>
        <div className="section-title" style={{ marginBottom: 0 }}>{t('Notfallkontakt')}</div>
        <p className="muted small" style={{ margin: 0 }}>{t('Wird nur bei einem Notfall an die Hunter gezeigt.')}</p>
        <label className="field">
          {t('Name')}
          <input required value={contactName} onChange={(e) => setContactName(e.target.value)} />
        </label>
        <label className="field">
          {t('Telefonnummer')}
          <input required type="tel" value={contactPhone} onChange={(e) => setContactPhone(e.target.value)} />
        </label>
        {msg && <div className={`notice ${msg.kind}`}>{msg.text}</div>}
        <button className="primary block">{t('Speichern')}</button>
      </form>
      <div className="section-title">{t('Hilfe')}</div>
      <Link to="/hilfe" className="game-card"><Icon name="help" /><span className="spacer">{t('So funktioniert Hunt Mode')}</span><Icon name="chevron" /></Link>
      <Link to="/datenschutz" className="game-card"><Icon name="shield" /><span className="spacer">{t('Datenschutz')}</span><Icon name="chevron" /></Link>

      <div className="section-title">{t('Konto')}</div>
      <button className="block" onClick={() => db().auth.signOut()}>
        {t('Abmelden')}
      </button>
      {!delAsk ? (
        <button className="ghost block" style={{ marginTop: 8, color: 'var(--red)' }} onClick={() => setDelAsk(true)}>
          {t('Konto löschen')}
        </button>
      ) : (
        <div className="card stack" style={{ marginTop: 12, borderColor: 'var(--red)' }}>
          <strong>{t('Konto endgültig löschen?')}</strong>
          <span className="small muted">{t('Dein Profil, dein Notfallkontakt, deine Teilnahmen und alle Spiele, die du erstellt hast, werden sofort gelöscht. Das kann man nicht rückgängig machen.')}</span>
          <label className="field">
            {t('Zum Bestätigen LÖSCHEN eingeben')}
            <input value={delText} onChange={(e) => setDelText(e.target.value)} autoCapitalize="characters" />
          </label>
          {delError && <div className="notice error">{delError}</div>}
          <div className="row">
            <button className="ghost" onClick={() => { setDelAsk(false); setDelText(''); }}>{t('Abbrechen')}</button>
            <button className="primary spacer" disabled={delText.trim().toUpperCase() !== t('LÖSCHEN')} onClick={deleteAccount}>{t('Endgültig löschen')}</button>
          </div>
        </div>
      )}
    </div>
  );
}
