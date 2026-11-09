import { db } from '../lib/supabase';
import { LANGS, setLang, useLang, type Lang } from '../i18n';

/** Sprache wählen: gilt sofort für dieses Gerät und wird im Profil gemerkt. */
export default function LanguagePicker({ userId }: { userId?: string | null }) {
  const lang = useLang();
  function pick(l: Lang) {
    setLang(l);
    if (userId) void db().from('profiles').update({ locale: l }).eq('user_id', userId).then(() => undefined);
  }
  return (
    <div className="chips" role="group" aria-label="Sprache / Langue / Language">
      {LANGS.map((l) => (
        <button key={l.id} type="button" className={`chip${lang === l.id ? ' on' : ''}`} aria-pressed={lang === l.id} onClick={() => pick(l.id)}>
          {l.label}
        </button>
      ))}
    </div>
  );
}
