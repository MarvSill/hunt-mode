# 0. So benutzt du dieses Dokument

Dieses Dokument ist die vollständige fachliche und technische Spezifikation für eine App, mit der man das urbane Verfolgungsspiel **Manhunt** (bekannt aus der YouTube-Serie von Manhunt Media, manhunt.at) in beliebiger Grösse selbst spielen kann. Es ist so geschrieben, dass eine KI (oder ein Entwicklerteam) daraus ohne Rückfragen eine fertige, moderne App bauen kann.

> Anweisung an die KI, die dieses Dokument erhält: Behandle dieses Dokument als einzige Quelle der Wahrheit. Setze alle Kapitel um. Wo etwas als "MUSS" markiert ist, ist es Pflicht. Wo etwas als "SOLL" markiert ist, setze es um, sofern es technisch möglich ist. Jeder Zahlenwert in den Regeln ist ein **konfigurierbarer Parameter** (Kapitel 8), niemals fest im Code. Die Standardwerte stammen aus der Originalserie (Preset "New York", Kapitel 9). Erfinde keine zusätzlichen Regeln; wenn etwas fehlt, nimm die in Kapitel 14 beschriebene Konfliktregel oder den dokumentierten Standardwert. Die Kapitel 20 bis 25 (Konten, Gruppen, Karten-Setup, Ortung und Pings, Spielbarkeits-Check, Konfigurations-Validierung) wurden in Version 1.1 ergänzt und sind genauso verbindlich wie die übrigen Kapitel. Am Ende (Anhang C) steht ein fertiger Start-Prompt.

Begriffe: **MUSS** = Pflicht. **SOLL** = dringend empfohlen. **KANN** = optional. Alle Zeiten sind in der Zeitzone des Spiels (Einstellung game.timezone).

# 1. Produktvision

Die App macht aus jeder Stadt, jedem Quartier oder jedem Park ein Manhunt-Spielfeld. Eine Gruppe Spieler (die Gejagten) flieht vor einer Taskforce (den Huntern). Die App ersetzt die Spielleitung, die GPS-Tracker, die Telegram-Gruppen und das Regelwerk der Serie: Sie ortet die Spieler, gibt Pings nach den Regeln an die Hunter weiter, verwaltet Speedhunts, Joker, Boni, Challenges, Budget, Zonen, Strafen, Fänge und das Finale am Exitpoint.

Kernversprechen:
- **Spielbar wie die echte Serie**: Mit dem Preset "Original" laufen alle Regeln exakt wie in der Staffel New York (oder Wien bzw. Bangkok).
- **Alles einstellbar**: Anzahl Spieler und Hunter, Spieldauer (90 Minuten bis 96 Stunden und mehr), Länge eines "Spieltags", Ping-Intervalle, Anzahl Speedhunts, Abfragen pro Speedhunt, Budget, Joker, Boni, Challenges, Zonen, Strafen, Fangmethode, Exitpoint und jede einzelne Regel lässt sich ein- oder ausschalten.
- **Skalierbar in der Zeit**: Ein "Spieltag" muss nicht 24 Stunden dauern. Bei einem 3-Stunden-Spiel kann ein Spieltag z. B. 45 Minuten lang sein, und alle Tagesregeln (Budget-Auffüllung, neuer Joker, Spielfeldverkleinerung, Speedhunt-Kontingent) laufen entsprechend schneller.
- **Automatische oder menschliche Spielleitung**: Die App kann die Spielleitung vollständig automatisch übernehmen. Optional übernimmt eine Person die Rolle Spielleitung und kann jederzeit eingreifen.
- **Sicher**: Notfallknopf, Pausenfunktion, Sperrzonen, Akku- und Signalüberwachung, Datenschutz.

# 2. Quellen und Abgrenzung

Ausgewertete Quellen (Stand 08.10.2026):
- Offizielles Regelwerk auf manhunt.at (Seite "Regelwerk", Abschnitte Staffel 1 Wien, Staffel 2 Bangkok, Staffel 3 New York).
- Spieler- und Hunter-Seite der Staffel New York auf manhunt.at.
- Episodenlisten und Folgenbeschreibungen aller drei Staffeln (TheTVDB, kinoundco.de) sowie Artikel von GIGA, mein-mmo, Promiflash, praxistipp, everybodywiki und benefit-blog.
- Die YouTube-Videos selbst waren aus der Arbeitsumgebung nicht direkt abspielbar (YouTube blockierte den Abruf). Mechaniken aus den Folgen wurden deshalb aus offiziellen Folgenbeschreibungen und Presseartikeln übernommen (Anhang B).

Bekannte Lücken und Unklarheiten:
- Staffel 4 (Saigon, angekündigt im September 2026, 9 Spieler gegen 7 Hunter) ist noch nicht ausgestrahlt; ihr Regelwerk war noch nicht veröffentlicht. Neue Mechaniken daraus können später als Preset ergänzt werden.
- New York: "Filmpflicht mindestens 35 Stunden pro Tag" steht so im Regelwerk, ist aber bei 24 Stunden pro Tag offensichtlich ein Tippfehler (vermutlich 3,5 h oder 15 h). In der App ist die Dokumentationspflicht deshalb ein frei einstellbarer Wert und standardmässig ausgeschaltet.
- New York: Die Startmeldung "Speedhunt 1 von 4" wird hier als "Abfrage 1 von 4" interpretiert. Der Text ist als Vorlage einstellbar.
- Joker und Boni sind nur für Bangkok vollständig dokumentiert. Die Challenges der Serie (z. B. Tresor-Überfall in New York, "Jagd auf die Hunter" und "Hotel oder Strasse" in Bangkok) haben jeweils ein eigenes, nicht veröffentlichtes Regelwerk; die App bildet sie als Vorlagen nach (Kapitel 7.13).
- Die Serie toleriert für Spieler einzelne Gesetzesverstösse (z. B. Schwarzfahren, illegales Campieren). Die App übernimmt das **nicht** als Regel: In der App gilt immer das geltende Recht. Gruppen können Hausregeln als Freitext ergänzen.
- Handschellen werden in der App nur als optionale physische Fangmethode beschrieben. Standard ist ein sicherer, digitaler Fang per QR-Code (Kapitel 7.6).

# 3. Glossar

