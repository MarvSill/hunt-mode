/** Ausführliche Erklärungen hinter den ⓘ-Knöpfen. */

export const ZONE_HELP: Record<string, { title: string; text: string }> = {
  spielfeld: {
    title: 'Spielfeld',
    text: 'Der ganze Bereich, in dem gespielt wird. Spieler dürfen ihn nicht verlassen: wer draussen ist, wird nach kurzer Toleranz live an alle Hunter gezeigt, und nach dem Limit gibt es die eingestellte Folge (z. B. Disqualifikation). Alle anderen Zonen liegen innerhalb. Das Spielfeld kann im Lauf des Spiels kleiner werden (Schritt "Kleiner werden").',
  },
  treffpunkt: {
    title: 'Treffpunkt',
    text: 'Hier treffen sich alle vor dem Start. Von hier laufen die Spieler los, sobald der Vorsprung beginnt. Der Punkt muss im Spielfeld liegen und weit genug vom HQ der Hunter entfernt sein (gestrichelter Kreis um das HQ).',
  },
  hq: {
    title: 'HQ (Hauptquartier der Hunter)',
    text: 'Ein Punkt, an dem die Hunter während des Vorsprungs warten. Erst wenn die Jagd beginnt, dürfen sie los. Der gestrichelte Kreis zeigt den Mindestabstand zum Treffpunkt: der Treffpunkt muss ausserhalb davon liegen, damit die Spieler fair starten.',
  },
  exit: {
    title: 'Fluchtpunkt',
    text: 'Am Schluss müssen die Spieler zum Fluchtpunkt, um zu gewinnen. Du kannst mehrere Kandidaten setzen; einer wird zufällig gewählt und erst kurz vor Schluss verraten. Der gestrichelte Kreis zeigt, wie nah man herankommen muss.',
  },
  sperrzone: {
    title: 'Gefahrenzone (Sperrzone)',
    text: 'Orte, die aus Sicherheitsgründen nie betreten werden dürfen: Autobahnen, Bahngleise, Gewässer, Baustellen, Schulen, Privatgelände. Sie sind rot schraffiert mit Warnsymbol. Wer hineingeht, wird sofort gewarnt; bleibt man drin, gibt es eine Verwarnung. Bei Brücken oder Unterführungen kann "Überqueren erlaubt" eingeschaltet werden.',
  },
  sicher: {
    title: 'Schutzzone',
    text: 'Hier darf niemand gefangen werden, z. B. ein Café oder eine Toilette. Spieler werden in der Schutzzone weiter gepingt, aber Hunter dürfen sie dort nicht fangen.',
  },
  kern: {
    title: 'Kern-Gebiet',
    text: 'Ein Gebiet mit häufigeren Pings. Wer sich hier versteckt, wird öfter geortet. So lohnt es sich, in Bewegung zu bleiben oder ins Aussengebiet zu gehen.',
  },
  aussen: {
    title: 'Aussen-Gebiet',
    text: 'Ein Gebiet mit eigenem Ping-Intervall, meist seltener als im Kern. Gut für weite Gebiete am Rand des Spielfelds.',
  },
  center: {
    title: 'Center',
    text: 'Ein besonderes Gebiet mit eigenen Ping-Regeln, z. B. ein dichtes Stadtzentrum. Auf Wunsch sind dort keine Fahrzeuge erlaubt.',
  },
  sektion: {
    title: 'Sektion',
    text: 'Ein Teilgebiet. Wenn "Eigene Sektion pro Spieler" aktiv ist, bekommt jeder Spieler eine Sektion und darf sie nicht verlassen. Wer seine Sektion verlässt, wird live an alle Hunter gezeigt.',
  },
  startzone: {
    title: 'Startzone',
    text: 'Gemeinsamer Bereich in Spielen mit Sektionen: hier dürfen alle Spieler sein, z. B. rund um den Treffpunkt.',
  },
};

