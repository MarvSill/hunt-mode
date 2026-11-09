/** Ausführliche Erklärungen hinter den ⓘ-Knöpfen. */

export const ZONE_HELP: Record<string, { title: string; text: string }> = {
  spielfeld: {
    title: 'Spielfeld',
    text: 'Der ganze Bereich, in dem gespielt wird. Spieler dürfen ihn nicht verlassen. Wer rausgeht, bekommt einen Alarm und 1 Minute Zeit, um zurückzukommen; sonst sehen ihn alle Hunter live. Ab dem 3. Verlassen gibt es keinen Countdown mehr, der Standort wird sofort live geteilt. Wer zu lange draussen bleibt, gilt als gefangen. Gefahrenzonen liegen darin. Das Spielfeld kann im Lauf des Spiels kleiner werden (Schritt "Kleiner werden").',
  },
  treffpunkt: {
    title: 'Startpunkt',
    text: 'Hier starten alle, Spieler und Hunter. Beim Start laufen die Spieler los; die Hunter warten am Startpunkt, bis der Vorsprung vorbei ist. Erst dann beginnt die Jagd. Der Punkt muss im Spielfeld liegen.',
  },
  exit: {
    title: 'Fluchtpunkt',
    text: 'Am Schluss müssen die Spieler zum Fluchtpunkt, um zu gewinnen. Du setzt mindestens 4 mögliche Fluchtpunkte. Erst kurz vor Schluss wählt die App zufällig einen davon und verrät ihn nur den Spielern, allen denselben. Die Hunter erfahren ihn nie. Ab diesem Moment dürfen die Spieler auch zusammen sein (kein Nähe-Alarm mehr). Der gestrichelte Kreis zeigt, wie nah man herankommen muss.',
  },
  sperrzone: {
    title: 'Gefahrenzone (Sperrzone)',
    text: 'Orte, die aus Sicherheitsgründen nie betreten werden dürfen: Autobahnen, Bahngleise, Gewässer, Baustellen, Schulen, Privatgelände. Sie sind rot schraffiert mit Warnsymbol. Es gilt dieselbe Regel wie beim Verlassen des Spielfelds: wer hineingeht, bekommt einen Alarm und 1 Minute Zeit, wieder rauszugehen, sonst sehen ihn die Hunter live. Ab dem 3. Mal gibt es keinen Countdown mehr. Wer zu lange drin bleibt, gilt als gefangen. Bei Brücken oder Unterführungen kann "Überqueren erlaubt" eingeschaltet werden.',
  },
};

export const STEP_HELP: Record<string, string> = {
  feld: ZONE_HELP.spielfeld.text,
  treff: ZONE_HELP.treffpunkt.text,
  exit: ZONE_HELP.exit.text,
  klein: 'Das Spielfeld kann im Lauf des Spiels kleiner werden. "Automatisch" verkleinert es um den eingestellten Prozentsatz Richtung Fluchtpunkt. "Selbst zeichnen" lässt dich jede Stufe selbst festlegen. Du stellst ein, alle wie viele Minuten es kleiner wird; alles muss in die Spieldauer passen. Vor jeder Verkleinerung wird angekündigt, und die neue Grenze ist gestrichelt zu sehen. Mit "Zeit zum Rauslaufen" haben Spieler nach der Verkleinerung noch etwas Zeit, bevor sie als ausserhalb gelten.',
  gefahr: ZONE_HELP.sperrzone.text,
  fertig: 'Hier siehst du, ob noch etwas fehlt oder nicht zusammenpasst. Rote Punkte verhindern den Start, gelbe sind nur Hinweise.',
};

