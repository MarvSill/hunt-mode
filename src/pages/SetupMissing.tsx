import { t } from '../i18n';
export default function SetupMissingPage() {
  return (
    <div className="app center-screen">
      <div className="brand">{t('Hunt Mode')}</div>
      <h1>{t('Fast bereit')}</h1>
      <div className="notice warning">
        {t('Die Verbindung zur Datenbank fehlt. Trage')} <code>{t('VITE_SUPABASE_URL')}</code> {t('und')} <code>{t('VITE_SUPABASE_ANON_KEY')}</code>{' '}
        {t('ein (lokal in')} <code>{t('.env')}</code>{t(', beim Hosting als Umgebungsvariablen). Anleitung: README.')}
      </div>
    </div>
  );
}
