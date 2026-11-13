import { lazy } from '../i18n';
/** Ausführliche Erklärungen hinter den ⓘ-Knöpfen. */

// Deutscher Ausgangstext; übersetzt wird erst beim Lesen (lazy).
const ZONE_HELP_DE: Record<string, { title: string; text: string }> = {
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
    text: 'Am Schluss müssen die Spieler zum Fluchtpunkt, um zu gewinnen. Du setzt mindestens 4 mögliche Fluchtpunkte, alle in der innersten Zone (dem Spielfeld der letzten Phase), damit sie am Ende erreichbar sind. Erst kurz vor Schluss (zur eingestellten Zeit) wählt die App zufällig einen davon und verrät ihn nur den Spielern, allen denselben. Die Hunter erfahren ihn nie. Nutzbar ist er aber erst ab der eingestellten Freigabe kurz vor Schluss: gerettet ist, wer zwischen Freigabe und Spielende im gestrichelten Kreis ist. Setze zuerst die Verkleinerung (Schritt "Kleiner werden"), damit klar ist, wie klein die innerste Zone wird.',
  },
  sperrzone: {
    title: 'Gefahrenzone (Sperrzone)',
    text: 'Nur aussergewöhnlich gefährliche Orte, die nie betreten werden dürfen: Autobahnen, Bahngleise und grosse Gewässer (Fluss, See). Unterführungen, Brücken und Stege gehören nicht dazu. Strassen, Schulen, kleine Gewässer, Baustellen, Bahnhöfe oder Einkaufszentren sind keine Gefahrenzonen: dort passt jeder selbst auf sich auf, jeder trägt die Verantwortung für sich. Gefahrenzonen sind rot schraffiert mit Warnsymbol. Es gilt dieselbe Regel wie beim Verlassen des Spielfelds: wer hineingeht, bekommt einen Alarm und 1 Minute Zeit, wieder rauszugehen, sonst sehen ihn die Hunter live. Ab dem 3. Mal gibt es keinen Countdown mehr. Wer zu lange drin bleibt, gilt als gefangen. Wo man eine Gefahrenzone gefahrlos überqueren kann, lässt sich "Überqueren erlaubt" einschalten.',
  },
};
export const ZONE_HELP = lazy(ZONE_HELP_DE);

export const STEP_HELP: Record<string, string> = lazy({
  feld: ZONE_HELP_DE.spielfeld.text,
  treff: ZONE_HELP_DE.treffpunkt.text,
  exit: ZONE_HELP_DE.exit.text,
  klein: 'Das Spielfeld kann im Lauf des Spiels kleiner werden. "Automatisch" verkleinert es um den eingestellten Prozentsatz Richtung Fluchtpunkt. "Selbst zeichnen" lässt dich jede Stufe selbst festlegen. Du stellst ein, alle wie viele Minuten es kleiner wird; alles muss in die Spielzeit passen. Vor jeder Verkleinerung wird angekündigt, und die neue Grenze ist gestrichelt zu sehen.',
  gefahr: ZONE_HELP_DE.sperrzone.text,
  fertig: 'Hier siehst du, ob noch etwas fehlt oder nicht zusammenpasst. Rote Punkte verhindern den Start, gelbe sind nur Hinweise.',
});