| Begriff | Bedeutung |
| Spieler (Runner) | Gejagte Person. Ziel: bis zum Spielende nicht gefangen werden und rechtzeitig den Exitpoint erreichen. |
| Hunter | Mitglied der Taskforce. Ziel: möglichst viele Spieler fangen. |
| Taskforce | Das Team aller Hunter, inklusive Einsatzzentrale. |
| Einsatzzentrale (HQ) | Hunter-Rolle, die die Karte mit allen freigegebenen Pings führt und die Hunter im Feld koordiniert. Soll ständig besetzt sein. |
| Spielleitung (Game Master, GM) | Überwacht die Regeln, gibt Standortdaten an die Taskforce weiter, entscheidet über Strafen und Ausnahmen. In der App: Auto-Spielleitung (Engine) und optional ein Mensch. |
| Ping / Track | Statischer Standort eines Spielers (Koordinate + Zeitpunkt + Genauigkeit), den die Taskforce erhält. Kein Livestandort. |
| Silenthunt | Regelmässige Pings ohne Vorwarnung an den Spieler. |
| Speedhunt | Zeitlich begrenzte Jagd auf einen Spieler, bei der die Taskforce mehrere Standortabfragen bekommt. Alle Spieler erhalten die Meldung "Speedhunt", aber nicht, wer betroffen ist. |
| Abfrage | Eine Standortabfrage innerhalb eines Speedhunts. |
| LEO | Schutzfenster nach einem Speedhunt: Der betroffene Spieler erhält bis zum Ende der nächsten vollen Stunde keine Silent-Pings. |
| Livestandort | Laufend aktualisierte Position, die die Taskforce für eine bestimmte Zeit sieht (z. B. ausserhalb des Spielfelds, im ÖV). |
| Catch / Fang | Ein Spieler ist gefangen, sobald der Fang nach der eingestellten Methode bestätigt ist (Original: Handschellen angelegt). |
| Spielfeld / Zone | Polygon(e), in denen sich Spieler aufhalten dürfen. Zonen können Typen und eigene Regeln haben. |
| Sektion | Einem einzelnen Spieler zugeteilte Zone (Staffel Wien und Bangkok). |
| Center Zone / Kernzone | Zone mit höherer Ping-Frequenz und ggf. Transportverbot (Bangkok: Center Zone, New York: Manhattan). |
| Aussenzone | Zone mit tieferer Ping-Frequenz (New York: Outer Area). |
| Spieltag | Zeitabschnitt, nach dem die Tagesregeln zurückgesetzt werden (Original 06:00 bis 06:00). Länge einstellbar. |
| Tagesreset | Zeitpunkt, zu dem ein neuer Spieltag beginnt (Original 06:00). |
| Verschanzen | Aufenthalt an einem Ort, den Hunter nicht betreten dürfen (Wohnung, Haus, verschlossener Raum). Zeitlich begrenzt. |
| Joker | Täglich vergebener Vorteil für Spieler (z. B. 4 h keine Pings). |
| Bonus | Vorteil, den man in einer Challenge erspielen muss. Verfällt beim Tagesreset. |
| Challenge | Freiwillige Tagesaufgabe mit eigener Regel, Risiko und Belohnung. |
| Exitpoint | Ort, den Spieler am Ende erreichen müssen, um zu gewinnen. |
| Kopfgeld | Belohnung, die die Taskforce pro Fang erhält (Bangkok: 1'000 EUR pro Spieler). |
| Teambildungs-Alarm | Warnung an die Taskforce, wenn sich zwei Spieler näher als ein Grenzwert kommen. |

# 4. Das Spiel in Kürze (Originalserie)

Neun (Staffel 3) bekannte Personen werden ohne Geld, Essen, Wasser und Unterkunft in einer Grossstadt ausgesetzt. Sie dürfen höchstens zwei persönliche Gegenstände mitnehmen, tragen ein Handy und einen GPS-Tracker und filmen sich mit Bodycam und Handkamera. Eine Taskforce aus sieben Huntern (Staffel 1: fünf) mit Einsatzwagen, Fahrrädern oder Motorrad jagt sie 96 Stunden lang (Staffel 1: 72 Stunden). Die Spielleitung ortet die Spieler regelmässig ohne Vorwarnung (Silenthunt) und gibt die Koordinaten an die Taskforce weiter. Zusätzlich darf die Taskforce Speedhunts auslösen, bei denen sie einen Spieler mehrmals kurz hintereinander orten darf. Wer gefangen wird (Handschellen), scheidet aus. Das Spielfeld wird jeden Tag um 06:00 Uhr kleiner. Täglich gibt es eine freiwillige Challenge mit Belohnungen und (Bangkok) einen Joker pro Spieler. In New York hat jeder Spieler ein Tagesbudget von 30 USD; jede Zahlung wird mit Ort an die Taskforce gemeldet. Wer nach 96 Stunden nicht gefangen wurde und rechtzeitig am Exitpoint ankommt, gewinnt (Preisgeld 5'000 EUR). Die Taskforce erhält ein Kopfgeld pro gefangenem Spieler.

# 5. Rollen und Rechte

## 5.1 Rollen

| Rolle | Beschreibung | Anzahl (einstellbar) |
| Ersteller (Host) | Legt das Spiel an, konfiguriert alles, lädt ein, startet. Ist automatisch Spielleitung, kann die Rolle aber abgeben oder zusätzlich Spieler/Hunter sein (nur wenn game.host_can_play = an; dann sieht er nur die Infos seiner Spielrolle). | 1 |
| Spielleitung (GM) | Sieht alles (alle Livestandorte), kann alle Regeln live ändern, Strafen verhängen, Pausen auslösen, Fänge bestätigen oder annullieren, Challenges freigeben. | 0 bis n (0 = vollautomatisch) |
| Spieler | Flieht. Sieht eigene Position, Spielfeld, eigene Joker, Boni, Budget, Timer, Meldungen. | 1 bis 100 |
| Hunter | Jagt. Sieht freigegebene Pings, Positionen der anderen Hunter, Taskforce-Chat. | 1 bis 50 |
| Einsatzzentrale | Hunter mit Zentralen-Dashboard (grosse Karte, Ping-Historie, Speedhunt-Steuerung). Kann gleichzeitig Hunter im Feld sein, wenn erlaubt. | 0 bis n |
| Zuschauer | Optional. Sieht das Spiel mit Verzögerung (spectator.delay_minutes). | 0 bis n |

Alle Rollen setzen ein eigenes, bestätigtes Konto voraus (Kapitel 20). Spiele entstehen innerhalb einer Gruppe; wer in einer Gruppe Admin ist, darf Spiele erstellen und wird dann Host (Kapitel 21). Die Spielrolle (Spieler, Hunter usw.) gilt nur für ein Spiel; in der nächsten Runde kann dieselbe Person eine andere Rolle haben.

## 5.2 Sichtbarkeitsmatrix

| Information | Spieler (selbst) | Andere Spieler | Hunter / Zentrale | Spielleitung | Zuschauer |
| Eigene Live-Position | ja | nein | nur in Live-Fenstern (ausserhalb, ÖV, Fahrzeug im Speedhunt, Hotel-Ende) | ja | ja, verzögert |
| Silent-Pings | Spieler erfährt NICHT, dass gepingt wurde (einstellbar: ping.notify_player) | nein | ja | ja | ja, verzögert |
| Speedhunt aktiv | alle Spieler: "Speedhunt läuft" ohne Ziel (einstellbar: speedhunt.reveal_target_to_target) | ja, anonym | ja, mit Ziel | ja | ja |
| Speedhunt-Abfragen | nein | nein | ja | ja | ja |
| Hunter-Positionen | nur durch Joker "Hunter erfragen" (Momentaufnahme) | nein | ja, live untereinander | ja | ja |
| Budget, Joker, Boni | eigene | nein (einstellbar: Anzahl öffentlich) | Einkäufe: Ort und Art; Joker-Einsatz: einstellbar | ja | ja |
| Spielfeld und nächste Verkleinerung | ja, ab Ankündigung | ja | ja | ja | ja |
| Fänge | Liste der gefangenen Spieler (einstellbar: catch.announce_to_players) | ja | ja | ja | ja |
| Regelverstösse | eigene | nein | Strafe (z. B. Straf-Speedhunt) ja | ja | ja |

MUSS: Die Sichtbarkeit wird ausschliesslich serverseitig entschieden. Ein Client erhält nie Daten, die seine Rolle nicht sehen darf (keine Filterung nur im UI).

# 6. Spielablauf und Zustände

## 6.1 Phasen eines Spiels

| Phase | Was passiert |
| Entwurf | Host erstellt Spiel, wählt Preset, passt Parameter an, zeichnet Spielfeld, plant Challenges. |
| Geplant | Spiel ist fertig konfiguriert (Karte vollständig, Validierung grün, Kapitel 22 und 25), hat Startzeit und Treffpunkt. Gruppenmitglieder sagen zu oder ab (Kapitel 21.5). |
| Lobby | Teilnehmer treten per Link/QR-Code/Code bei, wählen oder erhalten Rollen, akzeptieren Regeln und Sicherheitshinweise, Berechtigungen (Standort "immer", Mitteilungen) werden geprüft. Check: alle Geräte senden GPS, Akku über Mindestwert. |
| Briefing | Optional: Regelübersicht für alle, Ausrüstungs-Checkliste (max. 2 persönliche Gegenstände), Countdown. |
| Vorsprung | Spieler starten in der Startzone und verteilen sich. Hunter sind gesperrt (warten im HQ, Karte leer). Dauer: start.head_start_minutes. Keine Pings. Die App prüft, dass alle Hunter im HQ-Kreis bleiben (start.hunters_must_stay_in_hq); Verlassen = Warnung an Spielleitung und Verstoss-Fall. |
| Jagd (läuft) | Alle Regeln aktiv. Spieltage laufen, Tagesresets, Challenges, Speedhunts. |
| Pause | Durch Spielleitung oder Notfall. Alle Timer (Verschanzen, Joker-Dauer, ausserhalb-Zeit, Spielzeit wenn game.pause_extends_game = an) frieren ein. Keine Pings, keine Fänge. |
| Finale | Ab Bekanntgabe des Exitpoints. Spieler müssen bis zur Ankunftsfrist am Exitpoint sein. |
| Beendet | Ergebnis, Statistik, Wiederholung (Replay) der Karte, Export. |
| Archiviert | Standortrohdaten werden nach privacy.retention_days gelöscht. |

## 6.2 Zustände eines Spielers

| Zustand | Bedeutung | Übergänge |
| aktiv | Normal im Spiel | ausserhalb, im_transit, verschanzt, geschützt, gefangen, notfall, aufgegeben, disqualifiziert, im_ziel |
| ausserhalb | Ausserhalb des erlaubten Spielfelds. Taskforce sieht Livestandort. Timer läuft. | aktiv (zurück), gefangen oder disqualifiziert (Timer abgelaufen, je nach Einstellung) |
| im_transit | Fortbewegungsmittel/ÖV angemeldet. Livestandort je nach Regel. | aktiv (abgemeldet, Nachlauf-Livestandort läuft weiter) |
| verschanzt | Spieler hat sich in einem nicht öffentlichen Ort angemeldet oder die Engine erkennt einen längeren Aufenthalt. Timer läuft. | aktiv (verlassen, Mindestabstand), gefangen (Timer abgelaufen) |
| geschützt | Catch-Free-Joker oder Hotel-Bonus aktiv: kann nicht gefangen werden. | aktiv |
| gefangen | Ausgeschieden. Wird optional Zuschauer. | (nur Spielleitung kann annullieren) |
| notfall | Notfallknopf gedrückt. Jagd auf diesen Spieler (oder alle) unterbrochen. | aktiv (Spielleitung gibt frei), aufgegeben |
| aufgegeben | Freiwillig ausgestiegen. | - |
| disqualifiziert | Durch Regelverstoss. | - |
| im_ziel | Hat Exitpoint rechtzeitig erreicht. Sicher. | Gewinner bei Spielende |

Ein Spieler kann gleichzeitig mehrere Nebenzustände haben (z. B. aktiv + im_transit + LEO). Implementiere das als Hauptzustand plus Liste aktiver Effekte (effects: leo, regeneration, catch_free, hotel, live_visible, fake_ping_armed, speedhunt_target, proximity_alert).

## 6.3 Zustände eines Speedhunts

angefordert, (optional) wartet_auf_freigabe, läuft, beendet (Abfragen aufgebraucht, Zeit abgelaufen, Ziel gefangen, abgebrochen). Nach "beendet" startet LEO für das Ziel.

## 6.4 Ablauf eines Spieltags (Tagesreset)

Zum Tagesreset (Original 06:00) führt die Engine in genau dieser Reihenfolge aus:
1. Spieltag-Zähler erhöhen.
2. Neues Spielfeld aktivieren (wenn für diesen Tag geplant). Spieler ausserhalb erhalten den Zustand ausserhalb (mit Übergangsfrist zone.shrink_grace_minutes).
3. Budget auffüllen (Ansparen nur, wenn budget.allow_saving = an).
4. Neuen Joker an jeden aktiven Spieler vergeben. Nicht eingelöste Joker vom Vortag behalten oder verfallen lassen gemäss joker.carry_over.
5. Nicht eingelöste Boni verfallen lassen (bonus.expire_at_day_reset).
6. ÖV-Nachlaufzeit auf Startwert zurücksetzen.
7. Speedhunt-Kontingent für den neuen Tag setzen; Zähler "Speedhunts pro Spieler und Tag" zurücksetzen.
8. Tages-Challenge ankündigen, falls geplant.
9. Mitteilung "Neuer Spieltag" an alle mit Zusammenfassung.

# 7. Regelmodule

Jedes Modul nennt zuerst die Originalregel, dann die verbindliche App-Umsetzung. Alle Werte sind Parameter (Kapitel 8). Jedes Modul ist einzeln abschaltbar (modules.<name>.enabled).

## 7.1 Zeit, Spieldauer und Spieltag

Original: 96 Stunden (Wien 72 h). Tagesreset 06:00. Exitpoint-Ankunft bis 06:15 am letzten Morgen.

App:
- game.duration_minutes: Gesamtdauer der Jagd (ohne Vorsprung). Frei wählbar, z. B. 60, 90, 180, 1440, 5760 (= 96 h).
- game.day_length_minutes: Länge eines Spieltags. Standard 1440 (24 h). Bei kurzen Spielen wählt die App automatisch einen Vorschlag: Spieldauer / Anzahl gewünschter Spieltage (game.days, Standard 4).
- game.day_reset_time: Uhrzeit des ersten Tagesresets bei 24-h-Tagen (Standard 06:00). Bei kürzeren Tagen läuft der Reset relativ zum Spielstart.
- MUSS: Alle Regeln, die in der Serie "pro Tag" gelten, beziehen sich auf den Spieltag.
- MUSS: Alle Regeln, die in der Serie "zur vollen Stunde" gelten, haben die Option time.align_to_full_hour. Ist sie aus (empfohlen bei kurzen Spielen), wird ab Spielstart gezählt.
- SOLL: Zeitskalierung: Der Host kann mit einem Schieberegler "Tempo" alle Dauern (Ping-Intervall, Joker-Dauer, Verschanzen-Limit, ÖV-Nachlauf, LEO) proportional zur Spieldauer skalieren lassen. Die App zeigt die resultierenden Werte an, der Host kann jeden einzeln überschreiben. Skalierungsfaktor = game.duration_minutes / 5760.
- KANN: Ruhezeiten (game.quiet_hours, z. B. 00:00 bis 06:00), in denen nicht gejagt wird. Im Original gibt es keine Ruhezeit.

## 7.2 Spielfeld und Zonen

Original:
- Wien: Jeder Spieler hat eine eigene Sektion. Verlassen macht ihn für die Jäger sichtbar. Start im ersten Bezirk (Startzone, dort dürfen alle sein). Wird ein Spieler gefangen, wird seine Zone für die anderen frei. Gegen Ende werden Zonen grösser.
- Bangkok: Spielerzonen pro Spieler plus eine Center Zone, die alle betreten dürfen. Mehr als 2 h ausserhalb der Spielerzone = gefangen. Spielerzone wird täglich verkleinert. Gefangen = Zone wird frei.
- New York: Zwei Hauptzonen (Manhattan mit 1-h-Pings, Outer Area mit 2-h-Pings). Spielfeld wird täglich um 06:00 verkleinert, neue Karte spätestens um 03:00. Mehr als 2 h ausserhalb = Disqualifikation.

App:
- Spielfeld-Editor (MUSS): Zonen als Polygone auf der Karte zeichnen, Kreise, oder Stadtteil-Grenzen importieren (GeoJSON/KML-Import). Pro Zone: Name, Farbe, Typ, gültig von/bis (Spieltag oder Uhrzeit), zugeordnete Spieler.
- Zonentypen:
| Typ | Wirkung (alles einstellbar pro Zone) |
| spielfeld | Erlaubter Bereich für alle Spieler. |
| sektion | Erlaubter Bereich nur für zugeordnete Spieler. Wird beim Fang des Besitzers für alle frei (zone.release_on_catch). |
| startzone | Für alle erlaubt; Startpunkt. |
| center | Für alle erlaubt; eigenes Ping-Intervall; optional Fortbewegungsverbot. |
| aussen | Eigenes (meist längeres) Ping-Intervall. |
| sperrzone | Darf nie betreten werden (Autobahn, Bahngleise, Gewässer, Privatgelände, Schulen). Betreten = Warnung an Spieler sofort und an die Spielleitung. |
| sicher | Zone, in der nicht gefangen werden darf (z. B. Toiletten, Spitäler). KANN. |
| exit | Der Exitpoint (Kreis mit Radius exit.radius_m). |
- Spielfeldverkleinerung: Entweder (a) vorab gezeichnete Polygone pro Spieltag oder (b) automatisch: Polygon wird um zone.auto_shrink_percent pro Spieltag in Richtung eines Mittelpunkts (Standard: Exitpoint, falls bekannt, sonst Schwerpunkt) verkleinert. Ankündigung zone.shrink_announce_minutes vor Aktivierung (Original: 180 min, also 03:00 für 06:00).
- Spielfeldvergrösserung: ebenso möglich (Wien, Folge 9).
- MUSS: Die Karte zeigt jedem Spieler die für ihn gültigen Zonen, die nächste geplante Änderung (gestrichelt) und einen Countdown.
- Bedienung des Editors, Pflicht-Elemente, Sperrzonen-Details, Prüfungen und Grössenempfehlung: Kapitel 22.
- MUSS: Prüfung "innerhalb" serverseitig mit PostGIS (ST_Covers), mit Toleranz zone.edge_tolerance_m (Standard 25 m) wegen GPS-Ungenauigkeit.

## 7.3 Silenthunt (Pings)

Original:
- Wien: alle 2 h zur vollen Stunde, ohne Audiowarnung. Spielleitung darf Abstand verringern oder erhöhen.
- Bangkok: Aussenzonen alle 2 h, Center Zone stündlich, zur vollen Stunde.
- New York: Manhattan jede volle Stunde, Outer Area alle 2 h zur vollen Stunde. Silenthunt läuft während eines Speedhunts weiter.
- Wien: Während eines Speedhunts gibt es für den Spieler keinen Silenthunt.

App:
- ping.interval_minutes (Standard 120) und pro Zone überschreibbar (zone.<id>.ping_interval_minutes, z. B. 60 für Center).
- Massgeblich ist die Zone, in der sich der Spieler zum Ping-Zeitpunkt befindet.
- ping.align_to_full_hour (Standard an bei 24-h-Tagen). Bei 2-h-Intervall: gerade Stunden (00, 02, 04 ...), konfigurierbar ping.offset_minutes.
- ping.notify_player: aus (Original: keine Audiowarnung). KANN: "ping.notify_player_after" informiert den Spieler nachträglich.
- ping.jitter_minutes: zufällige Verschiebung 0 bis n Minuten (Standard 0), damit Spieler den Zeitpunkt nicht exakt kennen.
- ping.during_speedhunt: "weiterlaufen" (New York, Bangkok) oder "aussetzen" (Wien).
- ping.accuracy_reveal: Hunter sehen den Genauigkeitsradius (an) oder nur einen Punkt.
- ping.precision_blur_m: KANN künstliche Unschärfe (0 = exakt, Original).
- Ein Ping ist ein Datensatz: Spieler, Zeitpunkt, Position (Medianwert der letzten 30 s), Genauigkeit, Quelle (silent, speedhunt, purchase, transit, proximity, fake, hotel_end, out_of_bounds, penalty), Zone, ob gefälscht (nur für Spielleitung sichtbar).
- Die Spielleitung kann Intervalle live ändern (ping.gm_can_change_live).
- Wie ein Standort technisch vom Handy bis zur Taskforce-Karte gelangt (Frische-Regel, Push, Anzeige, Fehlerfälle): Kapitel 23.
- Spezialfall Erstes Ping: Original Wien erste Koordinaten 2 h nach Start. Erstes Ping = Ende des Vorsprungs + ping.first_ping_delay_minutes.

## 7.4 Speedhunt

Original:
- Ausgelöst von der Taskforce (aus einem Kontingent) bzw. von der Spielleitung. Startet mit der Nachricht "Speedhunt" an alle Spieler; der Betroffene ist nicht erkennbar.
- Abfragen pro Speedhunt: Wien 5, Bangkok 4, New York 4. Statische Standorte, keine Livetracks. Taskforce erhält nur die Koordinaten des Ziels.
- Anzahl: Wien 1 am ersten Tag, Bangkok 2, New York 3. Danach entscheidet die Spielleitung. Erhöhen, senken, aussetzen jederzeit möglich.
- Wien: höchstens 1 Speedhunt pro Spieler und Tag. Frühestens 45 min nach einem Silent-Track; erfolgt er früher, zählt der Silent-Track als Speedhunt-Track (Abfragen 5 werden zu 4).
- Wien: Nach einem Speedhunt ist der Spieler für die nächste volle Stunde im LEO.
- New York: Ist das Ziel auf einem Fortbewegungsmittel, erhält die Taskforce bei einer Abfrage 1 Minute Livestandort statt eines Punkts. Ein Spieler darf nicht zweimal hintereinander Ziel sein (ausser bei Regelverstoss oder wenn nur noch 2 Spieler im Spiel sind). Zwei Speedhunts dürfen gleichzeitig auf verschiedene Spieler laufen. Ein Catch streicht zusätzlich einen Speedhunt aus dem Kontingent.
- Strafe: Die Spielleitung kann bei Regelverstössen einen Speedhunt auf den Spieler ausrufen.
- Statistik der Serie: Fangchance bei einem Speedhunt ca. 45 %.

App:
- speedhunt.quota_per_day: Liste pro Spieltag, z. B. [3, 2, 2, 1]. Nicht angegebene Tage = speedhunt.quota_default. Nicht genutzte Speedhunts verfallen (speedhunt.carry_over = aus).
- speedhunt.trigger_mode: "taskforce" (Hunter wählen Ziel und Zeitpunkt), "random" (Engine zieht Ziel und Zeitpunkt zufällig, gleichmässig über den Tag verteilt), "gm" (nur Spielleitung). Optional speedhunt.gm_approval.
- speedhunt.queries: Anzahl Abfragen (Standard 4).
- speedhunt.query_min_gap_minutes: Mindestabstand zwischen zwei Abfragen (Standard 0; die Taskforce entscheidet).
- speedhunt.max_duration_minutes: Ein Speedhunt endet spätestens nach dieser Zeit (Standard 90). Unbenutzte Abfragen verfallen.
- speedhunt.min_minutes_after_silent_ping: 45 im Preset Wien, 0 (Regel aus) in den Presets Bangkok und New York. Mit speedhunt.early_start_policy: "verbieten" oder "silent_zaehlt_als_abfrage" (Standard, Original Wien).
- speedhunt.max_per_player_per_day: 1 (Wien) oder 0 = unbegrenzt.
- speedhunt.no_consecutive_same_target: an (New York); Ausnahmen speedhunt.consecutive_allowed_on_violation und speedhunt.consecutive_allowed_when_players_left_le (Standard 2).
- speedhunt.max_parallel: 2 (New York).
- speedhunt.vehicle_live_seconds: 60 (New York). Erkennung "auf Fortbewegungsmittel": im_transit-Zustand oder gemessene Geschwindigkeit > transport.speed_threshold_kmh.
- speedhunt.catch_removes_one: an (New York): Bei jedem Fang wird ein noch offener Speedhunt des aktuellen Tages gestrichen.
- speedhunt.announce_text: Vorlage, Standard "SPEEDHUNT! Einer von euch wird gejagt. Abfrage {n} von {queries}." Alle aktiven Spieler erhalten bei Start eine laute Mitteilung (Ton + Vibration, auch im Lautlos-Modus als kritische Mitteilung, falls erlaubt).
- speedhunt.notify_each_query_to_players: an. Bei jeder Abfrage erhalten alle Spieler "Abfrage {n} von {queries}" (anonym).
- speedhunt.reveal_target_to_target: aus (Original: Ziel erfährt es nicht).
- Abfrage ausführen: Hunter oder Zentrale drückt "Abfrage". Server liefert den aktuellen Standort des Ziels (bei Fahrzeug: Livestandort für vehicle_live_seconds). Ist das Ziel ausserhalb Empfang, wird die letzte bekannte Position mit Zeitstempel geliefert und markiert.
- Fang während Speedhunt: Speedhunt endet sofort.
- Regenerations-Joker oder Hotel-Bonus aktiv: Speedhunt auf dieses Ziel kann nicht gestartet werden; läuft einer, siehe Kapitel 14.

## 7.5 LEO (Schutzfenster nach Speedhunt)

Original Wien: Nach einem Speedhunt ist der gejagte Spieler für die nächste volle Stunde im LEO, kein Track an die Taskforce.

App: leo.enabled; leo.mode: "bis_ende_naechste_volle_stunde" (Original) oder "feste_dauer" mit leo.duration_minutes. Während LEO werden Silent-Pings dieses Spielers unterdrückt (nicht nachgeholt). Live-Fenster aus anderen Gründen (ausserhalb, ÖV, Kauf) gelten trotzdem, ausser leo.suppresses_all = an.

## 7.6 Fang (Catch)

Original: Ein Spieler gilt erst als gefangen, wenn ihm Handschellen angelegt wurden. New York: Ein Catch ohne Filmmaterial ist ungültig. Gefangene Spieler werden von einem Hunter zur Spielleitung gebracht (ÖV, Taxi oder Taskforce-Auto; bei Challenges abweichend). Gefangene dürfen befragt werden, Rucksack und Handy dürfen nicht durchsucht werden. Körperliche Gewalt ist verboten, Festhaltegriffe nur bei wirklicher Notwendigkeit. Auto-Catch: lautes Hilferufen oder Panikmache, die Polizei über die Verfolger informieren, Verschanzen über 2 h, (Bangkok) über 2 h ausserhalb der Zone.

App:
- catch.method (Mehrfachauswahl, Standard "qr"):
| Methode | Ablauf |
| qr | Jeder Spieler hat in der App einen persönlichen, rotierenden QR-Code (alle 30 s neu, signiert). Hunter scannt ihn mit der App. Gültig nur, wenn Hunter und Spieler laut GPS höchstens catch.max_distance_m (Standard 30 m) voneinander entfernt sind. Spieler muss den Code auf Verlangen zeigen (Pflicht, sobald berührt). |
| touch_confirm | Hunter berührt Spieler, drückt "Gefangen" und wählt den Spieler. Spieler bestätigt innerhalb catch.confirm_seconds (Standard 60). Ohne Bestätigung entscheidet die Spielleitung (oder bei Auto-Spielleitung: gültig, wenn GPS-Abstand <= max_distance_m). |
| nfc | Wie qr, aber per NFC-Tag/Armband. KANN. |
| bluetooth | Automatischer Fang, wenn Hunter-Gerät das Spieler-Gerät per BLE unter catch.ble_rssi_threshold für catch.ble_seconds erkennt und der Hunter "Gefangen" drückt. KANN. |
| handcuffs | Physische Handschellen/Kabelbinder-Attrappe wie im Original plus touch_confirm. Nur für volljährige Teilnehmer und mit ausdrücklicher Zustimmung. Sicherheitshinweis Pflicht. |
- catch.require_media: Foto- oder Videobeweis (Original New York). Bei an: Hunter muss innerhalb 2 Minuten ein Foto/Video in der App aufnehmen, sonst ist der Fang ungültig.
- catch.blocked_when: Spieler hat catch_free, hotel, im_ziel, notfall oder befindet sich in einer Zone vom Typ sicher, oder das Spiel ist pausiert. Die App lehnt den Fang mit Begründung ab.
- Nach Fang: Spieler wird "gefangen". Alle laufenden Speedhunts auf ihn enden. Seine Sektion wird frei (zone.release_on_catch). Kopfgeld wird gutgeschrieben. Speedhunt-Kontingent minus 1 (falls speedhunt.catch_removes_one). Meldung an alle (catch.announce_to_players, Standard an: "{Spieler} wurde gefangen. Noch {n} Spieler frei.").
- catch.transport_to_hq: Hinweis an Hunter, den Spieler zum HQ zu bringen (Original). In der App nur Checkliste, keine Pflicht.
- catch.caught_player_becomes: "zuschauer" (Standard), "hunter_helfer" (KANN: Gefangener wechselt ins Hunter-Team, Variante), "ausgeschieden_ohne_sicht".
- catch.interrogation_allowed: Hinweistext (Original: Befragen erlaubt, Rucksack und Handy nicht durchsuchen).
- Die Spielleitung kann jeden Fang annullieren (mit Begründung, protokolliert).
- Auto-Catch-Gründe (siehe 7.17): Polizei informiert, Hilfeschreie/Panik, Verschanzen-Limit, ausserhalb-Limit (wenn out_of_bounds.on_timeout = catch). Diese setzt die Spielleitung per Knopf; die App erkennt Verschanzen und ausserhalb automatisch.

## 7.7 Verlassen des Spielfelds

Original: Wer seine Sektion verlässt, ist für die Jäger sichtbar. Bangkok: über 2 h ausserhalb = gefangen. New York: über 2 h ausserhalb = Disqualifikation.

App:
- out_of_bounds.live_visible: an. Solange ausserhalb, sieht die Taskforce den Livestandort (Aktualisierung alle out_of_bounds.live_update_seconds, Standard 10).
- out_of_bounds.max_minutes: 120. Gemessen als Summe pro Ausflug (Standard) oder kumuliert pro Tag (out_of_bounds.count_mode).
- out_of_bounds.on_timeout: "catch" (Bangkok), "disqualify" (New York), "penalty" (Strafe gemäss Katalog).
- out_of_bounds.grace_seconds: 60. Kurze Ausreisser durch GPS-Sprünge lösen nichts aus.
- Spieler erhält sofort eine Warnung mit Pfeil zur nächsten Zonengrenze und Countdown.

## 7.8 Verschanzen

Original: Höchstens 2 h am Stück in Wohnungen, Häusern oder verschlossenen, nicht öffentlichen Orten, zu denen Jäger keinen Zutritt haben. Danach Mindestabstand vom Ort: Wien und Bangkok 100 m, New York 200 m Luftlinie. New York: Ab dem ersten Betreten ist der Ort nach 8 h vollständig unzugänglich. Überschreiten = Catch. Stört ein Versteck das GPS-Signal, muss es sofort gewechselt werden.

App:
- hideout.max_minutes: 120.
- hideout.min_leave_distance_m: 200 (New York) bzw. 100.
- hideout.lockout_after_first_entry_minutes: 480 (New York), 0 = aus.
- hideout.detection: "selbstmeldung" (Spieler drückt "Ich bin drinnen"), "automatisch" (Engine erkennt Aufenthalt: Bewegung unter hideout.stationary_radius_m = 40 m für länger als hideout.stationary_minutes = 20, und/oder schlechte GPS-Genauigkeit wie in Gebäuden) oder "beides" (Standard). Automatisch erkannte Aufenthalte werden dem Spieler als "Verschanzen erkannt? Ja/Nein" bestätigt; bei Nein entscheidet die Spielleitung.
- Gespeicherter Ort = Mittelpunkt des Aufenthalts. Timer beginnt beim Betreten. Warnungen bei 30, 10 und 2 Minuten Restzeit.
- Nach Verlassen: Ort wird zum gesperrten Kreis (Radius = min_leave_distance_m) für hideout.cooldown_minutes (Standard: bis ausreichend Abstand erreicht und danach 0) bzw. dauerhaft ab lockout_after_first_entry_minutes.
- on_timeout: catch (Original). Konfigurierbar: penalty.
- Signalverlust in Gebäude länger als tracking.signal_loss_max_minutes: Spieler muss den Ort wechseln, sonst Regelverstoss.

## 7.9 Fortbewegung und öffentlicher Verkehr

Original:
- Fortbewegungsmittel = alles, womit man schneller als normale Gehgeschwindigkeit ist (Inlineskates, Fahrrad, Motorrad, E-Roller, E-Skateboard, Auto, ÖV). Trampen erlaubt (New York, meldepflichtig). Taxi meldepflichtig und nur im Budget. Leihgaben mit Rückgabeabsicht verboten.
- New York ÖV: Jede Nutzung muss vorher angemeldet werden (Verkehrsmittel, Station von/bis). Löst sofort einen Livestandort aus, der bis 10 min nach dem Ausstieg gültig bleibt. Jede weitere Nutzung verlängert diese Nachlaufzeit um 5 min; täglicher Reset 06:00 auf 10 min. Abmeldung mit "ÖFFI verlassen". Transfer Manhattan <-> Outer Area nur mit vorheriger Anmeldung. Fähren erlaubt, max. 10 Stationen pro Tag, anmeldepflichtig. Nichtanmeldung = Regelverstoss.
- Bangkok: In der Center Zone sind alle mobilen Transportmittel verboten (Tuk-Tuk, Bus, Taxi, U-Bahn, Moped). Verstoss = Regelverletzung; jede weiteren 10 min = weitere Verletzung, jeweils mit Speedhunt geahndet; am letzten Tag kann der Sieg aberkannt werden. Fähren über den Fluss erlaubt, aber nicht über mehrere Stationen zur Flucht. In der Spielerzone ÖV erlaubt mit vorheriger Info an die Spielleitung.

App:
- transport.allowed_modes: Liste (zu_fuss immer; fahrrad, e_roller, skates, auto_mitfahrt/trampen, taxi, bus, tram, ubahn, zug, faehre, eigenes_fahrzeug). Jeder Modus: erlaubt ja/nein, meldepflichtig ja/nein, erlaubt in Zonentypen.
- transport.checkin_required: an. Spieler drückt "Transport starten", wählt Modus, optional Linie, Station von/bis. Abmeldung "Transport verlassen".
- transport.live_during: an (Livestandort während der Fahrt für die Taskforce).
- transport.live_after_base_minutes: 10; transport.live_after_increment_minutes: 5; Reset beim Tagesreset.
- transport.ferry_max_stops_per_day: 10.
- transport.zone_transfer_requires_checkin: an (Wechsel zwischen Zonen per Fahrzeug nur angemeldet).
- transport.forbidden_in_zone_types: [center] im Bangkok-Preset. transport.violation_repeat_minutes: 10 (jede weitere angefangene Periode = neuer Verstoss).
- transport.speed_threshold_kmh: 8. Automatische Erkennung: Bewegt sich ein Spieler länger als transport.detect_seconds (Standard 90) schneller als der Schwellwert ohne Anmeldung, erhält er eine Aufforderung "Fährst du? Jetzt anmelden" und nach 2 Minuten wird ein Verdachtsfall an die Spielleitung gemeldet (Auto-Spielleitung: Regelverstoss "ÖV nicht angemeldet").
- transport.max_rides_per_day: 0 = unbegrenzt.

## 7.10 Budget

Original New York: Start ohne Essen und Trinken. 30 USD pro Tag, aufgefüllt um 06:00, Ansparen nicht möglich, kein Schuldenmachen. Jede Zahlung wird mit Standort und Kaufart an die Taskforce gemeldet. Umtausch in Bargeld verboten. Mitgebrachtes Geld (Karte, Bitcoin) verboten. Geld leihen, Betteln, Pfandhandel, Kauf auf Rechnung verboten. Taxi über Budget unzulässig. Unterstützung durch Fans verboten; freiwillige Sachgeschenke (kein Zahlungsmittel) erlaubt. Wien/Bangkok: ohne Geld gestartet, kein Tagesbudget im Regelwerk.

App:
- budget.enabled; budget.currency (CHF, EUR, USD, ...); budget.daily_amount (30); budget.start_amount (0 oder Tagesbetrag); budget.allow_saving (aus); budget.allow_negative (aus).
- Einkauf erfassen (MUSS): Spieler gibt Betrag und Kategorie ein (Essen, Getränk, Transport, Taxi, Hygiene, Sonstiges), optional Foto des Belegs (budget.receipt_photo_required). Die App bucht ab und sendet einen Kauf-Ping (Ort + Kategorie, nicht Betrag, einstellbar budget.reveal_amount) an die Taskforce, verzögert um budget.ping_delay_minutes (Standard 0).
- Kauf ohne Budget wird abgelehnt. Die echte Bezahlung erfolgt ausserhalb der App (z. B. eine Prepaid-Karte pro Spieler oder Bargeld beim Host); die App ist das Kassenbuch.
- budget.max_taxi_per_ride: optional.
- Belohnungen aus Challenges können Budget gutschreiben.

## 7.11 Joker

Original Bangkok: Täglich ab 06:00 erhält jeder Spieler einen neuen Joker. Er kann sofort eingelöst oder für den nächsten Tag aufgehoben werden. Typen:
- Regenerations-Joker: 4 h keine Pings weitergegeben; in dieser Zeit kein Speedhunt möglich.
- Hunter erfragen: aktuelle Position der Hunter.
- Catch-Free-Bonus: 3 h nicht fangbar.
(In Folge 8 der Staffel Bangkok wurden neue Jokerkarten eingeführt; diese sind im Regelwerk nicht beschrieben.)

App:
- joker.enabled; joker.per_day: 1; joker.selection: "spieler_waehlt" (aus Katalog), "zufall" (Original: Karte wird gezogen) oder "fest_pro_tag".
- joker.carry_over: "einen_tag" (Original), "unbegrenzt", "nie".
- joker.max_inventory: 2.
- joker.visible_to_taskforce_on_use: aus. Ein Einsatz wird nur der Spielleitung angezeigt; die Taskforce merkt es an fehlenden Pings.
- Joker-Katalog (jeder Typ einzeln aktivierbar, Dauer einstellbar):
| Joker | Wirkung | Standard |
| regeneration | Keine Silent-Pings, kein Speedhunt auf diesen Spieler, kein Teambildungs-Alarm. Kauf- und Transport-Livestandorte gelten weiter (einstellbar). | 240 min |
| hunter_erfragen | Spieler erhält eine Momentaufnahme aller Hunter-Positionen (Karte, 5 min sichtbar, kein Live-Update). | einmalig |
| catch_free | Spieler kann nicht gefangen werden. Pings laufen normal weiter. | 180 min |
| fake_ping (als Joker) | wie Bonus fake_ping, siehe 7.12 | einmalig |
| eigene | Host kann eigene Joker mit Name, Beschreibung, Dauer und Effekt aus einer Liste von Effekten zusammenstellen (Effekte: pings_unterdrücken, speedhunt_sperren, nicht_fangbar, hunter_positionen_zeigen, ping_faelschen, ping_intervall_verdoppeln, budget_gutschrift, zone_verlassen_erlaubt X min). | - |

## 7.12 Boni

Original Bangkok: Boni gibt es nur durch Teilnahme an einer Challenge. Sie müssen bis 06:00 eingelöst werden und verfallen danach. Typen:
- Fake-Ping-Bonus: Der Spieler setzt einen Ping seiner Wahl als Fake-Ping (gilt für Silenthunt und Speedhunt). Alternativ wählt die Spielleitung.
- 6h-Hotel-Bonus: 6 h Aufenthalt in einem Hotelzimmer. Danach wird der Spieler "vom Hotelpersonal erkannt" und sein Aufenthaltsort an die Taskforce weitergegeben.

App:
- bonus.expire_at_day_reset: an.
- fake_ping: Spieler aktiviert ihn und setzt auf der Karte einen Punkt innerhalb seines erlaubten Spielfelds, höchstens bonus.fake_ping_max_distance_m (Standard 3000 m) von der echten Position. Der nächste Ping (Silent oder eine Speedhunt-Abfrage, je nach Wahl) zeigt der Taskforce diesen Punkt. bonus.fake_ping_chooser: "spieler" oder "spielleitung".
- hotel: Spieler aktiviert ihn an seinem aktuellen Ort (Hotel, Unterkunft). Für bonus.hotel_minutes (360) ist er innerhalb von bonus.hotel_radius_m (50 m) nicht fangbar und das Verschanzen-Limit gilt nicht. Pings laufen weiter (bonus.hotel_pings: "weiter" oder "pausiert"). Bei Ende: Ping "Hotel" mit exaktem Ort an die Taskforce, Spieler muss den Ort verlassen (gilt danach als verlassenes Versteck, Mindestabstand 7.8).
- Weitere Bonus-Typen können wie Joker frei definiert werden (gleicher Effektbaukasten), z. B. Budget-Gutschrift, ein Speedhunt weniger heute, Hinweis auf den Exitpoint.

## 7.13 Challenges

Original: Täglich eine Challenge, Teilnahme freiwillig. Unterschiedliche Schwierigkeit, teils hohe Belohnungen. Eigenes Regelwerk, das vor dem Start bekannt gegeben wird. Ein Catch während einer Challenge zählt. New York: Teambildungsregel ist 1 h vor, während und 1 h nach der Challenge ausgesetzt; Transport gefangener Spieler kann abweichen. Beispiele aus der Serie: "Jagd auf die Hunter" (Bangkok, Spieler fotografieren Hunter), "Hotel oder Strasse" (Bangkok), "Hide" (Bangkok, Risiko gegen Bonus), Tresor-Überfall eines "Black Circuit Vault" (New York, Wettlauf gegen die Zeit nach Betreten eines Raums).

App:
- challenge.enabled; challenge.per_day: 1; challenge.announce_before_minutes (Standard 60); challenge.suspend_proximity_rule_minutes_before/after: 60/60.
- Pro Challenge: Titel, Beschreibung (Regelwerk), Ort (Geofence), Zeitfenster, Teilnahmeschluss, maximale Teilnehmerzahl, Belohnung(en) pro Platz oder für alle Erfolgreichen, Risiko (z. B. Ort wird der Taskforce verraten), Nachweis-Art, Auswertung (automatisch oder Spielleitung).
- Teilnahme: Spieler drückt "Teilnehmen". Wer nicht teilnimmt, hat keine Nachteile (ausser die Challenge definiert es).
- Nachweis-Arten: geofence_checkin (Spieler muss Ort X betreten), qr_scan (Code am Ort, vom Host vorher platziert), foto (Spielleitung prüft), quiz (Antwort eingeben), zeit (schnellster gewinnt), hunter_foto (Spieler fotografiert einen Hunter; Spielleitung bestätigt).
- Challenge-Vorlagen (MUSS mitgeliefert, alle Werte anpassbar):
| Vorlage | Ablauf | Belohnung / Risiko |
| Tresor-Überfall | Ort wird bekannt gegeben. Ab Betreten des Geofence läuft ein Timer (z. B. 10 min) für das Lösen eines Rätsels/Scannen eines Codes. Die Taskforce erfährt den Ort gleichzeitig mit den Spielern. | Bonus (z. B. Fake-Ping) oder Budget; Risiko Fang |
| Jagd auf die Hunter | Spieler müssen einen Hunter fotografieren (Gesicht/Weste erkennbar). | Pro Foto ein Bonus; Taskforce erhält dafür einen Ping des Fotografen nach X min |
| Hotel oder Strasse | Spieler entscheiden bis Frist: Hotel-Bonus (Ort wird nach Ablauf verraten) oder Strasse (Budget-Bonus). | wie gewählt |
| Hide | Spieler müssen sich an einem selbst gewählten Ort innerhalb eines Bereichs X min nicht bewegen; Taskforce erhält einmalig einen unscharfen Ping (Radius). | Bonus für alle, die nicht gefangen werden |
| Checkpoint-Lauf | N Orte in beliebiger Reihenfolge per QR/Geofence einsammeln. | Gestaffelte Belohnung |
| Schnitzeljagd | Kette von Rätseln, jeder Hinweis führt zum nächsten Ort. | Hinweis auf Exitpoint |
| Foto-Aufgabe | Foto von einem Motiv (z. B. Wahrzeichen) einreichen. | Budget |
- Belohnungstypen: bonus (aus Katalog), joker, budget, info (z. B. ein Hunter-Positionen-Snapshot, früherer Exitpoint-Hinweis), ping_pause (X min).

## 7.14 Teambildung / Nähe-Regel

Original New York: Teambildung ist nicht erwünscht, aber erlaubt. Kommen sich zwei oder mehr Spieler näher als 250 m, wird die Taskforce alarmiert und die Spieler erhalten die Standorte der anderen. Gilt ab 1 h nach Fluchtbeginn. Ausgesetzt 1 h vor, während und 1 h nach Challenges. Private Telefonate oder Absprachen zwischen Spielern sind verboten.

App:
- proximity.enabled; proximity.distance_m: 250; proximity.active_after_minutes: 60; proximity.hysteresis_m: 50 (neuer Alarm erst, wenn sie sich wieder auf mehr als distance + hysteresis entfernt haben); proximity.check_interval_seconds: 30.
- Bei Auslösung: Taskforce erhält einen Ping aller beteiligten Spieler (Quelle proximity). Die beteiligten Spieler sehen die Positionen der jeweils anderen (Momentaufnahme).
- proximity.repeat_minutes: Solange sie zusammenbleiben, erneuter Ping alle X min (Standard 0 = nur einmal).
- Unterdrückt bei: regeneration-Joker eines Beteiligten (nur dessen Position), Challenge-Fenster, Pause.
- communication.player_to_player: aus (Original verboten). Die App bietet keinen Chat zwischen Spielern, ausser die Einstellung erlaubt es.

## 7.15 Taskforce (Hunter)

Original (alle Staffeln): Hunter dürfen sich in allen Zonen frei bewegen. Fahrzeuge: Wien Einsatzwagen + bei Bedarf Motorrad; Bangkok Einsatzwagen + bei Bedarf Mopeds; New York 1 Auto + 2 Fahrräder (eine Person pro Rad). Verkehrsstrafen zahlen Hunter selbst. Bodycam und Handkamera, auch im HQ (New York). Keine Gewalt, Festhaltegriffe nur wenn nötig. Passanten nicht aktiv um Hilfe bitten (ausser fragen, ob jemand etwas Auffälliges gesehen hat). Kein eigenes Tracking (Disqualifikation des Hunters). Polizei nicht informieren. GPS-Tracker und Handy immer tragen. Rund um die Uhr erreichbar. Einsatzzentrale immer besetzt (Ausnahme mit Genehmigung). Einmal täglich Einsatzbesprechung im HQ (Wien, Bangkok). Pausen von mehr als einem Tag verboten. Gefangene sofort zur Spielleitung bringen. Bei Notfall eines Spielers wird die Jagd unterbrochen, Hunter leisten Erste Hilfe. Kopfgeld pro gefangenem Spieler (Bangkok 1'000 EUR).

App:
- taskforce.vehicles: Freitext-Liste und Zähler (z. B. 1 Auto, 2 Velos). Nur informativ, KANN: Hunter meldet, welches Fahrzeug er nutzt.
- taskforce.hq_required: an. Mindestens ein Hunter muss als "In der Zentrale" eingecheckt sein; sonst Warnung an Taskforce und Spielleitung nach taskforce.hq_empty_warning_minutes (15).
- taskforce.daily_briefing: an; Erinnerung zum eingestellten Zeitpunkt; Bestätigung "Briefing erledigt".
- taskforce.share_positions_internally: an. Hunter sehen sich gegenseitig live.
- taskforce.bounty_per_catch: Betrag oder Punkte (Standard 1000 Punkte); taskforce.bounty_currency.
- taskforce.max_break_minutes: KANN: Hunter kann sich in Pause setzen; Warnung, wenn länger als Grenzwert.
- Nur Daten aus der Engine: Hunter-Clients erhalten nie Spieler-Rohstandorte.

## 7.16 Spielerpflichten und Verbote

Original (zusammengefasst, alle Staffeln): Tracker und Handy immer am Körper; nicht ablegen, nicht stören, nicht verkaufen, nicht unbeaufsichtigt lassen. Rund um die Uhr für die Spielleitung erreichbar. Kein mitgebrachtes Geld, keine Schulden, nicht leihen, kein Pfandhandel. Keine Unterstützung durch Fans (Geld, Sachleistungen, Transport); freiwillige Sachgeschenke erlaubt. Nicht verraten, dass es ein Spiel ist, das man gewinnen muss (Wien); Hilfe erbitten erlaubt, solange das nicht herauskommt. Polizei nicht über Verfolger informieren (= Catch). Keine Hilfeschreie oder Panikmache (= Catch). Keine Leihgaben mit Rückgabeabsicht. Keine privaten Telefonate/Absprachen mit anderen Spielern; Kommunikation nur über den offiziellen Kanal (Telegram). Max. zwei persönliche Gegenstände. Dokumentationspflicht (filmen). Keine Gewalt.

App:
- Regeltext-Katalog mit allen Punkten, je an/aus, und Feld für Hausregeln. Spieler müssen vor Start alle aktiven Regeln bestätigen.
- equipment.personal_items_max: 2 (Checkliste im Briefing).
- documentation.required_minutes_per_day: 0 (aus). Wenn gesetzt: Spieler melden Aufnahmedauer manuell; Unterschreitung = Verstoss.
- Heartbeat: Die App erkennt "Handy aus/abgelegt" über fehlende Standortdaten und fehlende Bewegung bei gleichzeitiger Gerätesperre über lange Zeit nicht zuverlässig; deshalb nur Signalverlust-Regel (7.18, 15).

## 7.17 Regelverstösse und Strafen

Original: Mögliche Sanktionen: Verwarnung, zusätzlicher Speedhunt auf den betroffenen Spieler, sofortige Disqualifikation; Spielleitung entscheidet je nach Schwere. Bangkok: wiederholte Verstösse alle 10 min je ein Speedhunt; am letzten Tag kann der Sieg aberkannt werden. Bei sehr schweren Verstössen ist eine spätere Disqualifikation möglich (Massstab: unfairer Vorteil). Verstösse, die erst nach Spielende (96 h) bemerkt werden, können nicht mehr bestraft werden. Illegale Handlungen = Disqualifikation (mit Ausnahmen, siehe Kapitel 2).

App:
- Strafarten: verwarnung, straf_speedhunt (zählt nicht zum Kontingent, darf nicht aufeinanderfolgend-Regel brechen), live_standort (X min), sofort_ping, budget_abzug, joker_entzug, zeitstrafe (X min bewegungslos warten; KANN), catch, disqualifikation, sieg_aberkennen (nur Finale).
- Verstoss-Katalog (Standardstrafen, alle einstellbar):
| Verstoss | Erkennung | Standardstrafe |
| Spielfeld zu lange verlassen | automatisch | gemäss out_of_bounds.on_timeout |
| Sperrzone betreten | automatisch | verwarnung, beim 2. Mal straf_speedhunt |
| Verschanzen über Limit | automatisch | catch |
| Versteck vor Mindestabstand wieder betreten | automatisch | straf_speedhunt |
| ÖV/Fahrzeug nicht angemeldet | automatisch (Verdacht) + Spielleitung | straf_speedhunt |
| Fahrzeug in verbotener Zone | automatisch | straf_speedhunt, alle 10 min wiederholt |
| Fähren-Limit überschritten | automatisch | verwarnung |
| Budget überschritten / fremdes Geld | Spielleitung | straf_speedhunt |
| Signal absichtlich gestört / Handy abgelegt | automatisch (Verdacht) + Spielleitung | straf_speedhunt bzw. disqualifikation |
| Polizei informiert | Spielleitung | catch |
| Hilfeschreie / Panik | Spielleitung | catch |
| Absprache mit anderen Spielern | Spielleitung | verwarnung |
| Fan-Unterstützung | Spielleitung | straf_speedhunt |
| Gewalt | Spielleitung | disqualifikation |
| Hunter: eigenes Tracking | Spielleitung | Hunter disqualifiziert |
| Hunter: Gewalt | Spielleitung | Hunter disqualifiziert |
| Hunter: Polizei informiert | Spielleitung | Hunter disqualifiziert |
- Ablauf: Automatisch erkannte Verstösse erzeugen einen Fall. Mit menschlicher Spielleitung: Fall wird zur Entscheidung angezeigt (vorgeschlagene Strafe, Annehmen/Ändern/Verwerfen). Ohne menschliche Spielleitung: Standardstrafe wird nach penalty.auto_apply_delay_seconds (60) automatisch verhängt, der Spieler kann innerhalb dieser Zeit eine Erklärung absenden (wird protokolliert).
- penalty.escalation: Wiederholungen eskalieren gemäss Liste (z. B. verwarnung -> straf_speedhunt -> disqualifikation).
- penalty.after_game_end: aus (Original: nach Spielende keine Strafen mehr).

## 7.18 Notfall und Sicherheit

Original: Gerät ein Spieler in Not, wird die Jagd unterbrochen; Hunter werden zu seinem Sicherheitspersonal, leisten Erste Hilfe oder schützen ihn. Bei Gefahr für Unbeteiligte leisten Hunter sofort Erste Hilfe. In Staffel 1 (Folge 8) wurde der Notfallknopf gedrückt; laut Folgenbeschreibung folgte ein Speedhunt.

App (MUSS):
- Notfallknopf für alle Rollen, immer sichtbar (2 s gedrückt halten). Wirkung: Spielleitung und alle Hunter erhalten Alarm mit Livestandort der Person; Option "Notruf wählen" (112/117/144/911 je Land) direkt aus der App; Jagd auf diese Person sofort pausiert (safety.emergency_pauses: "person" oder "alle").
- Freigabe nur durch Spielleitung (oder bei Auto-Spielleitung durch die Person selbst nach safety.emergency_min_pause_minutes und Bestätigung). Missbrauch: safety.emergency_abuse_penalty (Standard: Spielleitung entscheidet; Original-ähnlich: straf_speedhunt).
- Globale Pause durch Spielleitung (z. B. Gewitter, Unfall).
- Akku: Warnung an Spieler bei 25 %, an Spielleitung bei 15 %. Bei 5 % automatisch "letzter bekannter Standort" an Spielleitung.
- Sperrzonen für gefährliche Orte; Warnung bei Annäherung (safety.restricted_warning_m = 50).
- Altersgrenze: safety.min_age (Standard 16, mit Bestätigung; unter 18 nur mit Einverständnis der Eltern; physische Fangmethode "handcuffs" nur ab 18).
- Sicherheitsregeln vor Start bestätigen: Verkehrsregeln beachten, keine Privatgrundstücke, keine Gewalt, kein Rennen über Strassen, Nachtsicherheit, Wasser trinken.
- Nachts: safety.night_mode (KANN): zwischen X und Y Uhr keine Fänge in Unterführungen/Parks o. ä.; standardmässig aus.
- Check-in: Spielleitung kann jeden Spieler "Alles ok?" fragen; keine Antwort in 10 min = Alarm.

## 7.19 Spielende, Exitpoint und Sieg

Original: Spielende nach 96 h. Gewinner ist, wer bis dahin nicht gefangen wurde und bis 06:15 am Exitpoint ankommt. Preisgeld 5'000 EUR. Taskforce: Kopfgeld pro Fang.

App:
- exit.enabled: an. exit.location: Punkt + Radius (exit.radius_m, Standard 30). exit.reveal_minutes_before_end: Standard 120 (für kurze Spiele skaliert). exit.reveal_to_taskforce: "gleichzeitig" (Standard), "verzoegert X min", "nie".
- exit.arrival_deadline_offset_minutes: 15 (Ankunft bis Spielende + 15 min, Original 06:00 + 15 = 06:15).
- Ankunft: Spieler betritt Radius und scannt optional den QR-Code am Exitpoint (exit.confirm: "geofence", "qr", "spielleitung"). Danach im_ziel = sicher.
- Fänge sind bis zur Ankunft erlaubt, auch am Exitpoint selbst (exit.safe_radius_m = 0, einstellbar).
- Wer zum Spielende nicht gefangen, aber nicht im Ziel ist: exit.missed_policy: "verloren" (Original) oder "gewonnen_ohne_exit".
- Ohne Exitpoint (exit.enabled = aus): Alle nicht Gefangenen gewinnen bei Spielende.
- Siegermodus win.mode: "alle_ueberlebenden" (Original, Preis wird geteilt: win.prize_split = gleichmaessig), "letzter_ueberlebender" (Spiel endet, sobald nur noch einer frei ist oder Zeit um), "punkte".
- Punkte (KANN, win.mode = punkte): Spieler: Punkte pro überlebter Stunde, pro Challenge, Bonus für Exit; Hunter: Kopfgeld pro Fang. Rangliste.
- Spielende: Endbildschirm mit Siegern, Kopfgeld der Taskforce, Statistik (Distanz pro Person, Anzahl Pings, Speedhunts, Fangquote pro Speedhunt, Fangorte), Replay der gesamten Jagd auf der Karte (Zeitachse), Export als Video/GIF KANN.

## 7.20 Kommunikation

Original: Kommunikation über Telegram. Spielleitung gibt Pings an die Taskforce weiter. Spieler bekommen Speedhunt-Meldungen.

App:
- Kanäle: Ankündigungen (Spielleitung -> alle), Spielleitung <-> einzelner Spieler (privat), Taskforce-Chat (Hunter + Zentrale + Spielleitung), Spielleitung <-> Taskforce, optional Spieler <-> Spieler (communication.player_to_player, Standard aus).
- Nachrichten: Text, Foto, Sprachnachricht, Standort (Standort teilen nur im Taskforce-Chat).
- Systemnachrichten (Ping, Speedhunt, Fang, Zone, Challenge) erscheinen im passenden Kanal und als Push.
- Alle Nachrichten werden protokolliert und sind nach dem Spiel im Replay sichtbar (privacy).

## 7.21 Ausrüstung

Original: Handy und GPS-Tracker (immer am Körper), Bodycam und Handkamera, max. 2 persönliche Gegenstände, kein Essen, kein Geld.

App: Das Smartphone ersetzt den Tracker. Checkliste im Briefing: Powerbank (empfohlen, zählt als Gegenstand gemäss equipment.powerbank_counts_as_item), Ausweis, Notfallkontakt, Wasser (equipment.water_allowed). Alles als Hausregel konfigurierbar.

# 8. Konfiguration: vollständiger Parameterkatalog

Jeder Parameter ist im Spiel-Setup editierbar (gruppiert in Abschnitte, mit Erklärungstext und "Original"-Badge, wenn der Wert dem Original entspricht). Speicherung als versioniertes JSON (GameConfig), validiert mit einem Schema (z. B. Zod). Änderungen während des Spiels werden protokolliert und allen betroffenen Rollen mitgeteilt. Standardwerte = Preset "Original New York" (Zeiten in Minuten).

| Schlüssel | Typ | Standard | Bereich / Werte | Bedeutung |
| game.name | Text | - | 1-60 Zeichen | Name des Spiels |
| game.timezone | Zeitzone | Gerät des Hosts | IANA | Zeitzone |
| game.start_at | Zeitpunkt | - | - | Geplanter Start |
| game.duration_minutes | Zahl | 5760 | 15-20160 | Jagddauer |
| game.days | Zahl | 4 | 1-14 | Anzahl Spieltage (berechnet Tageslänge) |
| game.day_length_minutes | Zahl | 1440 | 10-1440 | Länge Spieltag |
| game.day_reset_time | Uhrzeit | 06:00 | - | Erster Reset bei 24-h-Tagen |
| game.quiet_hours | Liste | leer | Zeitfenster | Jagdfreie Zeiten |
| game.pause_extends_game | Bool | an | - | Pause verlängert Spiel |
| game.host_can_play | Bool | aus | - | Host spielt mit |
| roles.players_max | Zahl | 9 | 1-100 | Max. Spieler |
| roles.hunters_max | Zahl | 7 | 1-50 | Max. Hunter |
| roles.assignment | Auswahl | host | host, zufall, selbst | Rollenvergabe |
| roles.gm_mode | Auswahl | auto | auto, mensch, beides | Spielleitung |
| start.head_start_minutes | Zahl | 60 | 0-600 | Vorsprung |
| start.zone | Zone | Startzone | - | Startbereich |
| time.align_to_full_hour | Bool | an | - | Volle Stunden |
| time.scale_auto | Bool | aus | - | Dauern proportional skalieren |
| zone.edge_tolerance_m | Zahl | 25 | 0-200 | GPS-Toleranz |
| zone.shrink_mode | Auswahl | manuell | manuell, auto, aus | Verkleinerung |
| zone.auto_shrink_percent | Zahl | 20 | 1-80 | Fläche pro Spieltag |
| zone.shrink_announce_minutes | Zahl | 180 | 0-1440 | Vorankündigung |
| zone.shrink_grace_minutes | Zahl | 0 | 0-120 | Übergangsfrist |
| zone.release_on_catch | Bool | aus (NY), an (Wien/Bangkok) | - | Sektion wird frei |
| zone.sections_per_player | Bool | aus | - | Eigene Sektionen |
| ping.interval_minutes | Zahl | 120 | 1-720 | Silent-Ping-Intervall |
| ping.zone_overrides | Map | center/kern: 60 | - | Intervall je Zone |
| ping.offset_minutes | Zahl | 0 | 0-719 | Versatz |
| ping.jitter_minutes | Zahl | 0 | 0-30 | Zufallsversatz |
| ping.notify_player | Bool | aus | - | Spieler hört Ping |
| ping.during_speedhunt | Auswahl | weiterlaufen | weiterlaufen, aussetzen | Silent im Speedhunt |
| ping.first_ping_delay_minutes | Zahl | 0 | 0-600 | Erster Ping nach Vorsprung |
| ping.precision_blur_m | Zahl | 0 | 0-1000 | Unschärfe |
| ping.gm_can_change_live | Bool | an | - | Live-Änderung |
| speedhunt.enabled | Bool | an | - | Modul |
| speedhunt.quota_per_day | Liste | [3] | je 0-20 | Kontingent pro Tag |
| speedhunt.quota_default | Zahl | 2 | 0-20 | Folgetage |
| speedhunt.carry_over | Bool | aus | - | Ungenutzte übertragen |
| speedhunt.trigger_mode | Auswahl | taskforce | taskforce, random, gm | Auslöser |
| speedhunt.gm_approval | Bool | aus | - | Freigabe nötig |
| speedhunt.queries | Zahl | 4 | 1-20 | Abfragen |
| speedhunt.query_min_gap_minutes | Zahl | 0 | 0-60 | Abstand Abfragen |
| speedhunt.max_duration_minutes | Zahl | 90 | 5-480 | Maximale Dauer |
| speedhunt.min_minutes_after_silent_ping | Zahl | 0 (NY), 45 (Wien) | 0-120 | Abstand zum Silent-Ping |
| speedhunt.early_start_policy | Auswahl | silent_zaehlt_als_abfrage | verbieten, silent_zaehlt_als_abfrage | Wien-Regel |
| speedhunt.max_per_player_per_day | Zahl | 0 | 0-10 | 0 = unbegrenzt |
| speedhunt.no_consecutive_same_target | Bool | an | - | NY-Regel |
| speedhunt.consecutive_allowed_when_players_left_le | Zahl | 2 | 1-10 | Ausnahme |
| speedhunt.max_parallel | Zahl | 2 | 1-10 | Gleichzeitig |
| speedhunt.vehicle_live_seconds | Zahl | 60 | 0-600 | Live bei Fahrzeug |
| speedhunt.catch_removes_one | Bool | an | - | Fang streicht einen |
| speedhunt.reveal_target_to_target | Bool | aus | - | Ziel erfährt es |
| speedhunt.notify_each_query_to_players | Bool | an | - | Abfrage-Meldung |
| speedhunt.announce_text | Text | Vorlage | - | Meldungstext |
| leo.enabled | Bool | aus (NY), an (Wien) | - | Schutzfenster |
| leo.mode | Auswahl | bis_ende_naechste_volle_stunde | ..., feste_dauer | Art |
| leo.duration_minutes | Zahl | 60 | 0-240 | Dauer bei fester Dauer |
| catch.method | Mehrfach | qr | qr, touch_confirm, nfc, bluetooth, handcuffs | Fangmethode |
| catch.max_distance_m | Zahl | 30 | 5-200 | GPS-Plausibilität |
| catch.confirm_seconds | Zahl | 60 | 10-300 | Bestätigungsfrist |
| catch.require_media | Bool | aus | - | Foto/Video-Beweis |
| catch.announce_to_players | Bool | an | - | Fang öffentlich |
| catch.caught_player_becomes | Auswahl | zuschauer | zuschauer, hunter_helfer, nichts | Danach |
| out_of_bounds.live_visible | Bool | an | - | Live für Taskforce |
| out_of_bounds.max_minutes | Zahl | 120 | 1-600 | Limit |
| out_of_bounds.count_mode | Auswahl | pro_ausflug | pro_ausflug, pro_tag | Zählweise |
| out_of_bounds.on_timeout | Auswahl | disqualify | catch, disqualify, penalty | Folge |
| out_of_bounds.grace_seconds | Zahl | 60 | 0-600 | Toleranz |
| hideout.enabled | Bool | an | - | Modul |
| hideout.max_minutes | Zahl | 120 | 5-720 | Limit |
| hideout.min_leave_distance_m | Zahl | 200 | 0-2000 | Mindestabstand |
| hideout.lockout_after_first_entry_minutes | Zahl | 480 | 0-2880 | Ort gesperrt nach |
| hideout.detection | Auswahl | beides | selbstmeldung, automatisch, beides | Erkennung |
| hideout.stationary_radius_m | Zahl | 40 | 10-200 | Erkennung Radius |
| hideout.stationary_minutes | Zahl | 20 | 5-120 | Erkennung Dauer |
| hideout.on_timeout | Auswahl | catch | catch, penalty | Folge |
| transport.allowed_modes | Liste | alle ausser eigenes_fahrzeug | - | Erlaubte Mittel |
| transport.checkin_required | Bool | an | - | Anmeldepflicht |
| transport.live_during | Bool | an | - | Live während Fahrt |
| transport.live_after_base_minutes | Zahl | 10 | 0-120 | Nachlauf |
| transport.live_after_increment_minutes | Zahl | 5 | 0-60 | Zuwachs je Fahrt |
| transport.ferry_max_stops_per_day | Zahl | 10 | 0-100 | Fähren-Limit |
| transport.forbidden_in_zone_types | Liste | leer | Zonentypen | Verbot (Bangkok: center) |
| transport.violation_repeat_minutes | Zahl | 10 | 1-60 | Wiederholungsverstoss |
| transport.speed_threshold_kmh | Zahl | 8 | 5-25 | Erkennung |
| transport.detect_seconds | Zahl | 90 | 30-600 | Erkennungsdauer |
| budget.enabled | Bool | an | - | Modul |
| budget.currency | Auswahl | USD | ISO 4217 | Währung |
| budget.daily_amount | Zahl | 30 | 0-1000 | Tagesbudget |
| budget.start_amount | Zahl | 30 | 0-1000 | Startbudget |
| budget.allow_saving | Bool | aus | - | Ansparen |
| budget.reveal_amount | Bool | aus | - | Betrag an Taskforce |
| budget.ping_delay_minutes | Zahl | 0 | 0-60 | Verzögerung Kauf-Ping |
| budget.receipt_photo_required | Bool | aus | - | Belegfoto |
| joker.enabled | Bool | aus (NY), an (Bangkok) | - | Modul |
| joker.per_day | Zahl | 1 | 0-5 | Pro Tag |
| joker.selection | Auswahl | zufall | spieler_waehlt, zufall, fest_pro_tag | Vergabe |
| joker.carry_over | Auswahl | einen_tag | nie, einen_tag, unbegrenzt | Aufheben |
| joker.max_inventory | Zahl | 2 | 1-10 | Max. im Besitz |
| joker.types | Liste | regeneration 240, hunter_erfragen, catch_free 180 | Katalog | Aktive Joker |
| bonus.enabled | Bool | an | - | Modul |
| bonus.expire_at_day_reset | Bool | an | - | Verfall |
| bonus.fake_ping_max_distance_m | Zahl | 3000 | 100-20000 | Fake-Ping-Radius |
| bonus.fake_ping_chooser | Auswahl | spieler | spieler, spielleitung | Wer wählt |
| bonus.hotel_minutes | Zahl | 360 | 10-720 | Hotel-Dauer |
| bonus.hotel_radius_m | Zahl | 50 | 10-200 | Hotel-Radius |
| bonus.hotel_pings | Auswahl | weiter | weiter, pausiert | Pings im Hotel |
| challenge.enabled | Bool | an | - | Modul |
| challenge.per_day | Zahl | 1 | 0-10 | Pro Tag |
| challenge.announce_before_minutes | Zahl | 60 | 0-720 | Ankündigung |
| challenge.suspend_proximity_before/after | Zahl | 60/60 | 0-240 | Teambildungsregel aus |
| proximity.enabled | Bool | an | - | Modul |
| proximity.distance_m | Zahl | 250 | 10-2000 | Abstand |
| proximity.active_after_minutes | Zahl | 60 | 0-600 | Ab Start |
| proximity.hysteresis_m | Zahl | 50 | 0-500 | Hysterese |
| proximity.repeat_minutes | Zahl | 0 | 0-120 | Wiederholung |
| taskforce.hq_required | Bool | an | - | Zentrale besetzt |
| taskforce.daily_briefing | Bool | aus (NY), an (Wien/Bangkok) | - | Einsatzbesprechung |
| taskforce.bounty_per_catch | Zahl | 1000 | 0-100000 | Kopfgeld |
| taskforce.share_positions_internally | Bool | an | - | Hunter sehen sich |
| exit.enabled | Bool | an | - | Exitpoint |
| exit.radius_m | Zahl | 30 | 5-500 | Radius |
| exit.reveal_minutes_before_end | Zahl | 120 | 0-1440 | Bekanntgabe |
| exit.reveal_to_taskforce | Auswahl | gleichzeitig | gleichzeitig, verzoegert, nie | Taskforce |
| exit.arrival_deadline_offset_minutes | Zahl | 15 | 0-120 | Ankunftsfrist |
| exit.confirm | Auswahl | geofence | geofence, qr, spielleitung | Bestätigung |
| exit.missed_policy | Auswahl | verloren | verloren, gewonnen_ohne_exit | Nicht angekommen |
| win.mode | Auswahl | alle_ueberlebenden | alle_ueberlebenden, letzter_ueberlebender, punkte | Siegmodus |
| win.prize | Text | 5000 EUR | - | Anzeige Preis |
| penalty.auto_apply_delay_seconds | Zahl | 60 | 0-600 | Auto-Strafe |
| penalty.escalation | Liste | verwarnung, straf_speedhunt, disqualifikation | - | Eskalation |
| penalty.after_game_end | Bool | aus | - | Nachträgliche Strafen |
| safety.emergency_pauses | Auswahl | person | person, alle | Notfall-Wirkung |
| safety.min_age | Zahl | 16 | 0-99 | Mindestalter |
| safety.battery_warn_percent | Zahl | 25 | 5-50 | Akkuwarnung |
| tracking.sample_interval_seconds | Zahl | 15 | 5-120 | GPS-Intervall |
| tracking.signal_loss_max_minutes | Zahl | 15 | 1-120 | Signalverlust |
| communication.player_to_player | Bool | aus | - | Spieler-Chat |
| spectator.enabled | Bool | aus | - | Zuschauer |
| spectator.delay_minutes | Zahl | 30 | 0-240 | Verzögerung |
| documentation.required_minutes_per_day | Zahl | 0 | 0-1440 | Filmpflicht |
| equipment.personal_items_max | Zahl | 2 | 0-10 | Gegenstände |
| privacy.retention_days | Zahl | 30 | 1-365 | Datenlöschung |
| start.hq_min_distance_m | Zahl | 300 | 0-10000 | Mindestabstand HQ zu Treffpunkt |
| start.hq_radius_m | Zahl | 100 | 20-1000 | HQ-Kreis |
| start.hunters_must_stay_in_hq | Bool | an | - | Hunter im HQ während Vorsprung |
| lobby.open_minutes_before | Zahl | 60 | 5-1440 | Lobby öffnet vor Start |
| lobby.min_battery_percent | Zahl | 60 | 0-100 | Akku für Startfreigabe |
| ping.max_age_seconds | Zahl | 60 | 10-600 | Frische-Regel |
| ping.fresh_fix_wait_seconds | Zahl | 30 | 5-120 | Wartezeit auf frischen Standort |
| ping.show_suppressed_to_taskforce | Bool | aus | - | "Kein Signal" anzeigen |
| ping.fade_after_minutes | Zahl | 60 | 5-600 | Verblassen der Marker |
| ping.history_per_player | Zahl | 5 | 1-50 | Sichtbare Pings pro Spieler |
| ping.reveal_schedule_to_taskforce | Bool | an | - | Nächster Ping-Zeitpunkt sichtbar |
| catch.track_after_catch | Bool | aus | - | Ortung nach Fang weiter |
| zone.restricted_counts_as_outside | Bool | aus | - | Sperrzone = ausserhalb |
| zone.restricted_crossing_max_seconds | Zahl | 60 | 0-600 | Überqueren erlaubt |
| exit.random_from_candidates | Bool | an | - | Exit zufällig aus Kandidaten |
| group.members_can_create_games | Bool | aus | - | Mitglieder dürfen Spiele anlegen (Gruppeneinstellung) |
| roles.balanced_random | Bool | an | - | Ausgeglichene Zufallsverteilung |
| account.require_verified_email | Bool | an | - | Bestätigte E-Mail Pflicht |

# 9. Voreinstellungen (Presets)

Presets setzen alle Parameter auf einmal. Danach kann jeder Wert geändert werden. Die App MUSS mindestens diese Presets anbieten. Zeiten bei kurzen Presets sind bereits skaliert.

| Parameter | Original Wien | Original Bangkok | Original New York | Wochenende 24 h | Stadtabend 3 h | Schnell 90 min |
| Dauer | 72 h | 96 h | 96 h | 24 h | 3 h | 90 min |
| Spieltage / Länge | 3 x 24 h | 4 x 24 h | 4 x 24 h | 4 x 6 h | 4 x 45 min | 3 x 30 min |
| Spieler / Hunter (Vorschlag) | 5 / 5 | 8 / 7 | 9 / 7 | 6 / 3 | 4 / 2 | 3 / 1 |
| Vorsprung | 120 min | 60 min | 60 min | 30 min | 10 min | 5 min |
| Zonen | Sektion pro Spieler + Startzone | Sektionen + Center Zone | Kernzone + Aussenzone | Spielfeld + Kern | Ein Spielfeld | Ein Spielfeld |
| Ping-Intervall | 120 min | 120 / Center 60 | 120 / Kern 60 | 45 / Kern 30 | 15 min | 10 min |
| Speedhunts Tag 1 / danach | 1 / GM | 2 / GM | 3 / GM | 2 / 1 | 1 / 1 | 1 / 1 |
| Abfragen | 5 | 4 | 4 | 4 | 3 | 3 |
| Max. Dauer Speedhunt | 90 min | 90 min | 90 min | 45 min | 15 min | 8 min |
| Silent im Speedhunt | aussetzen | weiter | weiter | weiter | weiter | weiter |
| 45-min-Regel / LEO | an / an | aus / aus | aus / aus | aus / aus | aus / aus | aus / aus |
| Max. 1 Speedhunt pro Spieler/Tag | an | aus | aus | aus | aus | aus |
| Nicht 2x gleiches Ziel / parallel 2 | aus | aus | an | an | an | aus |
| Fahrzeug-Live 60 s | aus | aus | an | an | an | aus |
| Fang streicht Speedhunt | aus | aus | an | an | aus | aus |
| Ausserhalb: Limit / Folge | sofort sichtbar, 120 / catch | 120 / catch | 120 / disqualify | 30 / catch | 5 / catch | 3 / catch |
| Verschanzen / Abstand / Sperre | 120 / 100 m / aus | 120 / 100 m / aus | 120 / 200 m / 480 | 30 / 150 m / 120 | 8 / 100 m / 30 | 5 / 75 m / aus |
| ÖV | erlaubt | Center: Verbot; Zone: meldepflichtig | meldepflichtig, Live + 10 / +5 min | meldepflichtig, Live + 5 / +2 | Live + 2 / +1 | verboten |
| Budget | aus | aus | 30 USD/Tag | 10 CHF/Tag | aus | aus |
| Joker | aus | 1/Tag (Reg. 240, Catch-Free 180) | aus | 1/Tag (Reg. 60, Catch-Free 45) | 1/Tag (Reg. 15, Catch-Free 10) | 1 gesamt (Reg. 8) |
| Boni (Fake-Ping, Hotel) | aus | an (Hotel 360) | aus | an (Hotel 60) | an (Hotel 15) | aus |
| Challenges | aus | 1/Tag | 1/Tag | 1/Tag | 1/Tag (kurz) | aus |
| Teambildungs-Alarm | aus | aus | 250 m ab 60 min | 200 m ab 30 min | 150 m ab 10 min | 100 m ab 5 min |
| Zone frei bei Fang | an | an | aus | aus | aus | aus |
| Spielfeld | wird grösser gegen Ende | täglich kleiner | täglich kleiner, Ankündigung 3 h | täglich -20 % | je Spieltag -15 % | aus |
| Exitpoint | aus (Überleben genügt) | aus | an, Frist +15 min | an, 60 min vorher | an, 20 min vorher | aus |
| Kopfgeld pro Fang | - | 1000 | 1000 | Punkte | Punkte | Punkte |

Hinweis (v1.1): Die kurzen Presets (Wochenende, Stadtabend, Schnell) setzen time.align_to_full_hour und ping.align_to_full_hour automatisch auf aus; Pings und Tagesresets zählen dort ab Jagdbeginn (siehe Durchlauf in Kapitel 24).

Weitere Presets KANN: "Original Saigon" (sobald Regelwerk bekannt), "Kids/Schulgelände" (keine Fahrzeuge, Fang nur per QR, kurze Zeiten, Sperrzonen Strassen), "Fahrrad-Manhunt" (grosse Fläche, alle auf dem Velo).

Benutzerdefinierte Presets: Host kann eigene Einstellungen als Preset speichern, teilen (Link/QR) und importieren (JSON).

# 10. App-Funktionen und Bildschirme

## 10.1 Allgemein

- Onboarding: Konto per E-Mail-Link, Apple, Google oder als Gast mit Anzeigename. Profilbild optional. Vollständige Regeln für Registrierung, Anmeldung, Geräte und Konto-Verwaltung: Kapitel 20 (Gäste nur als Zuschauer und im Probelauf).
- Unterste Navigationsleiste: Start, Gruppen, Spiele, Profil. Während eines laufenden Spiels öffnet die App direkt den Spielbildschirm der eigenen Rolle.
- Gruppen, Freunde und Einladungen: Kapitel 21.
- Startseite: "Spiel erstellen", "Spiel beitreten" (Code/QR/Link), "Meine Spiele", "Regeln lernen" (interaktives Tutorial).
- Berechtigungs-Assistent: Standort "Immer erlauben", genaue Position, Mitteilungen (inkl. kritische Mitteilungen auf iOS, falls verfügbar), Akku-Optimierung ausschalten (Android), Kamera (QR).

## 10.2 Host / Spielleitung

- Karten-Editor, Sperrzonen und Prüfungen im Detail: Kapitel 22. Gerätecheck in der Lobby: Kapitel 23.1.
- Setup-Assistent in Schritten: Preset wählen -> Dauer und Spieltage -> Rollen und Anzahl -> Spielfeld zeichnen (Zonen, Sektionen, Sperrzonen, Startzone, Exitpoint, Verkleinerungsplan je Tag) -> Regeln (alle Module mit Schaltern und Werten, Erklärtexte, "Original"-Badges) -> Challenges planen (Vorlagen) -> Zusammenfassung (lesbares Regelblatt, als PDF exportierbar) -> Einladen.
- Lobby: Liste der Teilnehmer mit Bereitschaftsstatus (GPS ok, Akku, Berechtigungen, Regeln bestätigt). Rollen per Drag-and-drop. "Spiel starten".
- Spielleitungs-Cockpit (Tablet/Desktop optimiert, auch Web): Karte mit allen Livestandorten, Hunter, Zonen, Pings; Zeitleiste der Ereignisse; Panels: Spieler (Status, Akku, Effekte, Budget, Joker), Speedhunts (Kontingent, laufend, Freigaben), Verstoss-Fälle (entscheiden), Challenges (starten, auswerten), Nachrichten, Live-Regeländerungen, Pause/Notfall, Fänge annullieren, Spieler zurück ins Spiel holen.

## 10.3 Spieler

- Hauptkarte: eigene Position, erlaubte Zone(n), Sperrzonen, nächste Zonenänderung, Distanz zur Zonengrenze, Exitpoint (wenn bekannt), Verstecke mit Sperrkreisen.
- Kopfzeile: Spielzeit verbleibend, Spieltag, Countdown bis Tagesreset, Status-Chips (Im Spielfeld / Ausserhalb mit Timer, Transport, Verschanzt mit Timer, Geschützt mit Timer, LEO).
- Speedhunt-Banner (rot, pulsierend, laut): "SPEEDHUNT läuft - Abfrage 2 von 4".
- Aktionen: "Transport starten/verlassen", "Ich bin drinnen (Verschanzen)", "Einkauf erfassen", "Joker einsetzen", "Bonus einsetzen", "Challenge", "QR-Code zeigen" (für Fang), "Notfall".
- Inventar: Joker und Boni mit Ablaufzeit.
- Budget: Kontostand, Liste der Käufe.
- Nachrichten: Ankündigungen, Spielleitung.
- Regeln: das aktive Regelblatt dieses Spiels.
- Wichtig: Der Spieler sieht keine Pings, keine Hunter (ausser durch Joker) und nicht, wer Ziel eines Speedhunts ist.

## 10.4 Hunter und Einsatzzentrale

- Hunter-Karte: alle freigegebenen Pings (mit Alter in Minuten, Farbe pro Spieler, verblassend mit Alter), Livestandorte in Live-Fenstern (mit Ablauf-Countdown), andere Hunter live, Zonen, Exitpoint, Kauf-Pings mit Kategorie, Teambildungs-Alarme.
- Spielerliste: Name, Foto, letzter Ping (Zeit, Ort), Status (frei/gefangen), Speedhunt-Verfügbarkeit (gesperrt wegen Regel X).
- Speedhunt-Steuerung (Zentrale oder alle Hunter, einstellbar): Ziel wählen (nicht erlaubte Ziele ausgegraut mit Grund), starten, Abfrage-Knopf mit verbleibenden Abfragen, Timer.
- "Gefangen"-Knopf (QR-Scanner / Bestätigung).
- Taskforce-Chat, Einsatzbesprechung bestätigen, "In der Zentrale"-Schalter, Pause-Schalter.
- Distanz- und Laufzeit-Schätzung vom eigenen Standort zum Ping (Fussweg).

## 10.5 Zuschauer und nach dem Spiel

- Zuschauer: verzögerte Gesamtsicht, Ereignis-Ticker.
- Ergebnis: Sieger, Kopfgeld, Statistiken, Replay mit Zeitregler (Wiedergabe 1x bis 600x), alle Pings und Fänge, Export JSON/GPX.

# 11. Benachrichtigungen (Ereigniskatalog)

| Ereignis | Empfänger | Beispieltext | Priorität |
| Spiel startet / Vorsprung | alle | "Die Flucht beginnt! Hunter starten in 60 min." | hoch |
| Jagd beginnt | alle | "Die Taskforce ist unterwegs." | hoch |
| Silent-Ping | Taskforce (+ GM) | "Ping: Spieler 3, 14:00, Kernzone" | normal |
| Speedhunt Start | alle Spieler (anonym), Taskforce (mit Ziel) | "SPEEDHUNT! Einer von euch wird gejagt." | kritisch |
| Speedhunt Abfrage | alle Spieler (anonym), Taskforce | "Abfrage 2 von 4" | hoch |
| Speedhunt Ende | alle | "Speedhunt beendet." | normal |
| Ausserhalb Spielfeld | Spieler, Taskforce (Live), GM | "Du bist ausserhalb! 118 min bis Disqualifikation." | kritisch |
| Verschanzen-Warnung | Spieler | "Noch 10 min, dann musst du raus (200 m Abstand)." | hoch |
| Transport-Verdacht | Spieler, GM | "Du bist schnell unterwegs. Transport anmelden?" | hoch |
| Kauf-Ping | Taskforce | "Kauf: Spieler 5, Essen, 15:42" | normal |
| Teambildungs-Alarm | Taskforce, beteiligte Spieler | "Spieler 2 und 7 sind unter 250 m." | hoch |
| Joker vergeben / läuft ab | Spieler | "Neuer Joker: Catch-Free (3 h)." | normal |
| Zone wird verkleinert (Ankündigung) | alle | "Neues Spielfeld ab 06:00. Karte ansehen." | hoch |
| Zone aktiv | alle | "Das Spielfeld ist jetzt kleiner." | hoch |
| Challenge angekündigt / startet | Spieler (+ Taskforce je nach Challenge) | "Challenge: Tresor-Überfall um 14:00." | hoch |
| Fang | alle | "Spieler 4 wurde gefangen. 6 frei." | hoch |
| Regelverstoss / Strafe | betroffener Spieler, GM, ggf. Taskforce | "Strafe: Speedhunt wegen nicht angemeldeter Fahrt." | hoch |
| Exitpoint bekannt | alle (Taskforce je nach Einstellung) | "Exitpoint: Bahnhofplatz. Ankunft bis 18:15." | kritisch |
| Notfall | GM, alle Hunter | "NOTFALL: Spieler 6. Jagd pausiert." | kritisch |
| Akku niedrig / Signalverlust | GM (+ Spieler) | "Spieler 1: Akku 14 %." | hoch |
| Spielende | alle | "Spielende! Sieger: ..." | hoch |

Alle Texte sind als Vorlagen mit Platzhaltern hinterlegt und mehrsprachig (Deutsch zuerst, Englisch).

# 12. Technische Architektur und empfohlener Stack

Empfehlung (modern, plattformübergreifend, eine Codebasis):

| Bereich | Empfehlung | Begründung |
| Mobile App | React Native mit Expo (TypeScript), Expo Router | iOS und Android aus einer Codebasis, schnelle Entwicklung, OTA-Updates |
| Karten | MapLibre (react-native-maplibre) mit Vektor-Tiles (z. B. MapTiler oder Stadia), alternativ Mapbox | Polygone, Heatmaps, Offline-Kacheln |
| Hintergrund-Ortung | expo-location mit TaskManager (Background Location), Foreground-Service auf Android; alternativ react-native-background-geolocation (Transistorsoft, kommerzielle Lizenz) für maximale Zuverlässigkeit | Spiel braucht Ortung bei gesperrtem Bildschirm |
| UI | Tamagui oder NativeWind (Tailwind), dunkles Design, Reanimated für Animationen | Modern, performant |
| Zustand Client | TanStack Query + Zustand | Server-State und lokaler State getrennt |
| Backend | Supabase: Postgres + PostGIS, Auth, Realtime (Broadcast/Presence), Storage, Row Level Security | Geodaten, Echtzeit, Rechteverwaltung in einem |
| Spiel-Engine | Eigener Node.js/TypeScript-Dienst (z. B. auf Fly.io oder Railway) mit persistierten Timern in Postgres (Tabelle scheduled_jobs, Abarbeitung mit SELECT ... FOR UPDATE SKIP LOCKED) | Server-autoritativ, präzise Timer, überlebt Neustarts |
| Push | Expo Notifications (APNs/FCM), kritische Mitteilungen iOS mit Entitlement (sonst zeitkritisch) | Speedhunt-Alarme |
| Web-Cockpit | Next.js (React) für Spielleitung/Zentrale am Laptop, gleiche API | Grosse Karte |
| Validierung | Zod-Schemas, geteilt zwischen App, Engine und Web (Monorepo mit pnpm + Turborepo) | Ein Konfigurationsschema überall |
| Tests | Vitest (Engine-Logik), Playwright (Web), Maestro oder Detox (App), Simulator für GPS-Spuren | Regeln sind testbar |
| Beobachtung | Sentry, strukturierte Logs | Fehler im Feld finden |
| Konten | Supabase Auth (E-Mail + Passwort, Magic Link, Apple, Google), expo-auth-session, expo-apple-authentication, expo-secure-store | Kapitel 20 |
| E-Mails | Transaktions-E-Mails über Resend oder Postmark (Bestätigung, Passwort, Einladungen) | Zustellbarkeit |
| Deep Links | Universal Links (iOS) und App Links (Android) für Einladungen, Fallback-Webseite mit Store-Links | Kapitel 21.3 |
| Cache | Redis (z. B. Upstash) für aktuelle Positionen und Rate-Limits | schnelle Ping-Erzeugung |
| Offline-Karten | MapLibre Offline-Packs für das Spielfeld | Kapitel 22.6 |
| Lokale Warteschlange | expo-sqlite für gepufferte Standorte und Aktionen | Kapitel 23.2 |
| OSM-Daten | Overpass API (Sperrzonen-Vorschläge), Nominatim/Photon (Adresssuche) | Kapitel 22 |

Architekturprinzipien (MUSS):
- Server-autoritativ: Clients senden nur Rohdaten (Standorte, Aktionen). Alle Regelentscheidungen (Ping fällig, innerhalb Zone, Fang gültig, Strafe) trifft die Engine.
- Ereignisbasiert: Jede Zustandsänderung ist ein unveränderliches Ereignis in game_events (Event Sourcing light). Daraus entstehen Replay und Statistik.
- Idempotente Aktionen mit Client-Request-ID (doppelte Taps, schlechte Verbindung).
- Offline-Toleranz: Client puffert Standorte und Aktionen und sendet sie nach (mit Original-Zeitstempel). Die Engine bewertet nachgereichte Standorte rückwirkend nur für Statistik, nicht für bereits ausgelieferte Pings.
- Uhrzeit: Server-Zeit ist massgeblich; Client zeigt Countdowns anhand eines gemessenen Zeitversatzes.
- Echtzeit-Kanäle pro Rolle (game:{id}:players, game:{id}:taskforce, game:{id}:gm, user:{id}) mit RLS, damit niemand fremde Kanäle abonniert.

# 13. Datenmodell (Tabellen)

| Tabelle | Wichtige Felder |
| users | id, display_name, avatar_url, created_at |
| profiles (v1.1, ergänzt users) | user_id, username (eindeutig), bio, birth_year oder age_confirmed, emergency_contact_name, emergency_contact_phone (verschlüsselt), locale, units, stats_visibility, deleted_at |
| consents | id, user_id, kind (agb, datenschutz, standort), version, accepted_at |
| devices | id, user_id, platform, model, app_version, push_token, last_seen_at, is_game_device_for (game_id) |
| friendships | user_a, user_b, status (angefragt, angenommen, blockiert), created_at |
| groups | id, name, image_url, description, home_location, visibility (privat, auffindbar), owner_id, settings_json, created_at |
| group_members | group_id, user_id, role (besitzer, admin, mitglied), joined_at, status (aktiv, entfernt, gesperrt) |
| invites | id, code, kind (gruppe, spiel), target_id, created_by, expires_at, max_uses, uses, revoked |
| game_rsvps | game_id, user_id, status (zugesagt, abgesagt, warteliste), wished_role |
| map_templates | id, group_id, name, geojson, created_by, updated_at |
| rule_presets | id, group_id (oder null für eingebaute), name, config_json, created_by |
| device_checks | id, participant_id, check, status, details, at |
| reports | id, reporter_id, target_user_id, reason, at, status |
| games | id, group_id, host_id, meeting_point, name, status (entwurf, geplant, lobby, vorsprung, laeuft, pausiert, finale, beendet, archiviert), config_json, config_version, start_at, ends_at, current_day, timezone |
| game_config_changes | id, game_id, changed_by, path, old_value, new_value, at |
| participants | id, game_id, user_id, role (spieler, hunter, zentrale, gm, zuschauer), state, effects_json, section_zone_id, color, joined_at, ready_flags |
| zones | id, game_id, name, type, geometry (PostGIS MultiPolygon), valid_from, valid_to, day_index, ping_interval_override, rules_json, owner_participant_id |
| location_samples | id, participant_id, at, geom (Point), accuracy_m, speed_mps, heading, battery, is_mock, source |
| pings | id, game_id, participant_id, at, geom, accuracy_m, source (silent, speedhunt, purchase, transit, proximity, fake, hotel_end, out_of_bounds, penalty, gm), zone_id, is_fake, real_geom (nur GM), speedhunt_id |
| live_windows | id, participant_id, reason, starts_at, ends_at |
| speedhunts | id, game_id, target_id, day_index, triggered_by, is_penalty, status, queries_total, queries_used, started_at, ended_at, end_reason |
| speedhunt_queries | id, speedhunt_id, n, requested_by, at, ping_id |
| hideouts | id, participant_id, center geom, entered_at, left_at, locked_until, detection |
| transit_sessions | id, participant_id, mode, line, from_station, to_station, started_at, ended_at, live_after_minutes |
| purchases | id, participant_id, amount, currency, category, at, geom, receipt_url |
| budget_ledger | id, participant_id, day_index, delta, reason, balance_after |
| inventory_items | id, participant_id, kind (joker, bonus), type, granted_at, expires_at, used_at, params_json |
| active_effects | id, participant_id, type, starts_at, ends_at, source_item_id |
| challenges | id, game_id, template, title, description, geom, starts_at, ends_at, rewards_json, proof_type, status |
| challenge_entries | id, challenge_id, participant_id, joined_at, proof_url, result, rank |
| catches | id, game_id, runner_id, hunter_id, at, geom, method, media_url, status (gueltig, abgelehnt, annulliert), reason |
| violations | id, game_id, participant_id, type, detected_by (auto, gm, meldung), at, evidence_json, proposed_penalty, decided_penalty, status |
| penalties | id, violation_id, type, params_json, applied_at |
| messages | id, game_id, channel, sender_id, body, attachments, at |
| game_events | id, game_id, at, type, actor_id, payload_json (unveränderlich) |
| scheduled_jobs | id, game_id, run_at, kind, payload_json, status, attempts |
| emergencies | id, participant_id, at, geom, status, resolved_by, resolved_at |

# 14. Spiel-Engine: Timer, Reihenfolge und Konfliktregeln

## 14.1 Timer (scheduled_jobs)

Ping fällig (pro Spieler), Speedhunt-Timeout, LEO-Ende, Effekt-Ende (Joker/Bonus), Verschanzen-Warnungen und -Limit, Ausserhalb-Limit, Transport-Nachlauf-Ende, Tagesreset, Zonen-Ankündigung, Zonen-Aktivierung, Challenge-Start/Ende, Exitpoint-Bekanntgabe, Ankunftsfrist, Spielende, Random-Speedhunt, Zentrale-leer-Warnung, Auto-Strafe. Alle Timer werden bei Pause verschoben (Restzeit gespeichert) und bei Fortsetzung neu geplant.

## 14.2 Standortverarbeitung (bei jedem Standort-Sample)

1. Plausibilität: is_mock (Android-Mock-Location) -> Verdachtsfall. Sprünge > 200 km/h verwerfen.
2. Zonenprüfung (mit Toleranz) -> ausserhalb starten/beenden.
3. Sperrzonen-Prüfung.
4. Geschwindigkeit -> Transport-Erkennung.
5. Stillstand -> Verschanzen-Erkennung; Versteck-Abstand prüfen.
6. Nähe zu anderen Spielern -> Teambildungs-Alarm.
7. Exit-Radius -> Ankunft.
8. Live-Fenster aktiv -> Livestandort an Taskforce-Kanal weitergeben.

## 14.3 Prioritäten bei Konflikten (verbindlich)

1. Pause und Notfall schlagen alles: keine Pings, keine Fänge, keine Strafen-Timer.
2. Spieler im Ziel (im_ziel), gefangen, disqualifiziert oder aufgegeben: keine Pings mehr.
3. Regenerations-Joker: unterdrückt Silent-Pings, Teambildungs-Pings (seine Position) und verhindert Speedhunt-Start auf ihn. Läuft bereits ein Speedhunt auf ihn, wenn er den Joker einsetzen will: Joker-Einsatz ist während eines Speedhunts nicht erlaubt (Knopf ausgegraut, da der Spieler nicht weiss, dass er das Ziel ist, lautet der Hinweis nur "Joker im Moment nicht einsetzbar"). Straf-Speedhunts werden bis zum Jokerende aufgeschoben. Präzisierung (v1.1): Damit der Spieler aus dem gesperrten Knopf nicht ablesen kann, dass er das Ziel ist, ist der Regenerations-Joker für ALLE Spieler gesperrt, solange irgendein Speedhunt läuft. Bei der Taskforce erscheint ein geschützter Spieler in der Zielauswahl nur als "derzeit nicht wählbar", ohne Grund.
4. LEO: unterdrückt nur Silent-Pings.
5. Catch-Free und Hotel: verhindern nur den Fang; Pings laufen (ausser bonus.hotel_pings = pausiert).
6. Fake-Ping: ersetzt genau den nächsten Ping der gewählten Art; wird dieser Ping durch 2. bis 4. unterdrückt, bleibt der Fake-Ping scharf bis zum nächsten tatsächlichen Ping oder bis Tagesreset (dann verfällt er, wenn bonus.expire_at_day_reset).
7. Live-Fenster (ausserhalb, Transport, Fahrzeug im Speedhunt, Hotel-Ende) gelten unabhängig von LEO, ausser Regenerations-Joker mit regeneration.suppresses_live = an.
8. Mehrere Live-Fenster gleichzeitig: Das Ende ist das späteste.
9. Zwei Timer zum gleichen Zeitpunkt: Reihenfolge Tagesreset -> Zonenaktivierung -> Effekt-Enden -> Pings -> Speedhunt-Timeouts -> sonstige.
10. Spieler ausserhalb wegen Zonenverkleinerung: Übergangsfrist gilt; Live-Sichtbarkeit beginnt erst nach Ablauf der Frist.
11. Fang zum gleichen Zeitpunkt wie Ankunft am Exit: Fang gilt nur, wenn sein Zeitstempel (Server) vor der Ankunft liegt.
12. Speedhunt-Kontingent eines Tages darf durch "Fang streicht einen" nicht unter 0 fallen.
13. Unklare Fälle ohne menschliche Spielleitung: zugunsten des Spielers entscheiden und als Fall protokollieren.

## 14.4 Ping-Berechnung (Pseudocode)

```
on ping_due(player):
  if game.paused or player.state not in [aktiv, ausserhalb, im_transit, verschanzt, geschuetzt]: return
  if has_effect(player, regeneration) or has_effect(player, leo): schedule_next(player); return
  if config.ping.during_speedhunt == "aussetzen" and active_speedhunt_on(player): schedule_next(player); return
  pos = median_position(player, last 30s) or last_known(player)
  if armed_fake_ping(player, kind="silent"): pos = fake.pos; consume(fake)
  create_ping(player, pos, source="silent")
  publish(taskforce, ping); publish(gm, ping)
  schedule_next(player)   # Intervall der Zone, in der sich der Spieler JETZT befindet, ausgerichtet auf volle Stunde falls aktiv
```

# 15. Ortung, Akku und Fairness

- Standort-Intervall tracking.sample_interval_seconds (15 s) im Spiel, adaptiv: bei Stillstand 60 s, bei Live-Fenster 5 s.
- Akku-Ziel: unter 8 % Verbrauch pro Stunde auf einem aktuellen Mittelklassegerät (SOLL). Hinweis im Briefing: Powerbank mitnehmen.
- Signalverlust: Kommen länger als tracking.signal_loss_max_minutes keine Daten, erhält die Spielleitung eine Meldung; für Pings gilt die letzte bekannte Position mit Zeitstempel ("veraltet seit 12 min"). Wiederholter Verlust = Verdachtsfall "Tracker gestört".
- Anti-Cheat (SOLL): Mock-Location-Erkennung (Android isMock, iOS-Simulator), Zeitmanipulation (Serverzeit), App im Hintergrund beendet (Heartbeat alle 60 s; fehlt er, Push "Öffne die App").
- Genauigkeit: Pings zeigen den Genauigkeitsradius; schlechte Genauigkeit (> 100 m) wird markiert.

# 16. Datenschutz, Sicherheit und Recht

- DSGVO und Schweizer DSG: Einwilligung vor Spielbeginn, klare Anzeige, wer wann den Standort sieht. Standortdaten nur während laufender Spiele. Automatische Löschung nach privacy.retention_days. Export und Löschung auf Wunsch.
- Row Level Security für jede Tabelle nach Rolle; Pings mit is_fake/real_geom nur für GM lesbar.
- Keine Weitergabe an Dritte; keine Werbung mit Standortdaten.
- Haftungshinweis und Sicherheitsregeln vor jedem Spiel bestätigen. Hinweis: Teilnahme auf eigenes Risiko, Gesetze und Verkehrsregeln gelten, öffentliche Ordnung respektieren, Unbeteiligte nicht belästigen.
- Marken: Die App darf nicht "Manhunt" von Manhunt Media als Namen/Logo verwenden ohne Erlaubnis. Arbeitstitel z. B. "Hunt Mode", "Fluchtspiel", "Taskforce". Inhalte (Regeln) sind als Spielmechaniken nachgebaut, nicht kopiert.

# 17. Nicht-funktionale Anforderungen und Design

- Plattformen: iOS 16+, Android 10+, Web-Cockpit (aktuelle Browser).
- Sprachen: Deutsch (Standard), Englisch; alle Texte in i18n-Dateien.
- Design: dunkles, taktisches Design (Nachtspiel), Akzentfarben Rot (Speedhunt, Gefahr), Gelb (Warnung), Grün (sicher), grosse Touch-Ziele (mind. 48 px), lesbar im Sonnenlicht, Haptik bei Alarmen, Barrierefreiheit (Screenreader-Labels, Kontrast AA).
- Leistung: Pings erreichen die Taskforce in unter 2 s nach Fälligkeit; Kartendarstellung 60 fps mit 100 Pings.
- Skalierung: 1 Engine-Instanz verarbeitet mindestens 200 gleichzeitige Spiele mit je 20 Teilnehmern.
- Zuverlässigkeit: Engine-Neustart verliert keine Timer; Clients reconnecten automatisch.
- Tests: Jede Regel aus Kapitel 7 hat automatisierte Tests mit simulierten GPS-Spuren und simulierter Zeit (Fake-Clock).

# 18. Akzeptanztests (Auswahl, MUSS bestehen)

| Nr. | Szenario | Erwartung |
| 1 | NY-Preset, Spieler in Kernzone um 13:00 | Ping um 14:00 an Taskforce, Spieler bekommt keine Meldung |
| 2 | Spieler wechselt um 13:30 in Aussenzone | Nächster Ping zur nächsten geraden Stunde (14:00), danach alle 2 h |
| 3 | Taskforce startet Speedhunt auf Spieler A | Alle Spieler: Speedhunt-Meldung ohne Ziel; Taskforce 4 Abfragen; nach 4 Abfragen oder 90 min Ende |
| 4 | Gleich danach Speedhunt erneut auf A (NY) | Abgelehnt: "nicht zweimal hintereinander", ausser nur noch 2 Spieler frei |
| 5 | Wien-Preset: Speedhunt 20 min nach Silent-Ping | Silent-Ping zählt als Abfrage 1, nur noch 4 Abfragen |
| 6 | Wien-Preset: nach Speedhunt-Ende 14:20 | Kein Silent-Ping für A bis 16:00 (Ende der nächsten vollen Stunde 15:00-16:00) |
| 7 | Spieler fährt U-Bahn ohne Anmeldung (Geschwindigkeit 30 km/h für 2 min) | Aufforderung an Spieler, danach Verstoss-Fall, Standardstrafe Straf-Speedhunt |
| 8 | Spieler meldet 3. ÖV-Fahrt am selben Tag | Live während Fahrt, Nachlauf 20 min (10 + 5 + 5); nach Tagesreset wieder 10 |
| 9 | Spieler 121 min ausserhalb (NY) | Disqualifikation; Taskforce sah die ganze Zeit Livestandort |
| 10 | Spieler 2 h verschanzt (NY) | Warnungen 30/10/2 min; bei 120 min Catch; Ort 200 m gesperrt; nach 8 h ab erstem Betreten dauerhaft gesperrt |
| 11 | Regenerations-Joker um 10:00 (240 min) | Keine Silent-Pings 10:00-14:00, kein Speedhunt auf ihn möglich (für Taskforce ausgegraut "nicht verfügbar"), Kauf-Ping weiterhin |
| 12 | Catch-Free aktiv, Hunter scannt QR | Fang abgelehnt mit Hinweis "Spieler ist geschützt" |
| 13 | Fake-Ping gesetzt, nächster Silent-Ping | Taskforce sieht Fake-Position, GM sieht beide |
| 14 | Hotel-Bonus 6 h | Nicht fangbar im Radius, danach Hotel-Ping an Taskforce, Spieler muss Ort verlassen |
| 15 | Zwei Spieler 200 m entfernt, 2 h nach Start | Teambildungs-Alarm an Taskforce mit beiden Positionen; beide Spieler sehen einander; kein neuer Alarm, bis > 300 m |
| 16 | Gleiche Situation während Challenge-Fenster | Kein Alarm |
| 17 | Kauf 8 USD bei Budget 5 USD | Abgelehnt |
| 18 | Tagesreset 06:00 | Budget 30 (kein Ansparen), neuer Joker, Boni verfallen, ÖV-Nachlauf 10, neues Spielfeld aktiv, Kontingent neu |
| 19 | Fang (NY) | Speedhunt-Kontingent heute minus 1; Meldung an alle |
| 20 | Spielende 96 h, Spieler kommt 06:10 am Exit an | Gewinner; Spieler kommt 06:16: verloren |
| 21 | Notfallknopf | Alarm an GM und Hunter, Jagd pausiert, Fänge auf diese Person gesperrt |
| 22 | 90-min-Preset mit 3 Spieltagen à 30 min | Tagesregeln (Joker, Kontingent) alle 30 min, Pings alle 10 min ab Spielstart |
| 23 | App 10 min ohne Netz | Standorte werden nachgereicht; Ping in dieser Zeit nutzt letzte bekannte Position, markiert als veraltet |
| 24 | GM ändert Ping-Intervall live auf 60 | Wirkung ab nächstem geplanten Ping, Änderung protokolliert, Taskforce informiert |
| 25 | Bangkok-Preset: Taxi in Center Zone 25 min | 3 Verstösse (0, 10, 20 min), 3 Straf-Speedhunts |
| 26 | Neue Person registriert sich per E-Mail | Bestätigungscode kommt, ohne Bestätigung kein Spielbeitritt; Notfallkontakt wird vor erstem Spiel verlangt |
| 27 | Einladungslink ohne installierte App | Store öffnet; nach Installation und Registrierung landet die Person direkt in der Gruppe/dem Spiel |
| 28 | Admin erstellt Gruppe, lädt 6 Personen per QR ein | Alle sind Mitglieder; Gruppenchat funktioniert; während eines Spiels ist er für Spieler stumm |
| 29 | Host versucht Spiel ohne Exitpoint (exit.enabled = an) zu starten | Start blockiert, Fehler im Karten-Editor markiert |
| 30 | Sperrzone über Treffpunkt gezeichnet | Fehler; Speichern als Entwurf möglich, Start nicht |
| 31 | "Gefahrenstellen vorschlagen" in einem Gebiet mit Autobahn und Gleisen | Vorschläge mit Puffer erscheinen, einzeln übernehmbar |
| 32 | Spieler betritt Sperrzone Gleise für 10 s auf einer Brücke mit "Überqueren erlaubt" | Kein Verstoss |
| 33 | Gerätecheck: Android-Gerät ohne Hintergrund-Standort | Ampel rot, Assistent führt zur Einstellung; Start erst nach Behebung oder Entfernen der Person |
| 34 | Silent-Ping fällig, letzter Punkt 4 min alt | Stille Push an Gerät, neuer Punkt innerhalb 30 s wird verwendet; sonst alter Punkt mit Markierung "veraltet seit 4 min" |
| 35 | App wird vom System beendet | Nach 3 min fehlendem Heartbeat Push an Spieler und Meldung an Spielleitung |
| 36 | Spieler wechselt Handy mitten im Spiel | Altes Gerät abgemeldet, neues sendet; Ping an Taskforce; Ereignis protokolliert |
| 37 | Konto löschen während laufendem Spiel | Nicht möglich, Hinweis |
| 38 | Kompletter Durchlauf aus Kapitel 24 mit simulierten Geräten | Alle Zeitpunkte und Sichtbarkeiten wie beschrieben |
| 39 | Host ist Spieler und Exit hat 3 Kandidaten | Host sieht den gewählten Exit erst zur Bekanntgabe |
| 40 | Konfiguration mit ping.interval 240 bei Spieldauer 180 | Fehler "keinen einzigen Ping", Start blockiert |

# 19. Umsetzungsreihenfolge

1. Fundament: Monorepo, Auth, Spiel anlegen/beitreten, Rollen, Lobby, Konfigurationsschema mit allen Parametern und Presets. Dazu (v1.1): Registrierung, Anmeldung, Profil, Geräte und Konto löschen (Kapitel 20); Gruppen, Einladungen, Freunde, Zusagen (Kapitel 21); Konfigurations-Validierung (Kapitel 25).
2. Ortung und Karte: Hintergrund-Ortung, Zonen-Editor, Zonenprüfung, Spieler- und Hunter-Karte. Dazu (v1.1): vollständiger Karten-Editor mit Sperrzonen, Prüfungen, Offline-Karten und Probelauf (Kapitel 22); Gerätecheck und Standort-Pipeline mit Frische-Regel (Kapitel 23).
3. Engine-Kern: Timer, Tagesreset, Silent-Pings, Live-Fenster, Ausserhalb, Pause, Notfall.
4. Speedhunt komplett (alle Regeln), Fang (QR + Bestätigung), Spielende und Exitpoint.
5. Verschanzen, Transport/ÖV, Budget und Käufe, Teambildungs-Alarm.
6. Joker, Boni, Challenges mit Vorlagen.
7. Strafen und Verstoss-Fälle, Spielleitungs-Cockpit (Web).
8. Kommunikation, Benachrichtigungen, Zuschauer, Replay und Statistik.
9. Feinschliff: Design, Tutorial, Barrierefreiheit, Akku-Optimierung, Store-Release.

# 20. Konten, Registrierung und Anmeldung

Jede Person braucht ein eigenes Konto, bevor sie einer Gruppe oder einem Spiel beitreten kann. Gastzugänge (10.1) sind KANN und nur für Probelauf und Zuschauer erlaubt. Für Spieler-, Hunter- und Spielleitungsrollen ist ein bestätigtes Konto Pflicht (MUSS), weil Standortdaten, Einwilligungen und Notfallkontakte an eine Person gebunden sein müssen.

## 20.1 Registrierung (MUSS)

| Schritt | Inhalt | Regeln |
| 1. Methode wählen | E-Mail + Passwort, "Mit Apple anmelden", "Mit Google anmelden" | Apple-Anmeldung ist auf iOS Pflicht, sobald Google angeboten wird (App-Store-Richtlinie). |
| 2. E-Mail bestätigen | Bestätigungslink oder 6-stelliger Code per E-Mail | Ohne Bestätigung kein Beitritt zu Spielen. Code 15 min gültig, erneut senden nach 60 s. |
| 3. Passwort | Mindestens 10 Zeichen, Prüfung gegen bekannte geleakte Passwörter (Supabase/HaveIBeenPwned-k-Anonymity) | Anzeige der Stärke. |
| 4. Benutzername | Eindeutiger @benutzername (3-20 Zeichen, a-z, 0-9, _ . ), Anzeigename frei | Benutzername dient zum Finden und Einladen. Änderung höchstens alle 30 Tage. |
| 5. Alter | Geburtsdatum oder Bestätigung "Ich bin mindestens 16" (safety.min_age) | Unter dem Mindestalter keine Registrierung. Unter 18: Hinweis auf Einverständnis der Eltern, Fangmethode handcuffs gesperrt. |
| 6. Profil | Profilbild (optional, Zuschneiden, max. 5 MB), Farbe/Avatar | Bild wird im Spiel als Marker benutzt (Hunter sehen es bei Pings). |
| 7. Notfallkontakt | Name und Telefonnummer einer Vertrauensperson | MUSS vor dem ersten Spiel als Spieler oder Hunter erfasst sein. Nur die Spielleitung des laufenden Spiels sieht ihn, und nur im Notfall. |
| 8. Einwilligungen | Nutzungsbedingungen, Datenschutz, Standortnutzung im Spiel | Versioniert gespeichert (Datum, Version). Neue Version = erneute Zustimmung. |
| 9. Berechtigungen | Mitteilungen; Standort wird erst beim ersten Spiel abgefragt | Erklärbildschirm vor jeder System-Abfrage. |

## 20.2 Anmeldung und Sitzung (MUSS)

- Anmeldung mit E-Mail + Passwort, Magic Link (Link per E-Mail), Apple oder Google. Mehrere Methoden können mit demselben Konto verknüpft werden (Einstellungen > Konto > Anmeldemethoden).
- "Passwort vergessen": Reset-Link per E-Mail, 30 min gültig. Danach werden alle anderen Sitzungen abgemeldet.
- Sitzungen bleiben angemeldet (Refresh-Token, sicher gespeichert in Keychain bzw. Android Keystore über expo-secure-store). Automatische Erneuerung im Hintergrund, damit Ortung im Spiel nie wegen abgelaufener Anmeldung abbricht.
- KANN: Zwei-Faktor-Anmeldung (TOTP) für Konten, die Spiele leiten.
- Schutz: Rate-Limit (5 Fehlversuche, dann 15 min Sperre pro Konto und IP), Captcha nach 3 Fehlversuchen (z. B. hCaptcha/Turnstile).
- Abmelden während eines laufenden Spiels: Warnung "Du bist im laufenden Spiel X. Wenn du dich abmeldest, wird deine Ortung gestoppt und das gilt als Regelverstoss (Tracker abgelegt)." Abmelden nur nach Bestätigung; die Spielleitung wird informiert.
- Wiedereinstieg: Nach Absturz, Neustart oder Neuinstallation meldet sich die Person an und landet automatisch im laufenden Spiel (Zustand wird vollständig vom Server geladen).

## 20.3 Geräte

- Ein Konto kann mehrere Geräte haben, aber pro laufendem Spiel ist genau ein Gerät das "Spielgerät" (sendet Standort, empfängt Alarme). Beim Spielbeitritt wird das aktuelle Gerät registriert (devices-Tabelle mit Push-Token, Plattform, App-Version).
- Gerätewechsel während des Spiels (Akku leer, Handy kaputt): Person meldet sich auf neuem Gerät an und tippt "Dieses Gerät als Spielgerät verwenden". Bei Spielern und Huntern braucht das die Freigabe der Spielleitung (bei Auto-Spielleitung: automatische Freigabe, aber Ping an Taskforce mit neuer Position, Ereignis wird protokolliert). Das alte Gerät wird sofort abgemeldet.
- Web-Cockpit (Spielleitung, Zentrale, Zuschauer) zählt nicht als Spielgerät und darf parallel offen sein.

## 20.4 Profil und Konto-Verwaltung

- Profil: Anzeigename, @benutzername, Bild, Kurzbeschreibung, Statistik (Spiele, Siege als Spieler, Fänge als Hunter, gelaufene km). Sichtbarkeit der Statistik: öffentlich, nur Gruppen, privat.
- Einstellungen: Sprache, Einheiten (km/mi), Kartenstil, Benachrichtigungen pro Kategorie (Speedhunt-Alarme lassen sich während eines Spiels nicht abschalten), Notfallkontakt, verknüpfte Anmeldemethoden, Geräte, Datenexport.
- Konto löschen (MUSS, App-Store-Pflicht): In der App erreichbar. Löscht Profil, Gruppenmitgliedschaften (Besitz von Gruppen muss vorher übertragen werden oder die Gruppe wird gelöscht), Standortdaten. In Spiel-Statistiken bleibt ein anonymer Eintrag "Gelöschte Person". Nicht möglich während eines laufenden Spiels.
- Datenexport: alle eigenen Daten als JSON/ZIP (DSG/DSGVO).
- Blockieren und Melden: Andere Konten blockieren (keine Einladungen, keine Nachrichten), Inhalte melden (Moderationsliste für Betreiber).

# 21. Gruppen, Freunde und Einladungen

Gruppen (in der App "Crew") sind feste Runden von Leuten, die öfter zusammen spielen. Ein Spiel gehört immer zu genau einer Gruppe; für einmalige Runden legt die App automatisch eine Gruppe an.

## 21.1 Gruppen (MUSS)

- Gruppe erstellen: Name (3-40 Zeichen), Bild, Beschreibung, Standard-Ort (Stadt, für Kartenvorschläge), Sichtbarkeit "privat" (nur mit Einladung, Standard) oder "auffindbar per Name".
- Rollen in der Gruppe:
| Rolle | Rechte |
| Besitzer | Alles, inkl. Gruppe löschen und Besitz übertragen. Genau 1. |
| Admin | Mitglieder einladen und entfernen, Spiele erstellen, Karten- und Regelvorlagen der Gruppe bearbeiten. |
| Mitglied | Spielen, Gruppenchat, Spiele vorschlagen. Darf Spiele erstellen, wenn group.members_can_create_games = an. |
- Mitglieder: maximal 200 pro Gruppe. Liste mit Profilbild, Rolle, Status (online, im Spiel).
- Gruppenchat (ausserhalb von Spielen). Während eines laufenden Spiels ist der Gruppenchat für Spieler stumm geschaltet (sonst wäre die Regel "keine Absprachen zwischen Spielern" umgehbar); Hinweis im Chat.
- Gruppenbereich zeigt: geplante und laufende Spiele, vergangene Spiele mit Replay, Bestenliste der Gruppe, gespeicherte Karten (21.4) und Regel-Presets der Gruppe.
- Verlassen, Entfernen, Sperren: Entfernte Personen verlieren Zugriff auf künftige Spiele; ihre Teilnahme an vergangenen Spielen bleibt in der Statistik.
- Besitzer verlässt die Gruppe: muss vorher den Besitz übertragen.

## 21.2 Freunde (SOLL)

- Personen per @benutzername oder QR-Code (Profil-QR) suchen und als Freund hinzufügen (Anfrage + Annahme).
- Freunde können direkt in Gruppen oder Spiele eingeladen werden.

## 21.3 Einladungen (MUSS)

| Weg | Ablauf |
| Einladungslink | https://<domain>/i/<code> öffnet die App (Universal Link/App Link) oder den Store. Gültigkeit einstellbar (1 h bis 30 Tage), maximale Anzahl Nutzungen, jederzeit widerrufbar. |
| QR-Code | Gleicher Link als QR, ideal am Treffpunkt. |
| 6-stelliger Code | Manuelle Eingabe unter "Beitreten". |
| Direkt | Über @benutzername oder Freundesliste, mit Push an die eingeladene Person. |
- Einladung kann auf Gruppe oder direkt auf ein Spiel lauten. Eine Spiel-Einladung macht die Person automatisch zum Gruppenmitglied (Rolle Mitglied) und meldet sie für das Spiel an.
- Beitritt ohne Konto: Link führt erst durch die Registrierung (20.1) und dann direkt in die Gruppe/das Spiel.
- Beitrittsanfragen: Bei "auffindbar"-Gruppen können Personen anfragen; Admin bestätigt.

## 21.4 Vorlagen der Gruppe

- Kartenvorlagen: Ein einmal gezeichnetes Spielfeld (mit Zonen, Sperrzonen, Startzone, Exitpoint-Kandidaten, Verkleinerungsplan) kann als Vorlage gespeichert und in neuen Spielen wiederverwendet werden.
- Regel-Presets: Eigene Presets (Kapitel 9) werden in der Gruppe gespeichert und sind für alle Admins nutzbar.
- Teilen: Vorlagen und Presets als Link/Datei (JSON) exportieren und in andere Gruppen importieren.

## 21.5 Vom Spiel-Anlegen bis zum Start (Ablauf)

1. Admin tippt in der Gruppe "Neues Spiel".
2. Setup-Assistent (10.2): Preset, Dauer, Rollen, Karte (Kapitel 22), Regeln, Challenges, Zusammenfassung.
3. Spiel wird "geplant" mit Startzeit und Treffpunkt. Alle Gruppenmitglieder erhalten eine Einladung mit Zusage/Absage (wie ein Termin, mit Kalender-Export .ics).
4. Wer zusagt, ist angemeldet. Max. Teilnehmer gemäss roles.players_max + roles.hunters_max + Spielleitung; weitere kommen auf eine Warteliste.
5. Rollen: Host verteilt Rollen, lässt die App zufällig verteilen (mit Option "ausgeglichen": berücksichtigt bisherige Rollen, damit nicht immer dieselben jagen) oder lässt Personen ihre Wunschrolle wählen und bestätigt.
6. Am Spieltag öffnet die Lobby (Standard 60 min vor Start). Jede Person durchläuft den Gerätecheck (23.1).
7. Startfreigabe erst, wenn alle Pflichtprüfungen grün sind oder der Host fehlende Personen aus dem Spiel nimmt.
8. Start (6.1): Vorsprung, dann Jagd.

# 22. Karten-Setup vor Spielbeginn

Vor dem Start muss die gesamte Karte festgelegt sein: Spielfeld, alle Zonen, Sektionen, Sperrzonen, Startzone, Hunter-Startpunkt (HQ), Exitpoint und der komplette Verkleinerungsplan für jeden Spieltag. Ohne vollständige und gültige Karte lässt sich das Spiel nicht starten (MUSS). Während des Spiels darf nur die Spielleitung Zonen ändern (22.6).

## 22.1 Karten-Editor (MUSS)

Der Editor läuft in der App (Tablet und Handy) und im Web-Cockpit (empfohlen für grosse Karten). Werkzeuge:
- Adresssuche und "Auf meinen Standort zentrieren".
- Polygon zeichnen (Punkt für Punkt), Rechteck, Kreis (Mittelpunkt + Radius), Freihand mit automatischer Glättung.
- Punkte verschieben, einfügen (Mitte einer Kante antippen), löschen; ganze Zone verschieben, drehen, skalieren.
- Rückgängig/Wiederholen (mind. 50 Schritte), automatische Zwischenspeicherung als Entwurf.
- Einrasten an Strassen und Gewässern (SOLL): Kanten folgen auf Wunsch der nächsten Strasse aus den Kartendaten, damit Grenzen im Gelände erkennbar sind.
- Schnellstart-Vorlagen: "Kreis um Treffpunkt" mit Radius-Regler, "Stadtteil wählen" (Verwaltungsgrenzen aus OpenStreetMap), "Bereich aus Gruppen-Vorlage".
- Import GeoJSON, KML, GPX (Polygon); Export GeoJSON.
- Ebenenliste rechts/unten: alle Zonen mit Typ-Symbol, Farbe, Sichtbarkeit, Reihenfolge, Gültigkeit (Spieltag).
- Messwerkzeug (Distanz, Fläche) und Anzeige von Fläche und Umfang jeder Zone.

## 22.2 Was gesetzt werden muss

| Element | Pflicht | Regeln |
| Spielfeld Tag 1 | ja | Mindestens eine Zone vom Typ spielfeld (oder Sektionen, die zusammen das Spielfeld bilden). |
| Startzone / Treffpunkt | ja | Liegt vollständig im Spielfeld Tag 1. Treffpunkt ist ein Punkt darin, an dem sich alle vor dem Start sammeln. |
| Hunter-Startpunkt (HQ) | ja | Punkt + Radius (Standard 100 m), an dem die Hunter während des Vorsprungs warten. Muss mindestens start.hq_min_distance_m (Standard: 20 % der Spielfeld-Ausdehnung, mind. 300 m) vom Treffpunkt entfernt sein. Darf ausserhalb des Spielfelds liegen. |
| Sektionen | nur wenn zone.sections_per_player | Jedem Spieler muss genau eine Sektion zugeordnet sein (Zuordnung im Editor per Drag-and-drop oder "zufällig verteilen"). |
| Center-/Kern-/Aussenzonen | nein | Müssen im Spielfeld liegen. |
| Sperrzonen | nein (dringend empfohlen) | Dürfen weder Treffpunkt noch Exitpoint noch HQ abdecken. Sie werden aus dem Spielfeld ausgeschnitten (Spielfeld minus Sperrzonen = erlaubter Bereich). Gelten für alle Rollen. |
| Sichere Zonen | nein | Siehe 7.2. |
| Exitpoint | ja, wenn exit.enabled | Muss im Spielfeld des letzten Spieltags liegen und darf in keiner Sperrzone liegen. Mehrere Kandidaten möglich; die App wählt zufällig einen (exit.random_from_candidates). |
| Verkleinerungsplan | ja, wenn zone.shrink_mode = manuell | Für jeden Spieltag ein Spielfeld. Jedes Feld muss das Feld des Folgetags enthalten (nur kleiner werden) ausser bei bewusst vergrössernden Tagen (Option "Tag vergrössert"). |

## 22.3 Sperrzonen im Detail

- Typen mit Symbol: Strasse/Autobahn, Bahngleise, Gewässer, Baustelle, Privatgelände, Schule/Kita, Spital (Zufahrt), Bahnhof-Innenbereich, Einkaufszentrum innen, Polizei/Militär, frei definierbar.
- Jede Sperrzone hat: Name, Typ, Geltung (alle Rollen, nur Spieler, nur Hunter), Zeitraum (immer oder Uhrzeiten, z. B. Schulgelände nur 07:00-18:00), Strafe bei Betreten (7.17), Warnabstand (safety.restricted_warning_m).
- Automatische Vorschläge (SOLL): Ein Knopf "Gefahrenstellen vorschlagen" fragt OpenStreetMap-Daten im Spielfeld ab (Overpass API: motorway, trunk, railway, Gewässer, military, school) und schlägt Sperrzonen mit Puffer vor (Autobahn 30 m, Gleise 15 m). Der Host übernimmt sie einzeln oder alle.
- Linien-Sperren: Für Strassen und Gleise kann man eine Linie zeichnen; die App erzeugt daraus ein Band mit einstellbarer Breite.
- Überqueren: Option "Überqueren erlaubt, Aufenthalt nicht" (z. B. für Brücken über Gleise): Ein Durchqueren unter crossing_max_seconds (Standard 60) ist kein Verstoss.
- Verhalten im Spiel: Annäherung unter Warnabstand = Vibration + Hinweis; Betreten = Alarm beim Spieler, Meldung an die Spielleitung, Verstoss-Fall. Betreten zählt nicht als "ausserhalb Spielfeld" mit Livestandort, ausser zone.restricted_counts_as_outside = an.

## 22.4 Prüfungen vor dem Speichern und vor dem Start (MUSS)

Der Editor zeigt Fehler (rot, blockieren den Start) und Warnungen (gelb, Start möglich):
| Prüfung | Stufe |
| Polygon ungültig (selbstüberschneidend, weniger als 3 Punkte) | Fehler |
| Startzone, HQ oder Exitpoint fehlt bzw. liegt in Sperrzone | Fehler |
| Startzone nicht im Spielfeld Tag 1, Exitpoint nicht im Spielfeld letzter Tag | Fehler |
| Spieler ohne Sektion (bei Sektionen) | Fehler |
| Verkleinerungsplan lückenhaft oder Folgetag grösser ohne Markierung | Fehler |
| HQ zu nah am Treffpunkt | Warnung |
| Fläche pro Spieler ausserhalb Empfehlung (22.5) | Warnung |
| Sperrzonen bedecken mehr als 40 % des Spielfelds | Warnung |
| Erlaubter Bereich zerfällt in getrennte Teile (z. B. durch Fluss-Sperre) | Warnung |
| Spielfeld grösser als 500 km² oder kleiner als 0,02 km² | Warnung |
| Exitpoint-Kandidaten liegen ausserhalb des letzten Spielfelds | Fehler |

## 22.5 Empfohlene Spielfeldgrösse

Die App schlägt eine Fläche vor und warnt bei starken Abweichungen. Faustregel (SOLL, als Hilfe angezeigt):
| Spieldauer | Fläche pro Spieler | Beispiel 4 Spieler / 2 Hunter |
| 60-90 min | 0,05-0,15 km² | Park oder Altstadtquartier, ca. 0,4 km² |
| 2-4 h | 0,15-0,5 km² | Stadtteil, ca. 1,5 km² |
| 24 h | 1-3 km² | Mehrere Stadtteile, ca. 8 km² |
| 72-96 h | 3-8 km² | Grossstadt (Original New York: Manhattan ca. 59 km² für 9 Spieler) |
Mehr Hunter pro Spieler erlauben ein grösseres Feld. Mit Fahrrädern bei den Huntern: Fläche x 2.

## 22.6 Probelauf und Vorschau (SOLL)

- Zeitleisten-Vorschau: Regler über alle Spieltage zeigt, wie das Spielfeld wann aussieht (inkl. Zeitpunkt der Ankündigung und Aktivierung).
- Probelauf: Host startet eine Simulation mit virtuellen Spielern und Huntern (zufällige Bewegungen innerhalb der Zonen, beschleunigte Zeit 10x bis 600x). So sieht man Pings, Speedhunts, Verkleinerung und Exit ohne echte Personen.
- Begehung: Host kann im Modus "Grenzen prüfen" durch das Gelände laufen; die App zeigt laufend, ob er drinnen, draussen oder in einer Sperrzone ist.
- Offline-Karten: Vor dem Start lädt jedes Teilnehmergerät die Kartenkacheln für das Spielfeld (+ 500 m Rand) herunter (MUSS), damit die Karte auch ohne Netz funktioniert.

## 22.7 Karte während des Spiels

- Die Karte ist ab Start gesperrt. Nur die Spielleitung kann Änderungen vornehmen (z. B. Baustelle als neue Sperrzone). Jede Änderung ist versioniert (zones.version), wird protokolliert und allen betroffenen Rollen mit Hervorhebung auf der Karte angekündigt. Neue Sperrzonen gelten sofort; Verkleinerungen erst nach zone.shrink_announce_minutes, ausser die Spielleitung wählt "sofort (Sicherheit)".
- Geheime Elemente: Der Exitpoint und künftige Spielfelder werden erst ab ihrem Bekanntgabezeitpunkt an Clients ausgeliefert (serverseitig, 5.2). Vorher kennen nur Host/Spielleitung sie. Ist der Host selbst Spieler (game.host_can_play), muss die App den Exitpoint zufällig aus Kandidaten ziehen und vor dem Host verbergen.

# 23. Ortung und Pings von Anfang bis Ende

Dieses Kapitel beschreibt lückenlos, wie ein Standort vom Handy eines Spielers bis auf die Karte der Taskforce gelangt. Es ergänzt 7.3, 7.4, 14 und 15 und ist verbindlich.

## 23.1 Berechtigungen und Gerätecheck in der Lobby (MUSS)

Jedes Spielgerät muss vor dem Start diese Prüfungen bestehen. Die Lobby zeigt pro Person eine Ampel; der Host sieht alle.
| Prüfung | iOS | Android |
| Standort "Immer" | Erst "Beim Verwenden", dann Upgrade auf "Immer" (zweistufig, mit Erklärbildschirmen und Link in die Einstellungen, falls abgelehnt) | ACCESS_FINE_LOCATION, danach separat ACCESS_BACKGROUND_LOCATION (Android 10+; Einstellungsseite "Immer zulassen") |
| Genaue Position | "Genauer Standort" an | "Genau" statt "Ungefähr" (Android 12+) |
| Hintergrund-Ausführung | Hintergrundmodus "location" in der App aktiviert; Hintergrundaktualisierung an | Foreground-Service mit Typ location (Android 14+) und dauerhafter Benachrichtigung "Spiel läuft" |
| Akku-Optimierung | Stromsparmodus aus (Hinweis) | App von der Akku-Optimierung ausnehmen; herstellerspezifische Anleitung (Samsung, Xiaomi, Huawei, OnePlus) anzeigen |
| Mitteilungen | Erlaubt; kritische/zeitkritische Mitteilungen erlaubt | Erlaubt; Kanal "Alarme" mit hoher Wichtigkeit |
| GPS-Test | Testfix mit Genauigkeit unter 50 m innerhalb von 60 s | gleich |
| Server-Empfang | Ein Probe-Ping erreicht den Server und erscheint beim Host ("Probe-Ping erhalten vor 3 s") | gleich |
| Akku | Mindestens lobby.min_battery_percent (Standard 60 %) oder am Laden | gleich |
| Uhrzeit | Abweichung zum Server unter 5 s (sonst Hinweis; App rechnet trotzdem mit Serverzeit) | gleich |
| Offline-Karte | Kacheln heruntergeladen | gleich |
| App-Version | Mindestversion des Spiels | gleich |
Hunter brauchen dieselben Berechtigungen (ihre Position wird im Team geteilt und für Fangprüfung gebraucht).

## 23.2 Standort erfassen (Client)

- Während eines laufenden Spiels (und nur dann) läuft die Hintergrund-Ortung. Start automatisch mit dem Spielstart (auch wenn die App geschlossen ist: Start-Push weckt die App; zusätzlich startet die App die Ortung beim Öffnen, falls nötig), Stopp automatisch bei Spielende, Fang (catch.track_after_catch = aus), Aufgabe oder Disqualifikation.
- Erfassung: distanzbasiert (alle 10 m) plus zeitbasiert (tracking.sample_interval_seconds), adaptiv (14, 15). Jeder Messpunkt: Zeit (Geräteuhr + Server-Versatz), lat, lon, Genauigkeit, Höhe, Geschwindigkeit, Richtung, Akkustand, Ladezustand, is_mock, App-Zustand (Vordergrund/Hintergrund).
- Versand: Punkte werden gebündelt alle 15 s (in Live-Fenstern alle 5 s) per HTTPS an den Endpunkt POST /games/{id}/locations gesendet, mit Request-ID. Ohne Netz: lokale Warteschlange (SQLite), Nachsenden in Reihenfolge, max. 24 h Puffer.
- Heartbeat: alle 60 s ein Lebenszeichen (auch ohne Bewegung), damit der Server "App läuft" von "Handy aus" unterscheiden kann.

## 23.3 Standort verarbeiten (Server)

1. Empfang, Authentifizierung (Konto, Spielgerät, Rolle), Plausibilitätsprüfung (14.2).
2. Speichern in location_samples; letzter gültiger Punkt pro Teilnehmer im Arbeitsspeicher/Redis-Cache ("current_position") mit Zeitstempel und Genauigkeit.
3. Regelprüfungen aus 14.2 (Zone, Sperrzone, Transport, Verschanzen, Nähe, Exit, Live-Fenster).
4. Live-Fenster aktiv: Weitergabe an den Realtime-Kanal der Taskforce (gedrosselt auf 1 Update pro 5 s).
5. Hunter-Standorte: Weitergabe an den Taskforce-Kanal (alle 10 s) und an die Spielleitung.

## 23.4 Ping erzeugen (Silent, Speedhunt, Sonderfälle)

- Zum fälligen Zeitpunkt nimmt die Engine die beste verfügbare Position: Median der Punkte der letzten 30 s mit Genauigkeit unter 100 m; sonst der letzte Punkt.
- Frische-Regel (MUSS): Ist der letzte Punkt älter als ping.max_age_seconds (Standard 60), sendet der Server eine stille Push-Nachricht "Standort jetzt melden" an das Spielgerät und wartet bis zu ping.fresh_fix_wait_seconds (Standard 30) auf einen neuen Punkt. Kommt keiner, wird der letzte bekannte Punkt verwendet und als "veraltet seit X min" markiert. Zusätzlich Signalverlust-Regel (15).
- Speedhunt-Abfragen laufen genauso, aber mit höchster Priorität (Push mit hoher Priorität, Wartezeit 20 s).
- Der Ping wird gespeichert (pings) und erst danach an Taskforce und Spielleitung verteilt. Zustellung über Realtime (sofort, wenn die App offen ist) und zusätzlich Push (wenn sie im Hintergrund ist). Die Push-Nachricht enthält aus Datenschutzgründen keine Koordinaten, nur "Neuer Ping: Spieler X"; die Koordinaten lädt die App beim Öffnen.
- Unterdrückte Pings (LEO, Regeneration, Pause): Es wird kein Ping erzeugt. Die Taskforce sieht standardmässig nichts (Original). Option ping.show_suppressed_to_taskforce: Statt Position erscheint "Kein Signal" ohne Grund.
- Pro Ping wird der nächste Termin sofort neu geplant (scheduled_jobs), damit verpasste Termine nach einem Server-Neustart nachgeholt werden (Termin in der Vergangenheit = sofort ausführen, aber höchstens einmal).

## 23.5 Anzeige der Pings bei der Taskforce (MUSS)

- Marker in der Farbe und mit dem Profilbild des Spielers, Beschriftung "Name · 14:00 · vor 7 min", Genauigkeitskreis.
- Alterung: Marker verblassen mit dem Alter (100 % bei 0 min, 40 % ab ping.fade_after_minutes = 60). Die letzten ping.history_per_player (Standard 5) Pings pro Spieler bleiben sichtbar und sind mit einer gestrichelten Linie in zeitlicher Reihenfolge verbunden (Bewegungsrichtung erkennbar).
- Quelle als Symbol: Silent (Punkt), Speedhunt (Blitz, mit Nummer 1-4), Kauf (Einkaufswagen + Kategorie), Transport/Live (pulsierender Punkt mit Countdown), Teambildung (zwei Personen), Hotel (Bett), ausserhalb (Warnsymbol).
- Antippen eines Pings: Details (Zeit, Genauigkeit, Quelle, Zone), Navigation dorthin (Fussweg, Velo, Auto über Kartenanbieter oder Systemkarte), Entfernung und geschätzte Zeit vom eigenen Standort.
- Liste "Lagebild": alle Spieler mit letztem Ping, Alter, nächster erwarteter Ping (nur wenn ping.reveal_schedule_to_taskforce = an; Original: Taskforce kennt das Intervall, also an), Status (frei/gefangen).
- Filter: nur ein Spieler, nur letzte Stunde, nur Speedhunt.
- Ping-Ton: eigener Ton für neue Pings; Speedhunt-Abfragen mit lauterem Ton.

## 23.6 Was der Spieler über die Ortung sieht

- Dauerhafte Anzeige "Ortung aktiv" (Pflicht für Transparenz und Android-Vorgabe).
- Der Spieler sieht seine eigene Position genau so, wie der Server sie kennt (inkl. "Letzte Übertragung vor 12 s"), damit Probleme sofort auffallen.
- Er sieht nicht, wann ein Silent-Ping erfolgte (ausser ping.notify_player). Er sieht, wenn er gerade live sichtbar ist (rotes Auge-Symbol mit Countdown: ausserhalb, Transport, Hotel-Ende), weil das im Original bekannt ist.
- Bei Signalverlust: Banner "Keine Verbindung: Standorte werden gespeichert und nachgesendet".

## 23.7 Fehlerfälle

| Fall | Verhalten |
| Handy ohne Netz, GPS ok | Puffern, nachsenden; Pings verwenden letzten Server-Stand (markiert veraltet). |
| GPS schlecht (in Gebäuden, Genauigkeit > 100 m) | Ping mit grossem Genauigkeitskreis; ab tracking.signal_loss_max_minutes Hinweis "Ort wechseln" (7.8). |
| App vom System beendet | Heartbeat fehlt 3 min: Push "Öffne die App, deine Ortung ist unterbrochen" + Meldung an Spielleitung. Nach tracking.signal_loss_max_minutes: Verdachtsfall. |
| Handy aus / Akku leer | Letzter Punkt mit Akkustand zeigt den Grund. Spielleitung entscheidet (Gerätewechsel 20.3, Pause für Person, oder Verstoss). |
| Mock-Location erkannt | Punkte verwerfen, Verdachtsfall, Spielleitung informiert. |
| Uhr am Gerät falsch | Server-Zeit massgeblich; Client-Zeit nur zur Reihenfolge. |
| Server kurz nicht erreichbar | Client puffert; Engine holt verpasste Timer nach; Pings werden mit tatsächlichem Erzeugungszeitpunkt angezeigt. |

# 24. Spielbarkeits-Check: ein komplettes Spiel durchgespielt

Damit sicher ist, dass alles zusammenpasst, hier ein vollständiger Durchlauf mit dem Preset "Stadtabend 3 h" (4 Spieler, 2 Hunter, Spielleitung automatisch, Host spielt als Hunter mit). Jeder Schritt muss in der fertigen App genau so funktionieren (Abnahmetest E2E-1).

| Zeit | Was passiert | Wer sieht was |
| Tag vorher | Lena (Gruppen-Admin) erstellt in der Gruppe "Züri Hunt" ein Spiel, wählt "Stadtabend 3 h", zeichnet Spielfeld Kreis 1 km um den Treffpunkt Lindenhof, lässt Sperrzonen vorschlagen (Limmatquai-Strasse, Gleise), übernimmt sie, setzt HQ am Central (700 m entfernt), 2 Exit-Kandidaten, Verkleinerung auto -15 % pro Spieltag. Prüfung grün. Einladung an die Gruppe. | 7 Zusagen, 6 Plätze: 1 Person auf der Warteliste. |
| 19:00 | Lobby öffnet. Alle machen den Gerätecheck; Tom hat "Standort beim Verwenden" statt "Immer" und wird durch den Assistenten geführt. Rollen zufällig ausgeglichen: Lena und Tom Hunter, 4 Spieler. | Host sieht alle Ampeln grün. |
| 19:30 | Start. Vorsprung 10 min. Spieler laufen los. Hunter müssen im HQ-Kreis bleiben (verlassen = Warnung an Spielleitung). | Spieler: Countdown "Jagd beginnt in 9:59". Hunter: leere Karte, Countdown. |
| 19:40 | Jagd beginnt. Spieltag 1 von 4 (je 45 min). Jeder Spieler erhält einen Joker (zufällig). | Alle: "Die Taskforce ist unterwegs." |
| 19:55 | Erster Silent-Ping (Intervall 15 min, ab Jagdbeginn, nicht an volle Stunde gebunden). | Taskforce: 4 Marker. Spieler: nichts. |
| 20:05 | Hunter starten Speedhunt (Kontingent Tag 1: 1) auf Spieler B. Abfrage 1 sofort. | Alle Spieler: "SPEEDHUNT! Abfrage 1 von 3". Taskforce: Position B. |
| 20:09 | B steigt in ein Tram und meldet "Transport starten". Abfrage 2. | Taskforce: B live für 60 s (Fahrzeug), danach Live-Fenster Transport bis 2 min nach Ausstieg. |
| 20:14 | Abfrage 3. B wird von Tom gestellt, Tom scannt Bs QR-Code; Abstand laut GPS 6 m. Fang gültig. Speedhunt endet. | Alle: "B wurde gefangen. Noch 3 frei." B wird Zuschauer, Ortung von B stoppt. |
| 20:20 | Spieler C sitzt seit 10 min still in einem Café. Die Engine erkennt einen längeren Aufenthalt und fragt "Bist du verschanzt?". C antwortet "Nein, öffentlicher Ort". Da die Spielleitung automatisch ist, gilt die Antwort zugunsten des Spielers (14.3, Regel 13); der Fall wird nur protokolliert. | Spieler C: Rückfrage. Protokoll für das Replay. |
| 20:25 | Tagesreset (Spieltag 2). Neues Spielfeld (-15 %) war seit 20:10 angekündigt. Spieler D steht ausserhalb, Übergangsfrist 0: D ist ausserhalb, Livestandort für Taskforce, Limit 5 min. D läuft zurück nach 2 min. | D: rote Warnung + Pfeil. Taskforce: D live für 2 min. |
| 20:40 | Spieler A und C kommen sich unter 150 m nahe. | Taskforce: Teambildungs-Alarm mit beiden Positionen. A und C sehen sich. |
| 20:45 | Spieler C setzt Joker "Regeneration" (15 min). | Keine Pings für C bis 21:00; Taskforce sieht C bei Speedhunt-Auswahl als "nicht verfügbar". |
| 21:00 | Challenge "Checkpoint-Lauf" (angekündigt 20:45). A holt 2 QR-Codes, gewinnt Bonus Fake-Ping. Teambildungsregel ausgesetzt von 20:50 bis 21:20. | Spieler: Challenge-Karte. Taskforce: erfährt Checkpoint-Orte gemäss Challenge-Einstellung. |
| 21:10 | Spieltag 3. A setzt den Fake-Ping 600 m entfernt. Nächster Silent-Ping zeigt der Taskforce den falschen Ort. | Taskforce: falscher Marker. Spielleitung (automatisch): Protokoll mit echtem Ort. |
| 21:55 | Spieltag 4 (letzter). Spielfeld nochmals -15 %. | Alle: neue Karte. |
| 22:20 | Exitpoint wird bekannt gegeben (20 min vor Ende): Kandidat 2, Rathausbrücke. Taskforce erfährt ihn gleichzeitig. | Alle: Karte mit Exit und Countdown "Ankunft bis 22:55". |
| 22:40 | Spielende-Zeitpunkt (19:40 + 180 min). A ist seit 22:34 im Exit-Radius (im_ziel, nicht mehr fangbar). D ist noch auf dem Weg und darf bis zur Ankunft weiter gefangen werden. C wurde um 22:30 kurz vor dem Exit gefangen. | Spieler: Countdown bis Ankunftsfrist. |
| 22:52 | D erreicht den Exit vor der Frist (22:40 + 15 min = 22:55). | D: "Geschafft!" |
| 22:55 | Ergebnis: Sieger A und D. Kopfgeld Taskforce: 2 Fänge. Replay verfügbar, Statistik in der Gruppe. Ortung überall gestoppt. | Alle: Endbildschirm. |

Zusätzliche Abnahmeszenarien aus dem Durchlauf sind in Kapitel 18 (Nr. 26 ff.) ergänzt.

# 25. Konfigurations-Validierung (Konsistenzregeln)

Beim Speichern der Regeln und vor dem Start prüft die App die Einstellungen auf Widersprüche. Fehler blockieren den Start, Warnungen nicht (MUSS):
| Regel | Stufe | Meldung |
| Mindestens 1 Spieler und 1 Hunter angemeldet | Fehler | "Es braucht mindestens einen Spieler und einen Hunter." |
| ping.interval_minutes >= game.duration_minutes | Fehler | "Bei diesem Intervall gibt es keinen einzigen Ping." |
| ping.interval_minutes > game.day_length_minutes | Warnung | "Weniger als ein Ping pro Spieltag." |
| speedhunt.max_duration_minutes > game.day_length_minutes | Fehler | |
| Joker-/Bonus-Dauer >= game.duration_minutes | Warnung | "Joker gilt das ganze Spiel." |
| hideout.max_minutes >= game.duration_minutes | Warnung | "Verschanzen ist praktisch unbegrenzt." |
| out_of_bounds.max_minutes >= game.duration_minutes | Warnung | |
| exit.reveal_minutes_before_end > game.duration_minutes | Fehler | |
| time.align_to_full_hour = an bei game.day_length_minutes < 120 | Warnung | "Bei kurzen Spieltagen besser ab Spielstart zählen." Kurze Presets setzen es automatisch aus. |
| taskforce.hq_required = an bei nur 1 Hunter | Fehler wird automatisch korrigiert | Einstellung wird ausgeschaltet, Hinweis an Host. |
| speedhunt.trigger_mode = gm bei roles.gm_mode = auto | Fehler | "Ohne menschliche Spielleitung kann niemand Speedhunts auslösen." |
| Kontingent Speedhunts x Abfragen sehr hoch im Verhältnis zur Spielerzahl (mehr als 1 Speedhunt pro Spieler und Spieltag) | Warnung | "Die Taskforce ist stark im Vorteil." |
| catch.method = handcuffs und Teilnehmende unter 18 | Fehler | |
| budget.enabled ohne Währung/Betrag | Fehler | |
| proximity.distance_m grösser als halbe Spielfeldbreite | Warnung | "Alarm wird fast dauernd ausgelöst." |
| Ruhezeiten länger als 50 % der Spieldauer | Warnung | |
| zone.sections_per_player = an, aber Sektionen fehlen | Fehler | |
| win.mode = letzter_ueberlebender mit exit.enabled | Warnung | "Exitpoint wird ignoriert." |
Die App zeigt zusätzlich eine Balance-Einschätzung (SOLL): erwartete Fangquote aus Fläche, Spieler, Hunter, Ping-Intervall und Speedhunts, als Ampel "eher Spieler im Vorteil / ausgeglichen / eher Taskforce im Vorteil".

# Anhang A: Originalregeln der drei Staffeln im Vergleich

| Regel | Staffel 1 Wien | Staffel 2 Bangkok | Staffel 3 New York |
| Dauer | 72 h | 96 h | 96 h |
| Spieler / Hunter | 5 / 5 | 8 / 7 (laut Presse auch 7 Spieler) | 9 / 7 |
| Spielfeld | Sektion pro Spieler, Startzone 1. Bezirk, Zonen werden frei und gegen Ende grösser | Spielerzonen + Center Zone, täglich kleiner, Zone frei bei Fang | Manhattan + Outer Area, täglich 06:00 kleiner, neue Karte bis 03:00 |
| Silenthunt | alle 2 h, volle Stunde | Aussen 2 h, Center 1 h | Outer 2 h, Manhattan 1 h |
| Speedhunt Tag 1 | 1 | 2 | 3 |
| Abfragen | 5 | 4 | 4 (Fahrzeug: 1 min live) |
| Silent während Speedhunt | nein | ja | ja |
| Sonderregeln Speedhunt | 45 min nach Silent sonst Silent = Abfrage; max. 1 pro Spieler/Tag; LEO danach | Strafe-Speedhunt | nicht 2x gleiches Ziel; 2 parallel; Fang streicht einen |
| Ausserhalb | sofort sichtbar | sichtbar, > 2 h = Catch | > 2 h = Disqualifikation |
| Verschanzen | 2 h, dann 100 m | 2 h, dann 100 m | 2 h, dann 200 m; Ort nach 8 h gesperrt |
| Fortbewegung | nicht geregelt | Center: Verbot (alle 10 min Speedhunt); Zone: ÖV mit Info | Meldepflicht, Live + 10 min (+5 je Fahrt), Fähre max. 10 Stationen |
| Budget | kein Geld | kein Geld | 30 USD/Tag, Käufe gemeldet |
| Joker | - | 1/Tag: Regeneration 4 h, Hunter erfragen, Catch-Free 3 h | - |
| Boni | - | Challenge: Fake-Ping, 6h-Hotel | - |
| Challenges | - | täglich, freiwillig | täglich (z. B. Tresor-Überfall); Teambildungsregel ausgesetzt |
| Teambildung | - | - | < 250 m = Alarm an Taskforce, ab 1 h |
| Hunter-Fahrzeuge | Einsatzwagen + Motorrad | Einsatzwagen + Mopeds | 1 Auto + 2 Fahrräder |
| Fang | Handschellen | Handschellen | Handschellen + Filmbeweis |
| Sieg | 72 h überleben | 96 h überleben | 96 h + Exitpoint bis 06:15 |
| Preis | 5'000 EUR | 5'000 EUR, Kopfgeld 1'000 EUR pro Spieler | 5'000 EUR |

# Anhang B: Mechaniken aus den Folgen

Aus den Folgenbeschreibungen der drei Staffeln abgeleitete Spielmomente, die die App ermöglichen muss:
- Erste Koordinaten erreichen die Taskforce erst einige Stunden nach Start (Wien, Folge 1: um 2 Uhr) -> Vorsprung und verzögerter erster Ping.
- Erster Sichtkontakt und Einkesseln (Wien 2, 5) -> Hunter sehen einander live und koordinieren über Taskforce-Chat und Zentrale.
- Erste Nacht, Schlafplatzsuche, Regen (Wien 3, New York 5) -> Verschanzen-Regel, Hotel-Bonus, Akku-Management.
- Speedhunt, bei dem der Betroffene nicht weiss, dass er gemeint ist (Wien 5) -> anonyme Speedhunt-Meldung.
- Nach 72 h werden Zonen frei bzw. grösser (Wien 7, 9) -> Zonenplan und Freigabe bei Fang.
- Notfallknopf und Paranoia (Wien 8) -> Notfall-Funktion.
- Gefangener erzählt im Kontrollraum (Wien 8) -> Gefangene werden Zuschauer.
- Challenge gegen die Hunter: Hunter fotografieren (Bangkok 2, 3) -> Challenge-Vorlage "Jagd auf die Hunter".
- Gefangene als Lockvogel (Bangkok 6) -> Variante catch.caught_player_becomes = hunter_helfer.
- Hotel oder Strasse (Bangkok 7) -> Challenge-Vorlage und Hotel-Bonus.
- Neue Jokerkarten im Spielverlauf (Bangkok 8) -> Spielleitung kann Joker live hinzufügen.
- Taskforce hält Spieler nachts wach (Bangkok 9) -> keine Ruhezeiten im Original.
- Verfolgung auf ein Boot (Bangkok 11) -> Fähren-/Boot-Regeln.
- Speedhunt startet direkt neben einem Spieler (Bangkok 14) -> Speedhunt-Zeitpunkt frei wählbar.
- Zone stark verkleinert am letzten Tag (Bangkok 15) -> Verkleinerungsplan.
- Tresor-Überfall mit Zeitlimit nach Betreten des Raums (New York 4) -> Challenge-Vorlage "Tresor-Überfall".
- Spielleitung greift für Fairplay ein (New York 5) -> Live-Regeländerungen, Fälle.
- "ACHTUNG GPS-Tracker", "Hackerangriff", "Ins System gehackt" (New York 11, 12, 15) -> Story-Ereignisse rund um Tracker und System; in der App als Spielleitungs-Ereignisse umsetzbar (z. B. Bonus "Systemausfall": alle Pings für X min unterdrückt, oder Taskforce erhält einmalig alle Positionen). Genaue Regeln nicht öffentlich; als eigene Joker/Bonus-Effekte konfigurierbar.

# Anhang C: Start-Prompt für die KI

```
Du bist ein erfahrenes Full-Stack-Team. Baue die App gemäss der beigefügten
Spezifikation "Manhunt App - Spezifikation" vollständig und produktionsreif.

Vorgaben:
- Halte dich an alle MUSS-Anforderungen. Jeder Zahlenwert in den Regeln ist
  ein Parameter aus Kapitel 8 und gehört ins Konfigurationsschema, nie fest in
  den Code. Liefere alle Presets aus Kapitel 9.
- Stack gemäss Kapitel 12: Monorepo (pnpm, Turborepo) mit apps/mobile (Expo,
  React Native, TypeScript, MapLibre), apps/web (Next.js Cockpit),
  services/engine (Node.js, TypeScript), packages/shared (Zod-Schemas, Typen,
  Regel-Logik), Supabase (Postgres + PostGIS, Auth, Realtime, Storage, RLS).
- Die Regel-Logik lebt als reine, testbare Funktionen in packages/shared und
  wird von der Engine ausgeführt. Schreibe für jedes Szenario aus Kapitel 18
  einen automatisierten Test mit Fake-Clock und simulierten GPS-Spuren.
- Halte die Konfliktregeln aus Kapitel 14.3 exakt ein.
- Setze Konten, Anmeldung und Gruppen (Kapitel 20, 21), den Karten-Editor
  mit Sperrzonen und Startprüfungen (Kapitel 22), die Ortungs- und
  Ping-Pipeline (Kapitel 23) und die Konfigurations-Validierung (Kapitel 25)
  vollständig um. Der Durchlauf aus Kapitel 24 ist der wichtigste
  End-to-End-Test.
- Sichtbarkeit nur serverseitig (Kapitel 5.2), mit RLS und getrennten
  Realtime-Kanälen.
- UI auf Deutsch (i18n vorbereitet), dunkles taktisches Design, Kapitel 10.
- Arbeite in der Reihenfolge aus Kapitel 19. Liefere nach jedem Schritt
  lauffähigen Code, Migrationen, Seed-Daten (ein Demo-Spiel mit Zonen) und
  eine README mit Setup-Anleitung.
- Wenn etwas unklar ist, nimm den dokumentierten Standardwert und notiere die
  Annahme in DECISIONS.md, statt nachzufragen.
```

# Anhang D: Ergänzungen aus dem Testbetrieb (Version 1.2)

Diese Punkte ergänzen die Kapitel oben. Nichts wurde entfernt.

## D.1 Zeitlogik (ergänzt Kapitel 25)
- Jede Zeitangabe MUSS zu den anderen passen. Was während der Jagd passiert (Verkleinerung, Pings, Speedhunts, Ankündigungen, Joker, Exit-Bekanntgabe, Limits), liegt innerhalb der Spieldauer bzw. eines Spieltags.
- Eingabefelder lassen keine grösseren Werte zu. Unstimmige Werte (z. B. aus älteren Spielen) werden automatisch angepasst und dem Host als "Automatisch korrigiert" gezeigt; vor dem Start werden sie gespeichert.
- Bei nur einem Spieltag wird das Spielfeld alle X Minuten verkleinert (zone.shrink_every_minutes), höchstens die halbe Spieldauer, damit es mindestens einmal kleiner wird. Ankündigung und Übergangsfrist sind höchstens eine Phase lang.
- Akzeptanztest 40 gilt weiter sinngemäss: ein Intervall länger als die Spieldauer kann nicht mehr entstehen, es wird angepasst.

## D.2 Notfall (ergänzt Kapitel 15)
- Ein Notfall alarmiert immer alle Hunter und, falls vorhanden, die Spielleitung. Es wird nie ein Hunter zur Spielleitung.
- Hunter sehen bei einem offenen Notfall Standort und Notfallkontakt der Person.
- Die Person selbst kann den Notfall jederzeit beenden (Fehlalarm). Alle erhalten die Meldung.
- Notrufnummern Schweiz: 117 Polizei (Hauptnummer), 144 Sanität, 112 europaweit.

## D.3 Ausserhalb der Zone (ergänzt Kapitel 7)
- Wer seine Sektion bzw. das Spielfeld verlässt, wird nach der GPS-Toleranz immer live an alle Hunter gezeigt (nicht mehr abschaltbar).

## D.4 Chat (ergänzt Kapitel 16)
- Spieler und Hunter schreiben nur mit der Spielleitung; Spieler nie mit anderen Spielern. Hunter haben ihren Taskforce-Kanal.
- In "Ankündigungen" schreibt nur die Spielleitung. Durchgesetzt auf dem Server.

## D.5 Joker (ergänzt Kapitel 11)
- Beim Erstellen wählt der Host, welche Joker es gibt, ihre Dauer, wie viele pro Spieltag, wie viele gleichzeitig und ab wann sie verfügbar sind (joker.available_after_minutes nach Jagdbeginn). Spieler setzen sie unter "Aktionen" selbst ein.

## D.6 Karte (ergänzt Kapitel 22)
- HQ, Treffpunkt und Exit sind Punkte mit Symbol. Um das HQ zeigt ein gestrichelter Kreis den Mindestabstand zum Treffpunkt, um den Exit der Ankunftsradius.
- Karten haben Knöpfe für Vollbild, "auf das Spielfeld zoomen" und den eigenen Standort.
- Der Karten-Editor ist ein Assistent mit einem Schritt pro Seite; das Spielfeld entsteht mit einem Tipp (Grösse nach Spielerzahl), Treffpunkt, HQ und Exits können automatisch gesetzt werden.

## D.7 Hilfe
- Hinter jedem ⓘ steht eine ausführliche Erklärung (Zonen, Schritte, Einstellungen).
- Beim Erstellen eines Spiels gibt es einen Helfer, der Schritt für Schritt durch die Seite führt. Er startet nur auf Wunsch.

# Anhang E: Übersichtlichkeit und Play Store (Version 1.3)

Diese Punkte ergänzen die Kapitel oben. Nichts wurde entfernt.

## E.1 Erster Start
- Nach dem Profil zeigt die App eine kurze Einführung (5 Seiten): Spieler und Hunter, Pings und Speedhunts, Fangen und Exit, Sicherheit, die drei Schritte zum ersten Spiel. Jederzeit überspringbar und später wieder aufrufbar.
- Anmelde- und Startseite erklären in einem Satz, worum es geht. Auf der Startseite kann man den Code direkt eingeben.

## E.2 Spiel erstellen
- Eine Seite in drei Schritten: Name, Spielart (Vorlage als Karte mit Dauer und Personenzahl), Anpassen. Anpassen ist freiwillig und in zugeklappte Bereiche mit Kurzfassung gegliedert (Spieler und Hunter, Zeiten, Pings, Speedhunt, Fangen, Joker, Extras, Zusatzregeln, Termin, Expertenmodus mit allen Einstellungen).
- Automatische Anpassungen erscheinen gesammelt in einer Zeile; Fehler und Hinweise bleiben sichtbar.

## E.3 Lobby
- Der Beitritts-Code steht gross oben. Der Host sieht eine Checkliste: Karte zeichnen, Freunde einladen, Rollen verteilen, alle bereit.
- Die Regeln werden in normalen Sätzen zusammengefasst ("So läuft das Spiel"), auch im Spiel unter Aktionen.

## E.4 Spielansicht
- Navigation unten (Karte, Aktionen, Meldungen, Chat) mit Hinweis auf neue Meldungen. Der Notfall-Knopf (SOS) ist oben rechts immer erreichbar und fragt nach, mit den Nummern 117, 144, 112.
- Es wird immer nur eine Meldung eingeblendet; weitere stehen unter Meldungen.

## E.5 Play Store
- Konto löschen in der App (Profil), sofort und endgültig, mit eigenen Spielen. Nicht möglich während eines laufenden Spiels.
- Öffentliche Datenschutzseite unter /datenschutz.
- App-Icons als PNG (192, 512, maskable). Veröffentlichung als Trusted Web Activity; dafür braucht es ein Google-Play-Entwicklerkonto.
