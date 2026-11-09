import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
import { AuthProvider } from './lib/auth';
import { useLang } from './i18n';
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
