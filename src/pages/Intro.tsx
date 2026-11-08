import { useState } from 'react';
import { useNavigate } from 'react-router-dom';

const KEY = 'hm-intro-seen';

export function introSeen() {
  try {
    return localStorage.getItem(KEY) === '1';
  } catch {
    return true;
  }
}

const SLIDES: { art: string; title: string; lead: string; points: [string, string, string][] }[] = [
  {
    art: '🏃',
    title: 'Flucht durch die Stadt',
    lead: 'Hunt Mode ist Verstecken in gross: wie in der Serie Manhunt, nur mit deinen Freunden.',
    points: [
      ['🟢', 'Spieler', 'verstecken sich im Spielfeld und wollen bis zum Schluss frei bleiben.'],
      ['🔴', 'Hunter', 'sind die Taskforce. Sie jagen die Spieler und versuchen sie zu fangen.'],
      ['🗺️', 'Spielfeld', 'Ein Gebiet auf der Karte. Wer es verlässt, wird sofort sichtbar.'],
    ],
  },
  {
    art: '📍',
    title: 'Pings verraten dich',
    lead: 'Die Hunter sehen nicht immer, wo du bist, nur in bestimmten Momenten.',
    points: [
      ['⏱️', 'Ping', 'Alle paar Minuten sehen die Hunter deinen Standort von diesem Moment.'],
      ['⚡', 'Speedhunt', 'Kurze Live-Jagd: die Hunter fragen deinen Standort mehrmals ab.'],
      ['🃏', 'Joker', 'Hilfen für Spieler, z. B. eine Zeit lang nicht gepingt werden.'],
    ],
  },
  {
    art: '🏁',
    title: 'Fangen und gewinnen',
    lead: 'Erwischt ist, wer den Fang-Code des Hunters scannt. Wer frei bleibt, gewinnt.',
    points: [
      ['📷', 'Fangen', 'Der Spieler zeigt seinen Code, der Hunter scannt ihn mit der App.'],
      ['🏁', 'Exitpoint', 'Am Schluss müssen die Spieler oft noch zu einem Ziel.'],
      ['🏆', 'Sieg', 'Spieler gewinnen, wenn sie frei ankommen. Hunter, wenn alle gefangen sind.'],
    ],
  },
  {
    art: '🛡️',
    title: 'Sicherheit geht vor',
    lead: 'Es ist ein Spiel. Verkehrsregeln und Gesetze gelten immer.',
    points: [
      ['🚨', 'Notfall', 'Der rote SOS-Knopf alarmiert sofort alle Hunter und die Spielleitung.'],
      ['📞', 'Notrufe', '117 Polizei, 144 Sanität, 112 Notruf. Direkt aus der App anrufbar.'],
      ['🔒', 'Standort', 'Wird nur während eines Spiels geteilt und danach gelöscht.'],
    ],
  },
  {
    art: '🚀',
    title: 'So startest du',
    lead: 'In drei Schritten zum ersten Spiel.',
    points: [
      ['1️⃣', 'Spiel erstellen', 'Vorlage wählen und Name eingeben. Alles andere ist schon eingestellt.'],
      ['2️⃣', 'Karte zeichnen', 'Spielfeld mit einem Tipp setzen, den Rest macht die App.'],
      ['3️⃣', 'Freunde einladen', 'Den 6-stelligen Code teilen, Rollen verteilen, starten.'],
    ],
  },
];

/** Einführung beim ersten Start; später unter Profil > So funktioniert's. */
export default function IntroPage({ onDone }: { onDone?: () => void }) {
  const [i, setI] = useState(0);
  const navigate = useNavigate();
  const slide = SLIDES[i];
  const last = i === SLIDES.length - 1;

  function finish() {
    try {
      localStorage.setItem(KEY, '1');
    } catch {
      // ohne Speicher: kommt nächstes Mal wieder
    }
    if (onDone) onDone();
    else if (window.history.length > 1) navigate(-1);
    else navigate('/');
  }

  return (
    <div className="intro">
      <div className="row">
        <span className="brand">Hunt Mode</span>
        <span className="spacer" />
        <button className="ghost small" onClick={finish}>{onDone ? 'Überspringen' : 'Schliessen'}</button>
      </div>
      <div className="intro-art" aria-hidden="true">{slide.art}</div>
      <h1>{slide.title}</h1>
      <p className="lead">{slide.lead}</p>
      <ul>
        {slide.points.map(([icon, title, text]) => (
          <li key={title}>
            <span style={{ fontSize: 22 }} aria-hidden="true">{icon}</span>
            <span><b>{title}</b><span className="muted small">{text}</span></span>
          </li>
        ))}
      </ul>
      <div className="spacer" />
      <div className="dots" aria-label={`Seite ${i + 1} von ${SLIDES.length}`}>
        {SLIDES.map((_, k) => <span key={k} className={k === i ? 'on' : ''} />)}
      </div>
      <div className="row" style={{ flexWrap: 'nowrap' }}>
        {i > 0 && <button style={{ flex: 1 }} onClick={() => setI(i - 1)}>Zurück</button>}
        <button className="primary" style={{ flex: 2 }} onClick={() => (last ? finish() : setI(i + 1))}>
          {last ? 'Los geht’s' : 'Weiter'}
        </button>
      </div>
    </div>
  );
}
