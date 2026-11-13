import { useNavigate } from 'react-router-dom';
import Icon from '../components/Icon';
import { t } from '../i18n';

/** Datenschutzerklärung: öffentlich erreichbar (auch für den Play Store). */
export default function PrivacyPage() {
  const navigate = useNavigate();
  return (
    <div className="app">
      <div className="topbar">
        <button className="back ghost" aria-label={t('Zurück')} onClick={() => (window.history.length > 1 ? navigate(-1) : navigate('/'))}><Icon name="back" /></button>
        <h1>{t('Datenschutz')}</h1>
      </div>
      <div className="card stack small">
        <p style={{ margin: 0 }}>{t('Hunt Mode ist ein privates Spielprojekt. Diese Seite erklärt, welche Daten die App speichert und wofür.')}</p>
        <strong>{t('Was gespeichert wird')}</strong>
        <ul style={{ margin: 0, paddingLeft: 20 }}>
          <li>{t('Konto: E-Mail-Adresse und Passwort (verschlüsselt).')}</li>
          <li>{t('Profil: Benutzername, Anzeigename, Altersbestätigung.')}</li>
          <li>{t('Notfallkontakt: Name und Telefonnummer. Sichtbar nur bei einem Notfall, für die Hunter deines Spiels.')}</li>
          <li>{t('Standort: nur während eines laufenden Spiels, alle 5 Sekunden. Der Weg wird aufgezeichnet, damit die Teilnehmenden ihn nach Spielende in der Wiederholung ansehen können. Die Standortdaten bleiben gespeichert; wird das Spiel gelöscht, werden sie sofort mit gelöscht.')}</li>
          <li>{t('Spielinhalte: Chat-Nachrichten, Meldungen, Fänge und Ergebnisse deiner Spiele.')}</li>
        </ul>
        <strong>{t('Wer die Daten sieht')}</strong>
        <p style={{ margin: 0 }}>{t('Nur die Mitspielenden deiner Spiele, je nach Rolle und Spielregeln. Keine Werbung, kein Verkauf, kein Tracking durch Dritte.')}</p>
        <strong>{t('Wo die Daten liegen')}</strong>
        <p style={{ margin: 0 }}>{t('Bei Supabase in Frankfurt (EU). Die Karte stammt von OpenStreetMap.')}</p>
        <strong>{t('Löschen')}</strong>
        <p style={{ margin: 0 }}>{t('Unter Profil &gt; Konto löschen entfernst du dein Konto mit allen Daten sofort und endgültig. Spiele, die du erstellt hast, werden mitgelöscht.')}</p>
        <strong>{t('Kontakt')}</strong>
        <p style={{ margin: 0 }}>{t('Fragen zum Datenschutz: über die Projektseite github.com/MarvSill/hunt-mode.')}</p>
      </div>
    </div>
  );
}