export const STEP_HELP: Record<string, string> = {
  feld: ZONE_HELP.spielfeld.text,
  treff: ZONE_HELP.treffpunkt.text,
  hq: ZONE_HELP.hq.text,
  exit: ZONE_HELP.exit.text,
  klein: 'Das Spielfeld kann im Lauf des Spiels kleiner werden. "Automatisch" verkleinert es um den eingestellten Prozentsatz Richtung Fluchtpunkt. "Selbst zeichnen" lässt dich jede Stufe selbst festlegen. Du stellst ein, alle wie viele Minuten es kleiner wird; alles muss in die Spieldauer passen. Vor jeder Verkleinerung wird angekündigt, und die neue Grenze ist gestrichelt zu sehen. Mit "Zeit zum Rauslaufen" haben Spieler nach der Verkleinerung noch etwas Zeit, bevor sie als ausserhalb gelten.',
  gefahr: ZONE_HELP.sperrzone.text,
  mehr: 'Zusätzliche Gebiete mit eigenen Regeln: Schutzzonen (kein Fangen), Kern- und Aussengebiete (andere Ping-Intervalle), Center und Sektionen. Alle müssen im Spielfeld liegen; was hinausragt, wird beim Zeichnen automatisch abgeschnitten.',
  fertig: 'Hier siehst du, ob noch etwas fehlt oder nicht zusammenpasst. Rote Punkte verhindern den Start, gelbe sind nur Hinweise.',
};

export const SETTING_HELP: Record<string, { title: string; text: string }> = {
  roles: { title: 'Spieler und Hunter', text: 'Spieler verstecken sich und versuchen, bis zum Schluss nicht gefangen zu werden. Die Hunter jagen sie als Team. Die App regelt alles selbst: Pings, Strafen und Fänge laufen automatisch, und ein Notfall geht sofort an alle Hunter. Auch du als Host wählst eine Rolle und spielst mit (oder schaust zu).' },
  times: { title: 'Zeit', text: 'Das Spiel läuft am Stück von Anfang bis Ende, ohne Pause. Alle Zeiten müssen in die Spieldauer passen: Verkleinerung, Pings, Blitzjagden, Joker und Meldungen. Passt etwas nicht, korrigiert die App den Wert automatisch und sagt dir, was sie geändert hat.' },
  head_start: { title: 'Vorsprung', text: 'So lange haben die Spieler Zeit, sich zu verteilen, bevor die Hunter das HQ verlassen dürfen. Der Vorsprung kommt vor der Spieldauer dazu.' },
  pings: { title: 'Pings', text: 'Ein Ping verrät den Huntern den Standort eines Spielers zu einem bestimmten Zeitpunkt (nicht live). Das Intervall sagt, wie oft. Im Kern-Gebiet kann öfter gepingt werden. Mit "Ungenauigkeit" wird der Punkt etwas verschoben.' },
  speedhunt: { title: 'Blitzjagd', text: 'Eine kurze Live-Jagd: die Hunter dürfen den Standort eines Spielers mehrmals kurz hintereinander abfragen. Im ganzen Spiel gibt es nur wenige Blitzjagden.' },
  catch: { title: 'Fangen', text: 'Gefangen ist, wessen Fang-Code ein Hunter scannt oder wer die Berührung bestätigt. Der Fluchtpunkt ist das Ziel am Schluss.' },
  joker: { title: 'Joker', text: 'Joker sind Hilfen für die Spieler. Du legst fest, welche Joker es gibt und nach wie viel Spielzeit sie freigeschaltet werden. Dann bekommt jeder Spieler den Joker und setzt ihn in der App unter "Aktionen" selbst ein.\n\n• Regeneration: der Spieler wird für eine Zeit nicht gepingt.\n• Hunter-Standorte: der Spieler sieht 5 Minuten lang, wo die Hunter sind.\n• Schutzschild: der Spieler kann für eine Zeit nicht gefangen werden.' },
  extras: { title: 'Extras', text: 'Budget: Spieler haben Geld fürs ganze Spiel; jeder Kauf verrät ihren Standort. Verschanzen: niemand darf zu lange am selben Ort bleiben. Nähe-Alarm: Spieler, die zusammen laufen, werden gemeldet.' },
};
