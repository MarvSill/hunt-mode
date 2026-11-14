import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
import { AuthProvider } from './lib/auth';
import { useLang } from './i18n';
import { ensureNotifyPermission, isNative, setupNotifyChannel } from './lib/native';
import { installTapFeedback } from './lib/haptics';

// Echte App: Benachrichtigungen erlauben (auch nötig für die Standort-Meldung auf Android 13+).
if (isNative) {
  // Handy-App: die Seite selbst nie zoomen (die Karte zoomt trotzdem mit zwei Fingern).
  document
    .querySelector('meta[name=viewport]')
    ?.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover');
}
if (isNative) void setupNotifyChannel().then(() => ensureNotifyPermission());
installTapFeedback();
// Tastatur offen (Textfeld hat den Fokus): Klasse am body, damit die Leiste unten Platz macht.
const isTextField = (el: EventTarget | null) => el instanceof HTMLTextAreaElement
  || (el instanceof HTMLInputElement && !['checkbox', 'radio', 'button', 'submit', 'range', 'file', 'color'].includes(el.type));
document.addEventListener('focusin', (e) => { if (isTextField(e.target)) document.body.classList.add('kb-open'); });
document.addEventListener('focusout', (e) => { if (isTextField(e.target)) setTimeout(() => { if (!isTextField(document.activeElement)) document.body.classList.remove('kb-open'); }, 50); });
import './styles.css';

// Bei einem Sprachwechsel wird die App neu aufgebaut, damit alle Texte die neue Sprache haben.
function LangRoot() {
  const lang = useLang();
  return <App key={lang} />;
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, '')}>
      <AuthProvider>
        <LangRoot />
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
);