export const SETTING_HELP: Record<string, { title: string; text: string }> = {
  roles: { title: 'Spieler und Hunter', text: 'Spieler verstecken sich und versuchen, bis zum Schluss nicht gefangen zu werden. Die Hunter jagen sie gemeinsam als Team, alle unterwegs. Die App regelt alles selbst: Pings und Fänge laufen automatisch. Bei einem Notfall wird das Spiel unterbrochen, und alle werden alarmiert. Auch du als Host wählst eine Rolle und spielst mit (oder schaust zu).' },
  times: { title: 'Zeit', text: 'Das Spiel läuft am Stück von Anfang bis Ende, ohne Pause. Alle Zeiten müssen in die Spieldauer passen: Verkleinerung, Pings, Blitzjagden, Joker und Meldungen. Passt etwas nicht, korrigiert die App den Wert automatisch und sagt dir, was sie geändert hat.' },
  head_start: { title: 'Vorsprung', text: 'So lange haben die Spieler Zeit, sich zu verteilen, bevor die Hunter vom Startpunkt loslaufen dürfen. Der Vorsprung kommt vor der Spieldauer dazu.' },
  pings: { title: 'Pings', text: 'Ein Ping verrät den Huntern den Standort eines Spielers zu einem bestimmten Zeitpunkt (nicht live). Das Intervall sagt, wie oft. Bei jedem Ping klingelt das Handy aller Spieler; jeder Spieler stellt Ton und Vibration im Spiel selbst ein.' },
  speedhunt: { title: 'Blitzjagd', text: 'Eine Jagd auf einen Spieler: die Hunter dürfen seinen Standort mehrmals abfragen. Nur die Hunter starten eine Blitzjagd, und sie hat kein Zeitlimit: sie endet, wenn alle Abfragen gemacht sind oder der Spieler gefangen ist. Im ganzen Spiel gibt es nur wenige Blitzjagden. Bei jeder Blitzjagd klingelt das Handy aller Spieler.' },
  catch: { title: 'Fangen', text: 'Gefangen ist, wessen Fang-Code ein Hunter scannt oder wer die Berührung bestätigt. Der Fluchtpunkt ist das Ziel am Schluss.' },
  joker: { title: 'Joker', text: 'Joker sind Hilfen für die Spieler. Du legst fest, welche Joker es gibt und nach wie viel Spielzeit sie freigeschaltet werden. Dann bekommt jeder Spieler den Joker. Er wirkt erst, wenn der Spieler ihn in der App unter "Aktionen" selbst einsetzt.\n\n• Regeneration: der Spieler wird für eine Zeit nicht gepingt, und die Hunter können in dieser Zeit keine Blitzjagd auf ihn starten. Während einer laufenden Blitzjagd kann man sie nicht einsetzen.\n• Hunter-Standorte: beim Einsetzen bekommt der Spieler einmalig einen Ping aller Hunter, also wo sie in diesem Moment sind (nicht live).' },
  extras: { title: 'Extras', text: 'Verschanzen-Regel: niemand darf sich zu lange in einer Wohnung, einem Haus oder einem anderen nicht öffentlichen Ort verstecken.\n\nNähe-Alarm: kommen sich zwei Spieler zu nahe, bekommen die Hunter beide Standorte.\n\nZuschauer: Personen, die nur zuschauen.\n\nTippe bei jeder Einstellung auf das i für mehr.' },
};

