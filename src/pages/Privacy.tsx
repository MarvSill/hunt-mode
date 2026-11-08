import { useNavigate } from 'react-router-dom';
import Icon from '../components/Icon';

/** Datenschutzerklärung: öffentlich erreichbar (auch für den Play Store). */
export default function PrivacyPage() {
  const navigate = useNavigate();
  return (
    <div className="app">
      <div className="topbar">
        <button className="back ghost" aria-label="Zurück" onClick={() => (window.history.length > 1 ? navigate(-1) : navigate('/'))}><Icon name="back" /></button>
        <h1>Datenschutz</h1>
      </div>
      <div className="card stack small">
        <p style={{ margin: 0 }}>Hunt Mode ist ein privates Spielprojekt. Diese Seite erklärt, welche Daten die App speichert und wofür.</p>
        <strong>Was gespeichert wird</strong>
        <ul style={{ margin: 0, paddingLeft: 20 }}>
          <li>Konto: E-Mail-Adresse und Passwort (verschlüsselt).</li>
          <li>Profil: Benutzername, Anzeigename, Altersbestätigung.</li>
          <li>Notfallkontakt: Name und Telefonnummer. Sichtbar nur für die Spielleitung deines laufenden Spiels und bei einem Notfall für die Hunter.</li>
          <li>Standort: nur während eines laufenden Spiels und nur solange die App offen ist. Nach Spielende werden die Standortdaten automatisch gelöscht; übrig bleibt höchstens die Wiederholung des Spiels für die Teilnehmenden.</li>
          <li>Spielinhalte: Chat-Nachrichten, Meldungen, Fänge und Ergebnisse deiner Spiele.</li>
        </ul>
        <strong>Wer die Daten sieht</strong>
        <p style={{ margin: 0 }}>Nur die Mitspielenden deiner Spiele, je nach Rolle und Spielregeln. Keine Werbung, kein Verkauf, kein Tracking durch Dritte.</p>
        <strong>Wo die Daten liegen</strong>
        <p style={{ margin: 0 }}>Bei Supabase in Frankfurt (EU). Die Karte stammt von OpenStreetMap.</p>
        <strong>Löschen</strong>
        <p style={{ margin: 0 }}>Unter Profil &gt; Konto löschen entfernst du dein Konto mit allen Daten sofort und endgültig. Spiele, die du erstellt hast, werden mitgelöscht.</p>
        <strong>Kontakt</strong>
        <p style={{ margin: 0 }}>Fragen zum Datenschutz: über die Projektseite github.com/MarvSill/manhunt-app.</p>
      </div>
    </div>
  );
}