export const SETTING_HELP: Record<string, { title: string; text: string }> = lazy({
  roles: { title: 'Spieler und Hunter', text: 'Spieler verstecken sich und versuchen, bis zum Schluss nicht gefangen zu werden. Die Hunter jagen sie gemeinsam als Team, alle unterwegs. Die App regelt alles selbst: Pings und Fänge laufen automatisch. Bei einem Notfall wird das Spiel unterbrochen, und alle werden alarmiert. Auch du als Host wählst eine Rolle und spielst mit (oder schaust zu).' },
  times: { title: 'Zeit', text: 'Das Spiel läuft am Stück von Anfang bis Ende. Pausieren kann nur der Host, dann steht die Zeit still. Die Spielzeit gilt alles inklusive: sie zählt ab dem Start, der Vorsprung ist ein Teil davon, und das Spiel endet pünktlich. Alle Zeiten müssen hineinpassen: Verkleinerung, Pings, Blitzjagden, Joker und Meldungen. Passt etwas nicht, korrigiert die App den Wert automatisch und sagt dir, was sie geändert hat.' },
  head_start: { title: 'Vorsprung', text: 'So lange haben die Spieler Zeit, sich zu verteilen, bevor die Hunter vom Startpunkt loslaufen dürfen. Der Vorsprung ist ein Teil der Spielzeit.' },
  pings: { title: 'Pings', text: 'Ein Ping verrät den Huntern den Standort eines Spielers zu einem bestimmten Zeitpunkt (nicht live). Das Intervall sagt, wie oft. Bei jedem Ping klingelt das Handy aller Spieler; jeder Spieler stellt Ton und Vibration im Spiel selbst ein.' },
  speedhunt: { title: 'Blitzjagd', text: 'Eine Jagd auf einen Spieler: die Hunter dürfen seinen Standort mehrmals abfragen. Nur die Hunter starten eine Blitzjagd, und sie hat kein Zeitlimit: sie endet, wenn alle Abfragen gemacht sind oder der Spieler gefangen ist. Im ganzen Spiel gibt es nur wenige Blitzjagden. Bei jeder Blitzjagd klingelt das Handy aller Spieler.' },
  catch: { title: 'Fangen', text: 'Gefangen ist, wessen Fang-Code ein Hunter eingibt oder wer den gemeldeten Fang bestätigt. Der Fluchtpunkt ist das Ziel am Schluss.' },
  joker: { title: 'Joker', text: 'Joker sind Hilfen für die Spieler. Du legst fest, welche Joker es gibt und nach wie viel Spielzeit sie freigeschaltet werden. Dann bekommt jeder Spieler den Joker. Er wirkt erst, wenn der Spieler ihn in der App unter "Aktionen" selbst einsetzt.\n\n• Regeneration: der Spieler wird für eine Zeit nicht gepingt, und die Hunter können in dieser Zeit keine Blitzjagd auf ihn starten. Während einer laufenden Blitzjagd kann man sie nicht einsetzen.\n• Hunter-Standorte: beim Einsetzen bekommt der Spieler einmalig einen Ping aller Hunter, also wo sie in diesem Moment sind (nicht live).\n• Nähe-Radar: eine eingestellte Zeit lang sieht der Spieler, ob ein Hunter näher als der eingestellte Abstand ist (z. B. 500 m). Wo der Hunter ist, sieht er nicht. Jedes Mal, wenn ein Hunter nah kommt, klingelt das Handy laut. Solange er nah ist, steht das in der App; ist er wieder weg, steht dort, dass kein Hunter nah ist.' },
  extras: { title: 'Extras', text: 'Verschanzen-Regel: niemand darf sich zu lange in einer Wohnung, einem Haus oder einem anderen nicht öffentlichen Ort verstecken.\n\nZuschauer: Personen, die nur zuschauen.\n\nTippe bei jeder Einstellung auf das i für mehr.' },
});