/** Erklärung zu jeder einzelnen Einstellung beim Erstellen (ⓘ neben der Einstellung), nach Beschriftung. */
export const QUICK_HELP: Record<string, string> = {
  'Spieler': 'So viele Personen können sich höchstens verstecken. Spieler versuchen, bis zum Schluss nicht gefangen zu werden.',
  'Hunter': 'So viele Personen jagen höchstens die Spieler. Die Hunter spielen als Team und sehen sich gegenseitig auf der Karte.',
  'Wer bestimmt die Rollen?': 'Ich als Host: du verteilst die Rollen in der Lobby selbst.\nZufall: die App lost aus.\nJeder selbst: jede Person wählt ihre Rolle in der Lobby.',
  'Spieldauer (am Stück)': 'So lange läuft die Jagd, von Anfang bis Ende ohne Pause. Der Vorsprung kommt noch dazu.',
  'Vorsprung der Spieler': 'So lange haben die Spieler nach dem Start Zeit, sich zu verstecken. Erst danach beginnt die Jagd und die ersten Pings kommen.',
  'Hunter warten am Startpunkt während des Vorsprungs': 'Alle starten am selben Punkt. Ist das an, müssen die Hunter dort bleiben, bis der Vorsprung der Spieler vorbei ist. Wer zu früh losgeht, bekommt einen Alarm, zurückzugehen.',
  'Ping alle': 'In diesem Abstand sehen die Hunter, wo jeder Spieler gerade ist (nur diesen Moment, nicht live). Bei jedem Ping klingelt das Handy aller Spieler.',
  'Erster Ping nach dem Vorsprung': 'Wie lange es nach dem Vorsprung dauert, bis die Hunter den ersten Ping bekommen. 0 = sofort nach dem Vorsprung.',
  'Hunter sehen, wann der nächste Ping kommt': 'Ist das an, zeigt die App den Huntern die Uhrzeit des nächsten Pings, damit sie sich bereit machen können.',
  'Blitzjagden erlaubt': 'Bei einer Blitzjagd wählen die Hunter einen Spieler und dürfen seinen Standort mehrmals abfragen. Nur die Hunter starten sie, und sie hat kein Zeitlimit. Das Handy aller Spieler klingelt dabei.',
  'Blitzjagden im ganzen Spiel': 'So oft dürfen die Hunter im ganzen Spiel eine Blitzjagd starten.',
  'Standort-Abfragen pro Blitzjagd': 'So oft dürfen die Hunter während einer Blitzjagd den Standort des gejagten Spielers abfragen. Nach der letzten Abfrage ist die Blitzjagd vorbei.',
  'Wie wird gefangen?': 'QR-Code scannen: der Spieler zeigt seinen Fang-Code, der Hunter scannt ihn mit der App.\nBerühren + bestätigen: der Hunter tippt auf "Gefangen", der Spieler bestätigt. Bestreitet er, entscheidet der GPS-Abstand.',
  'Fluchtpunkt am Schluss (Spieler müssen hin)': 'Kurz vor Schluss wählt die App zufällig einen von mindestens 4 möglichen Fluchtpunkten, die du auf der Karte setzt. Nur die Spieler erfahren ihn, alle denselben; die Hunter nie. Nur wer frei dort ankommt, gewinnt. Ab der Bekanntgabe dürfen die Spieler zusammen sein. Ist das aus, gewinnt jeder Spieler, der bis zum Ende frei bleibt.',
  'Joker im Spiel': 'Joker sind Hilfen für die Spieler. Du legst fest, welche es gibt und wann sie freigeschaltet werden. Wirken tun sie erst, wenn der Spieler sie selbst einsetzt.',
  'Freigeschaltet nach': 'Nach so viel Spielzeit (ab Jagdbeginn) bekommt jeder Spieler diesen Joker. Er kann ihn danach jederzeit einsetzen.',
  'Wirkt so lange': 'So lange wirkt der Joker, nachdem der Spieler ihn eingesetzt hat.',
  'Verschanzen-Regel (nicht zu lange am selben Ort)': 'Damit sich niemand das ganze Spiel in einer Wohnung, einem Haus oder einem anderen nicht öffentlichen Ort versteckt, wo Hunter nicht hinkommen.\n\nSo funktioniert es: Bleibt ein Spieler länger am selben Ort, fragt die App "Bist du verschanzt?" (er kann es auch selbst melden). Ab dann läuft eine Uhr. Ist das Limit erreicht, gilt er als gefangen. Verlässt er den Ort vorher, muss er sich ein Stück davon entfernen und darf nicht sofort zurück.',
  'Alarm, wenn Spieler zusammen laufen': 'Spieler sollen sich allein verstecken. Kommen sich zwei Spieler näher als den eingestellten Abstand:\n\n1. Beide bekommen einen Alarm und sehen, wo der andere ist.\n2. Sie haben die eingestellte Zeit, um sich voneinander zu entfernen.\n3. Sind sie danach immer noch zu nahe, bekommen die Hunter den Ping beider Spieler.\n\nDer Alarm ist erst ein paar Minuten nach Spielbeginn aktiv und ab der Bekanntgabe des Fluchtpunkts aus.',
  'Abstand für den Nähe-Alarm (m)': 'Kommen sich zwei Spieler näher als so viele Meter, gibt es den Nähe-Alarm.',
  'Zeit zum Auseinandergehen': 'So lange haben zwei Spieler nach dem Nähe-Alarm Zeit, sich voneinander zu entfernen. Danach bekommen die Hunter den Ping beider.',
  'ÖV, Taxi und Auto erlaubt': 'Ist das an, dürfen Spieler und Hunter Bus, Tram, Zug, Schiff, Taxi und Auto benutzen. Ist es aus, ist das verboten. Die App prüft das nicht, es gilt Fairplay.',
  'Velo und Trottinett erlaubt': 'Ist das an, dürfen Spieler und Hunter Velo und Trottinett (auch E-Trottinett) benutzen. Ist es aus, ist das verboten. Die App prüft das nicht, es gilt Fairplay.',
  'Zuschauer erlaubt': 'Ist das an, können Personen als Zuschauer dabei sein. Sie spielen nicht mit und sehen die Positionen mit Verzögerung, damit sie nichts verraten können.',
};
