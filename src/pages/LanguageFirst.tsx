import { LANGS, setLang, useLang } from '../i18n';
import Icon from '../components/Icon';

/** Ganz am Anfang (erstes Öffnen auf diesem Gerät): Sprache wählen, bevor irgendetwas anderes kommt. */
export default function LanguageFirst({ onDone }: { onDone: () => void }) {
  const lang = useLang();
  return (
    <div className="app center-screen">
      <div className="hero" style={{ textAlign: 'center' }}>
        <div className="row" style={{ justifyContent: 'center' }}><div className="logo"><Icon name="target" size={26} /></div><span className="brand">Hunt Mode</span></div>
        <h1 style={{ marginTop: 10 }}>🌍</h1>
        <p>Sprache wählen · Choisis ta langue · Choose your language</p>
      </div>
      <div className="stack">
        {LANGS.map((l) => (
          <button key={l.id} type="button" className={`block big${lang === l.id ? ' primary' : ''}`}
            onClick={() => { setLang(l.id); onDone(); }}>
            {l.label}
          </button>
        ))}
      </div>
      <p className="muted small" style={{ textAlign: 'center' }}>Später änderbar im Profil · Modifiable plus tard dans le profil · Change it later in your profile</p>
    </div>
  );
}