/** Erklärung zu jeder einzelnen Einstellung beim Erstellen (ⓘ neben der Einstellung), nach Beschriftung. */
export const QUICK_HELP: Record<string, string> = {
  'Spieler': 'So viele Personen können sich höchstens verstecken. Spieler versuchen, bis zum Schluss nicht gefangen zu werden.',
  'Hunter': 'So viele Personen jagen höchstens die Spieler. Die Hunter spielen als Team und sehen sich gegenseitig auf der Karte.',
  'Wer bestimmt die Rollen?': 'Ich als Host: du verteilst die Rollen in der Lobby selbst.\nZufall: die App lost aus.\nJeder selbst: jede Person wählt ihre Rolle in der Lobby.',
  'Spielzeit (alles inklusive)': 'So lange dauert das ganze Spiel, vom Start bis zum Ende, am Stück und ohne Nachspielzeit (eine Pause des Hosts wird angehängt). Der Vorsprung ist ein Teil davon: bei 20 min Spielzeit und 5 min Vorsprung wird 15 min gejagt.',
  'Vorsprung der Spieler': 'So lange haben die Spieler nach dem Start Zeit, sich zu verstecken. Erst danach beginnt die Jagd und die ersten Pings kommen.',
  'Hunter warten am Startpunkt während des Vorsprungs': 'Alle starten am selben Punkt. Ist das an, müssen die Hunter dort bleiben, bis der Vorsprung der Spieler vorbei ist. Wer zu früh losgeht, bekommt einen Alarm, zurückzugehen.',
  'Ping alle': 'In diesem Abstand sehen die Hunter, wo jeder Spieler gerade ist (nur diesen Moment, nicht live). Die Spieler sehen die Pings der anderen Spieler auch, damit sie sich besser verteilen können. Bei jedem Ping klingelt das Handy aller Spieler.',
  'Hunter sehen, wann der nächste Ping kommt': 'Ist das an, zeigt die App den Huntern die Uhrzeit des nächsten Pings, damit sie sich bereit machen können.',
  'Blitzjagden erlaubt': 'Bei einer Blitzjagd wählen die Hunter einen Spieler und dürfen seinen Standort mehrmals abfragen. Nur die Hunter starten sie, und sie hat kein Zeitlimit. Das Handy aller Spieler klingelt dabei.',
  'Blitzjagden im ganzen Spiel': 'So oft dürfen die Hunter im ganzen Spiel eine Blitzjagd starten.',
  'Standort-Abfragen pro Blitzjagd': 'So oft dürfen die Hunter während einer Blitzjagd den Standort des gejagten Spielers abfragen. Nach der letzten Abfrage ist die Blitzjagd vorbei.',
  'Wie wird gefangen?': 'Es gibt immer beide Wege, jeder kann ohne den anderen benutzt werden.\nZahlencode: der Spieler zeigt seinen 6-stelligen Fang-Code, der Hunter tippt ihn ein. Dann gilt der Fang sofort.\nFang melden: der Hunter tippt auf den gefangenen Spieler, der Spieler bestätigt oder lehnt ab. Lehnt er ab, gilt der Fang nicht.',
  'Fluchtpunkt am Schluss (Spieler müssen hin)': 'Kurz vor Schluss wählt die App zufällig einen von mindestens 4 möglichen Fluchtpunkten, die du auf der Karte setzt. Nur die Spieler erfahren ihn, alle denselben; die Hunter nie. Nur wer frei dort ankommt, gewinnt. Ist das aus, gewinnt jeder Spieler, der bis zum Ende frei bleibt.',
  'Fluchtpunkt bekannt ab (vor Schluss)': 'So viele Minuten vor Spielende erfahren die Spieler, welcher Fluchtpunkt es ist. Nutzen können sie ihn aber erst ab der Freigabe.',
  'Fluchtpunkt nutzbar ab (vor Schluss)': 'Erst so viele Minuten vor Spielende ist der Fluchtpunkt offen. Gerettet ist, wer zwischen der Freigabe und dem Spielende im Kreis ist. Wer früher dort steht, zählt erst ab der Freigabe. So kann niemand gleich nach der Bekanntgabe flüchten.',
  'Joker im Spiel': 'Joker sind Hilfen für die Spieler. Du legst fest, welche es gibt und wann sie freigeschaltet werden. Wirken tun sie erst, wenn der Spieler sie selbst einsetzt.',
  'Freigeschaltet nach (ab Jagdbeginn)': 'Nach so viel Zeit ab Jagdbeginn (Ende des Vorsprungs) bekommt jeder Spieler diesen Joker. Er kann ihn danach jederzeit einsetzen.',
  'Wirkt so lange': 'So lange wirkt der Joker, nachdem der Spieler ihn eingesetzt hat.',
  'Verschanzen-Regel (nicht zu lange am selben Ort)': 'Damit sich niemand das ganze Spiel in einer Wohnung, einem Haus oder einem anderen nicht öffentlichen Ort versteckt, wo Hunter nicht hinkommen.\n\nSo funktioniert es: Bleibt ein Spieler länger am selben Ort, fragt die App "Bist du verschanzt?" (er kann es auch selbst melden). Ab dann läuft eine Uhr. Ist das Limit erreicht, gilt er als gefangen. Verlässt er den Ort vorher, muss er sich ein Stück davon entfernen.',
  'ÖV, Taxi und Auto erlaubt': 'Ist das an, dürfen Spieler und Hunter Bus, Tram, Zug, Schiff, Taxi und Auto benutzen. Ist es aus, ist das verboten. Die App prüft das nicht, es gilt Fairplay.',
  'Velo und Trottinett erlaubt': 'Ist das an, dürfen Spieler und Hunter Velo und Trottinett (auch E-Trottinett) benutzen. Ist es aus, ist das verboten. Die App prüft das nicht, es gilt Fairplay.',
  'Zuschauer erlaubt': 'Ist das an, können Personen als Zuschauer dabei sein. Sie spielen nicht mit und sehen die Positionen mit Verzögerung, damit sie nichts verraten können.',
};
