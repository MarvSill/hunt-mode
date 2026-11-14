# Entscheidungen und Annahmen

Abweichungen von der Spezifikation und Annahmen, wo sie nichts festlegt.

## Bauplan

1. Fundament: Konten, Profil, Regelwerk, Presets, Prüfung, Spiel erstellen/beitreten, Lobby (**erledigt**)
2. Karte: Spielfeld, Zonen, Sperrzonen, Exitpoint, Startprüfungen, Standort-/Gerätecheck
3. Spiel-Engine: Start, Vorsprung, Spieltage, Silent-Pings, Live-Fenster, Ausserhalb, Pause, Notfall
4. Speedhunt, Fang (QR), Exitpoint, Spielende
5. Verschanzen, ÖV, Budget, Teambildungs-Alarm
6. Joker, Boni, Challenges
7. Strafen, Verstoss-Fälle, Spielleitungs-Cockpit, Live-Regeländerung
8. Gruppen, Einladungslinks, Chat, Push, Zuschauer, Replay, Statistik
9. Feinschliff, i18n, Konto löschen/Datenexport, optional native App

## Technik

- **PWA statt Expo/React Native** (Kapitel 12 empfiehlt Expo). Grund: Freunde sollen ohne App Store
  mitspielen. Folge: Im Browser läuft die Ortung nur, solange die App offen ist. Falls nötig wird
  derselbe Code in Schritt 9 mit Capacitor als native App mit Hintergrund-Ortung verpackt.
- **Ein Paket statt Monorepo.** Die Regel-Logik liegt UI-frei in `src/shared/` und kann später in
  eine Engine (Supabase Edge Functions/pg_cron oder eigener Dienst, Entscheidung in Schritt 3) wandern.
- Schreibzugriffe auf Spiele und Teilnehmende nur über Datenbank-Funktionen (RPC), Lesen über RLS.
- Notfallkontakt liegt in eigener Tabelle `profile_private`, nur für die Person selbst lesbar.

## Annahmen zum Regelwerk

- `ping.align_to_full_hour` (Hinweis in Kapitel 9) ist nicht im Parameterkatalog; es gilt `time.align_to_full_hour`.
- Kurze Presets: Werte, die länger als ein Spieltag wären (Challenge-Ankündigung, Zonen-Ankündigung,
  Verschanzen-Erkennung), wurden auf passende Werte verkürzt.
- „Nicht 2x gleiches Ziel / parallel 2: aus“ = `no_consecutive_same_target` aus und `max_parallel` 1.
- Konsistenzregel „mehr als 1 Speedhunt pro Spieler und Spieltag“: geprüft als Tageskontingent > Anzahl Spieler.
- Ein Rollenwechsel durch den Host setzt „bereit“ zurück, damit jede Person ihre Rolle bestätigt.
- Beitreten verlangt bestätigte E-Mail, vollständiges Profil und Notfallkontakt (Kapitel 20.1, für alle Rollen).

## Engine (Schritte 3 bis 8)

- Die ganze Spiellogik läuft in der Datenbank (PL/pgSQL): `tick_game()` wird von pg_cron alle 15 s,
  bei jedem Standort-Update und von offenen Apps aufgerufen. Damit muss niemand einen Server betreiben,
  und kein Handy kann Regeln umgehen. Clients schreiben nur über geprüfte Funktionen.
- Sichtbarkeit (Kapitel 5.2) entscheidet eine Funktion `game_state()`: Spieler sehen nur sich selbst,
  die Taskforce Pings und Live-Fenster, die Spielleitung alles inklusive echter Position hinter Fake-Pings.
- Spielzeit = echte Zeit + Vorlauf. Im Probelauf verschiebt „Vorspulen“ den Vorlauf in 5-Minuten-Schritten,
  damit alle Timer in der richtigen Reihenfolge feuern; letzte Positionen gelten dabei als aktuell.
- Fang-Code: 6 Ziffern, alle 30 s neu, vorheriger Code bleibt 30 s gültig. Ohne Kamera: Code eintippen.
- Automatische Spielleitung entscheidet im Zweifel für die Spieler (Challenge-Fotos zählen, bestrittener
  Fang gilt nur bei passendem GPS-Abstand). Mit menschlicher Spielleitung wartet eine Strafe nach einer
  Erklärung auf die Entscheidung.
- Punkte (Siegmodus „punkte“): 10 pro überlebte Stunde, 50 für den Exit, 20 pro geschaffte Challenge;
  Hunter bekommen ihr Kopfgeld. Annahme, die Spezifikation legt keine Formel fest.
- Joker „nach Wahl“: der Spieler wählt beim Einsetzen aus den erlaubten Typen.

## Grenzen der Web-App (bekannt)

- Der Browser sendet den Standort nur, solange die App offen und sichtbar ist (Bildschirm bleibt dank
  Wake Lock an). Echte Hintergrund-Ortung und Push bei geschlossener App braucht die native Verpackung
  (Capacitor), die mit demselben Code möglich ist. Meldungen kommen bei offener App mit Ton/Vibration
  und als Systembenachrichtigung.
- NFC, Bluetooth-Fang und Handschellen sind in den Regeln wählbar, aber nur QR und Bestätigung sind gebaut.
- Kartenkacheln kommen von OpenStreetMap und werden für Funklöcher zwischengespeichert; für viele Spiele
  später einen eigenen Kachel-Anbieter nehmen (OSM-Nutzungsregeln).
- Nur Deutsch; die Texte sind für weitere Sprachen nicht ausgelagert.

## Noch offen in Schritt 1

- Balance-Einschätzung (Kapitel 25, SOLL) braucht die Spielfeldfläche, kommt mit der Karte.
- „Ausgeglichene“ Zufallsverteilung nach bisherigen Rollen braucht Spielhistorie (ab Schritt 8).
- Benutzername ändern (alle 30 Tage), Konto löschen, Datenexport, Apple/Google-Login, Captcha: spätere Schritte.
- Serverseitige Prüfung der Konfiguration beim Start kommt mit der Engine (Schritt 3).

## Betrieb

- Hosting auf GitHub Pages statt Vercel: braucht kein weiteres Konto. Dafür muss das Repository öffentlich sein
  (im Code stehen keine Geheimnisse; der Publishable key landet ohnehin im Browser).
- Supabase wird per Access Token aus der GitHub Action eingerichtet (`scripts/supabase-setup.mjs`).
  Bereits eingespielte Migrationen merkt sich die Tabelle `hm_migrations`.
- Keine Bestätigungsmail bei der Registrierung (Spezifikation verlangt sie): Der Gratis-Mailversand von Supabase
  stellt nur an Team-Mitglieder zu. Mit eigenem SMTP wieder einschaltbar. „Passwort vergessen“ braucht ebenfalls SMTP.

## Karte und Zonen (Migration 0008)
- Spielfeld-Zonen haben Phasen statt nur Spieltage: `zone.shrink_every_minutes = 0` heisst eine Phase pro Spieltag, sonst alle X Minuten eine neue Phase. `day_index` einer Zone ist die Phase. Stand in `games.state_json` (`phase`, `next_phase_at`).
- Der Editor führt Schritt für Schritt: Spielfeld (Kreis, Rechteck, eigene Form), Treffpunkt, HQ, Exit, Verkleinerung mit Vorschau, Gefahrenzonen, weitere Zonen.
- Sektion, Startzone, Center, Kern, Aussen, Sicher und Sperrzone müssen im Spielfeld (Phase 1) liegen, ein Phasen-Spielfeld im vorherigen. Was hinausragt, wird beim Zeichnen zugeschnitten (Turf). Treffpunkt und Exit müssen im Feld liegen; `start_game` prüft das nochmals.
- Sperrzonen haben eine Art (Strasse, Gleise, Gewässer …) und werden rot schraffiert mit Warnsymbol gezeigt. Vorschläge kommen aus OpenStreetMap (Overpass-API), Linien werden als Band mit Breite übernommen.

## Runde 3 (Migration 0009)
- Zeitlogik in `src/shared/timeRules.ts`: Höchstwerte für Eingaben (`timeLimits`) und automatische Korrektur (`fitTimes`), eingebaut in `validateConfig` als "autofix". Vor dem Start speichert die Lobby korrigierte Werte. Regeln deaktivierter Funktionen werden nicht geprüft.
- Notfall: an alle Hunter (und Spielleitung); Hunter sehen den Notfallkontakt nur bei offenem Notfall; die Person beendet Fehlalarme selbst. Nummern 117/144/112.
- Ausserhalb der Zone immer live (Option `out_of_bounds.live_visible` wird ignoriert und ist ausgeblendet).
- Chat: Kanal "spieler" nur noch für die Spielleitung, Ankündigungen nur Spielleitung (oder ein nicht mitspielender Host). `communication.player_to_player` ist ausgeblendet.
- Joker: `joker.available_after_minutes`; Vergabe einmal pro Spieltag über `state_json.joker_day` im Tick.

## Runde 4: Übersicht und Play Store (Migration 0010)
- Neues Design: Farbverlauf als Akzent, Icons in der unteren Leiste, Schalter statt Kästchen, aufklappbare Bereiche mit Kurzfassung.
- Einführung (5 Seiten) beim ersten Start, später unter Start > ? oder Profil > So funktioniert Hunt Mode. Gemerkt in `localStorage` (`hm-intro-seen`).
- Spiel erstellen ist eine Seite in drei Schritten: Name, Spielart (Vorlage), Anpassen (freiwillig, zugeklappt). "Eigenes Spiel" als eigener Einstieg entfällt; weicht die Konfiguration von der Vorlage ab, wird das Spiel als `eigenes` gespeichert.
- Lobby: Code gross oben, für den Host eine Start-Checkliste (Karte, Einladen, Rollen, Bereit), Regeln in Klartext (`RulesSummary`).
- Spielansicht: Tabs unten wie in einer App, SOS-Knopf oben rechts mit Bestätigung und Notrufnummern, nur eine Meldung gleichzeitig. Kein waagrechtes Scrollen mehr.
- Untere Leiste nur auf den Hauptseiten (Start, Beitreten, Gruppen, Profil).
- Play Store: Konto löschen (`delete_my_account`, eigene Spiele werden mitgelöscht, Gruppen gehen an das älteste Mitglied), öffentliche Seite `/datenschutz`, PNG-Icons (192, 512, maskable) im Manifest. Für den Store selbst fehlen noch: Google-Play-Entwicklerkonto (einmalig 25 USD) und das Verpacken als TWA (z. B. mit PWABuilder), inklusive `assetlinks.json` auf der Domain.

## Runde 5: eigenständiges Spiel (Migration 0012)
- Kein erkennbarer Bezug zu anderen Spielen oder Serien: keine Vorlagen nach Städten, keine solchen Texte. Übrig bleiben die Vorlagen Schnell 90 min, Stadtabend 3 h und Wochenende 24 h. Gespeicherte Spiele mit alten Vorlagen gelten als `eigenes`.
- Eigene Begriffe: Hunter-Team (statt Taskforce), Blitzjagd (statt Speedhunt), Ping, Fluchtpunkt (statt Exitpoint), Schutzschild (Joker, nicht fangbar). Intern heissen Tabellen und Felder weiter `speedhunt`, `taskforce`, `exit`, `catch_free`.
- Keine Spielleitung mehr (Rolle `gm` entfernt). Der Host wählt in der Lobby selbst eine Rolle und gilt immer als bereit. Strafen und bestrittene Fänge entscheidet immer die App. Funktionen der Spielleitung (Pause, Freigaben, Sonder-Ping, Joker vergeben, Live-Regeln) sind auf dem Server gesperrt. Der Host kann das Spiel abbrechen und im Probelauf vorspulen.
- Das Spiel läuft am Stück: keine Spieltage (intern immer `game.days = 1`), keine jagdfreien Zeiten, keine Pause. Blitzjagden gelten fürs ganze Spiel, das Spielfeld wird alle X Minuten kleiner.
- Notfall: geht an alle Hunter und an den Host. Nur die Jagd auf die betroffene Person wird ausgesetzt, das Spiel läuft weiter. Den Notfallkontakt sehen Hunter und Host nur bei einem offenen Notfall.
- Challenges, Boni (Fake-Ping, Hotel) und die Schonzeit nach einer Blitzjagd sind entfernt. Ebenso Filmpflicht, Gegenstände-Limit und tägliche Einsatzbesprechung.
- Joker: beim Erstellen eine Liste, pro Eintrag Art, Wirkdauer und Freischaltzeit (`joker.types[].after_minutes`). Zu dieser Spielzeit bekommt jeder freie Spieler den Joker einmal; vergebene Einträge merkt sich `games.state_json.jokers_granted`.
- Chat: `sp:<spieler>` ist das Gespräch eines Spielers mit allen Huntern, `spieler` schreiben die Hunter an alle Spieler, `taskforce` ist der Kanal der Hunter. Spieler schreiben nie mit anderen Spielern. Ankündigungen schreibt niemand mehr; automatische Meldungen kommen unter "Meldungen". Neue Nachrichten lösen eine kurze Meldung beim Empfänger aus.
- Repository und Adresse heissen `hunt-mode`. Die Spezifikation liegt nur noch lokal in `docs/` (nicht auf GitHub), weil sie sich auf eine Vorlage bezieht.

## Runde 6: ohne Budget (Migration 0013)
- Budget ist ganz entfernt: keine Einstellung, keine Anzeige, kein "Kauf melden", kein Kauf-Ping. Noch nicht gestartete Spiele haben es ausgeschaltet, `make_purchase` ist auf dem Server gesperrt. Die Tabelle `purchases` bleibt für alte Spiele stehen.

## Runde 7: nur ein Spielfeld (Migration 0014)
- Es gibt nur noch ein Spielfeld (es kann weiterhin alle X Minuten kleiner werden), dazu Gefahrenzonen und die Punkte Treffpunkt, HQ und Fluchtpunkt.
- Entfernt: Kern- und Aussengebiet (eigene Ping-Abstände, `ping.zone_overrides`), Center (`transport.forbidden_in_zone_types`), Sektionen pro Spieler (`zone.sections_per_player`, `zone.release_on_catch`), Startzone und Schutzzone. Bestehende Zonen dieser Art sind gelöscht, `save_map` speichert sie nicht mehr.

## Runde 8: Alarm, Blitzjagd nur durch Hunter, ohne Schutzschild (Migration 0015)
- Bei jedem Ping bekommen alle Spieler eine Meldung, der gepingte Spieler "Du wurdest gepingt". Bei jeder Blitzjagd (Start und jede Abfrage) ebenso. Das Handy klingelt, vibriert und zeigt die Meldung. Jeder Spieler stellt Ton (an/aus), Klingelton, Lautstärke und Vibration im Spiel unter Aktionen selbst ein; gespeichert nur auf dem Gerät (`localStorage` `hm-alarm`). Die Einstellung "Spieler merkt den Ping" gibt es nicht mehr. Grenze: nur solange die App offen ist; iPhones vibrieren im Browser nicht.
- Blitzjagden starten nur die Hunter: keine Zufalls-Blitzjagden, keine Straf-Blitzjagden. Die mittlere Strafstufe ist "15 min live sichtbar" (`live_standort`).
- Eine Blitzjagd hat kein Zeitlimit (`deadline_at` leer): sie endet nach der letzten Abfrage oder beim Fang.
- Der Joker "Schutzschild" ist entfernt; es bleiben Regeneration und Hunter-Standorte. Joker werden nach der eingestellten Zeit freigeschaltet und wirken erst, wenn der Spieler sie einsetzt.
- "Teambildungs-Alarm" heisst jetzt Nähe-Alarm.
- Jede Einstellung beim Erstellen hat ein ⓘ mit Erklärung (`QUICK_HELP` in `src/shared/help.ts`).
- Spiel erstellen hat jetzt 4 Schritte: Name, Spielart, Anpassen, Karte. Nach "Weiter zur Karte" öffnet sich der Karten-Editor im Einrichtungs-Modus (`/spiel/<id>/karte?neu=1`); "Fertig" speichert und führt in die Lobby. Den Code zum Einladen zeigt die Lobby erst, wenn ein Spielfeld gezeichnet ist.

## Runde 9: ein Startpunkt, keine Zentrale, genaue Pings (Migration 0016)
- Spieler und Hunter starten am selben Startpunkt (Zone `treffpunkt`, angezeigt als "Startpunkt"). Ein eigenes HQ gibt es nicht mehr; `save_map` legt den Wartebereich der Hunter (`hq`, Radius `start.hq_radius_m`) automatisch an den Startpunkt. Dort warten die Hunter während des Vorsprungs. Der Startpunkt ist Pflicht.
- Die Rolle "Zentrale" ist entfernt (wird zu Hunter). Alle Hunter jagen gemeinsam unterwegs. "Zentrale muss besetzt sein" entfällt.
- Pings zeigen immer den genauen Ort: die Einstellung "Ungenauigkeit" (`ping.precision_blur_m`) ist entfernt.
- Joker Regeneration: solange er wirkt, wird der Spieler nicht gepingt und keine Blitzjagd auf ihn ist möglich. Einsetzen geht nicht, solange irgendeine Blitzjagd läuft.
- Joker Hunter-Standorte: beim Einsetzen einmaliger Ping aller Hunter (Standort in diesem Moment, nicht live). Die Punkte bleiben mit Uhrzeit bis Spielende auf der Karte des Spielers.
- Spielfeld verlassen: beim 1. und 2. Mal Alarm (kritisch, mit Klingelton) und Countdown (`out_of_bounds.grace_seconds`, Standard 60 s), groß in der Spieler-Ansicht. Ist der Spieler danach nicht zurück, sehen ihn die Hunter live. Ab dem 3. Verlassen sofort live ohne Countdown (`participants.out_exits`). Das Limit "zu lange draussen = gefangen" bleibt.
- Gefahrenzone betreten: gleiche Regel wie beim Verlassen des Spielfelds, eigene Zählung (`participants.danger_exits`): 1. und 2. Mal Alarm und Countdown, danach live (Live-Fenster `gefahrenzone`); ab dem 3. Mal sofort live; zu lange drin (`out_of_bounds.max_minutes`) hat dieselbe Folge wie ausserhalb (Standard: gefangen). Gefahrenzonen mit "Überqueren erlaubt" bleiben ausgenommen. "Sperrzone zählt als ausserhalb" entfällt.

## Runde 10: keine Strafen, Fortbewegung, Nähe-Alarm, SOS, Fluchtpunkt (Migration 0017)
- Keine Strafen: `create_violation` erfasst nichts mehr; die Strafstufen und das Strafen-Kapitel der Regeln sind entfernt. Folgen gibt es nur, wo sie zum Spiel gehören: zu lange ausserhalb, in einer Gefahrenzone oder verschanzt = gefangen. Ein Hunter, der den Startpunkt während des Vorsprungs verlässt, bekommt nur einen Alarm (höchstens einmal pro Minute).
- Fortbewegung: zwei Schalter, "ÖV, Taxi und Auto" und "Velo und Trottinett". Kein Anmelden, kein Live-Standort, keine Erkennung (`check_transport` tut nichts). Es gilt Fairplay.
- Nähe-Alarm: beide Spieler bekommen einen Alarm mit dem Standort des anderen und einen Countdown (`proximity.warn_minutes`, Standard 2 min). Sind sie danach noch zu nahe, bekommen die Hunter den Ping beider. Ab der Bekanntgabe des Fluchtpunkts aus.
- SOS: unterbricht das ganze Spiel (`games.paused_at`), Alarm an alle mit Standort; alle sehen offene Notfälle. Ist kein Notfall mehr offen, geht das Spiel weiter (`resume_internal`), die unterbrochene Zeit wird angehängt. Den Notfallkontakt sehen weiterhin nur Hunter und Host. Das ist die einzige Unterbrechung im Spiel.
- Fluchtpunkt: mindestens 4 Kandidaten. Alle bleiben während des Spiels verborgen; erst bei der Bekanntgabe wählt die App zufällig einen (bevorzugt im aktuellen Spielfeld). Nur die Spieler sehen ihn, alle denselben; die Hunter nie. Die automatische Verkleinerung zielt deshalb auf die Mitte des Spielfelds.
- Verkleinerung ohne Extra-Zeit: die Ankündigung reicht, danach gilt sofort die Regel "Spielfeld verlassen".
- Verschanzen bleibt (Frage "Bist du verschanzt?" oder selbst melden, Uhr, danach gefangen); die Sperre für die Rückkehr an denselben Ort entfällt.

## Runde 11: Deutsch, Französisch, Englisch
- Jede Person wählt ihre Sprache selbst (Anmeldung und Profil); gespeichert auf dem Gerät (`localStorage` `hm-lang`) und im Profil (`profiles.locale`). Ohne Wahl gilt die Sprache des Handys.
- Texte stehen im Code auf Deutsch und laufen durch `t('…')` (`src/i18n`). Der deutsche Text ist der Schlüssel in `fr.ts` und `en.ts`. Feste Listen auf Modulebene sind mit `lazy(…)` umhüllt, damit sie beim Lesen übersetzt werden. Ein Test prüft, dass jeder Text übersetzt ist und die Platzhalter stimmen.
- Meldungen und Fehler vom Server bleiben in der Datenbank deutsch und werden auf dem Handy mit Mustern übersetzt (`src/i18n/server.ts`). So bekommt jede Person sie in ihrer Sprache, auch im selben Spiel. Neue Server-Texte brauchen dort eine Regel.
- Vor dem Start sieht der Host alle Zonen seiner Karte (auch Fluchtpunkt-Kandidaten), ab Spielstart gelten für ihn die normalen Sichtregeln (Migration 0018).

## Runde 12: Fluchtpunkte innen, Gefahrenzonen nur für echte Gefahren (Migration 0019)
- Fluchtpunkt-Kandidaten müssen in der innersten Zone liegen (Spielfeld der letzten Phase). Der Karten-Editor setzt sie automatisch dort und meldet einen Fehler, sonst lehnt der Server den Start ab. Die automatische Verkleinerung zielt im Editor wie auf dem Server auf die Mitte des Spielfelds.
- Gefahrenzonen nur für aussergewöhnlich gefährliche Orte: Autobahnen, Bahngleise, grosse Gewässer (ab 2 ha) und "andere aussergewöhnliche Gefahr" von Hand. Keine Schulen, Strassen, kleinen Gewässer, Baustellen, Kitas, Bahnhöfe oder Einkaufszentren mehr: jeder trägt die Verantwortung für sich.
- Vorschläge aus OpenStreetMap lassen Strecken auf Brücken oder in Tunneln weg und schneiden Unterführungen, Brücken und Stege (16 m breit) aus den Gefahrenzonen aus.

## Runde 13: moderne Karte und Nummern
- Spielkarte und Wiederholung mit MapLibre (Stile von OpenFreeMap und CARTO, ohne Konto). Jede Person wählt Stil (automatisch, Stadt in 3D, Klar und ruhig, Nacht) und 3D an/aus selbst, gespeichert auf dem Gerät (`localStorage` `hm-map`). Der Karten-Editor bleibt Leaflet (Zeichnen mit Geoman), bekommt aber den gewählten Stil als flache Grundkarte.
- Feste Nummern ab Spielstart (Migration 0020, `participants.tag`): Spieler 1, 2, 3 …, Hunter H1, H2 … in der Reihenfolge der Lobby. Die Nummer steht in jedem Punkt auf der Karte (Pings, Positionen, Hunter-Standorte-Joker) und neben den Namen. Sie bleibt, auch wenn jemand gefangen wird.
- Kartenart auf jeder Karte wählbar (Auswahl oben links, auch im Karten-Editor, Wechsel sofort). Neuer Standard ist "Klassisch" mit der gewohnten OpenStreetMap-Karte und flacher Ansicht; "Automatisch" wählt am Tag "Klar und ruhig" statt 3D. Grund: die dunkle Karte war schlecht lesbar.

## Runde 14: Rückmeldungen aus dem Testspiel (Migration 0022)
- Spielzeit gilt alles inklusive: sie zählt ab dem Start, der Vorsprung ist ein Teil davon, und das Spiel endet pünktlich ohne Nachspielzeit (`ends_at = deadline_at = start_at + duration`). Gejagt wird `duration - head_start` (mindestens 5 min, `hunt_minutes`). Alle Zeiten der Jagd (Pings, Verkleinerung, Joker, Fluchtpunkt) müssen in diese Jagdzeit passen. "Ankunftsfrist nach Ende" ist fest 0.
- Nach dem Vorsprung kommt sofort ein Ping für alle Spieler, danach im eingestellten Abstand. "Erster Ping nach dem Vorsprung" ist entfernt (fest 0).
- Fluchtpunkt: Bekanntgabe X min vor Schluss (`exit.reveal_minutes_before_end`, Standard 10), nutzbar erst Y min vor Schluss (`exit.usable_minutes_before_end`, Standard 2, höchstens X). Gerettet ist, wer zwischen Freigabe und Spielende frei im Kreis ist; wer schon vorher dort steht, zählt ab der Freigabe. Die Spieler sehen einen Countdown bis zur Freigabe und bekommen bei der Freigabe einen Alarm.
- Blitzjagd startet auf der Karte (Knopf unten links), mit Ziel wählen und einmal bestätigen. Beim Start kommt sofort die erste Abfrage; jede weitere mit einem Tippen auf der Karte. Nie zweimal hintereinander dieselbe Person, auch wenn nur noch eine frei ist.
- Spieler haben Buchstaben (A, B, C …), Hunter H1, H2 … Pings sind je Spieler nummeriert (A1, A2 …) und in der Farbe des Spielers. Der neueste Ping je Spieler ist gelb umrandet, Blitzjagd-Pings rot. Jeder wählt auf der Karte selbst: nur letzter, letzte 3, alle oder eine eigene Anzahl (gespeichert auf dem Gerät, `hm-pings`).
- Karte kann immer nach Norden zeigen (Knopf N, `hm-map.north`).
- Countdown ausserhalb des Spielfelds oder in einer Gefahrenzone läuft auch ab, wenn das Handy keinen neuen Standort schickt (Tick prüft mit dem letzten Standort).
- Zu Beginn jedes Spiels bestätigt jede Person einen Sicherheitshinweis (nur ein Spiel, auf eigene Gefahr; gespeichert auf dem Gerät).
- Chat: Hunter sehen zuerst "Alle Nachrichten" (auch die der Spieler) und können durch Antippen im passenden Chat antworten; neue Nachrichten zeigen einen Punkt am Chat-Tab und klingeln in der Handy-App. Nachrichten werden zusätzlich alle 10 s abgefragt.
- Handy-App: wichtige Meldungen kommen immer auch als Benachrichtigung des Handys (Ton und Vibration vom Handy), im Hintergrund alle. Der Spielstand wird auch im Hintergrund alle 10 s und nach jedem gesendeten Standort geholt. Neuer Android-Kanal `hunt-alarm-v2` mit höchster Wichtigkeit.
- Karten-Editor: eigener Standort als blauer Punkt; Spielfeld-Kreis um den eigenen Standort; Startpunkt "hier"; Zonen haben keine Namen mehr (kein Namensfeld); Schritt "Kleiner werden" kommt vor den Fluchtpunkten; Fluchtpunkte lassen sich nacheinander antippen und müssen in der kleinsten Zone liegen. Die Liste heisst "Alles auf der Karte".
- Neue Spielart "Eigenes Spiel": wer eine Vorlage verändert, spielt automatisch ein eigenes Spiel.
- Wiederholung: neben dem Schnelldurchlauf Ping für Ping durchklicken.
- Vergangene Spiele löschen: der Host löscht das Spiel für alle, alle anderen entfernen es aus ihrer Liste (`delete_game`).
- Fluchtpunkte in einer Gefahrenzone oder ausserhalb der kleinsten Zone verschiebt der Karten-Editor automatisch an die nächste erlaubte Stelle (mit etwas Abstand zum Rand und zu anderen Fluchtpunkten), beim Antippen, Verschieben, nach neuen Gefahrenzonen und nach Änderungen der Verkleinerung.

## Runde 15: zweites Testspiel (Migration 0023)
- Pause: Wer das Spiel erstellt hat, kann es pausieren (mit freiwilligem Grund) und fortsetzen. Die Zeit hält an: Spielende, Pings, Countdowns, Verkleinerung und Joker verschieben sich um die Pause (`host_pause`, `host_resume`, `resume_shift`). Während einer Pause des Hosts lassen sich die Regeln ändern; die Zeiten werden dann ab dem Start neu berechnet (bisherige Pausen zählen nicht mit). Ersetzt "keine Pause" aus Runde 11. `games.pause_kind`: `notfall` (SOS), `host`, `sicherheit`. Ein Notfall beendet nie eine Pause des Hosts.
- Sicherheitshinweis: jede Person (Spieler, Hunter) bestätigt ihn im Spiel, gespeichert in der Datenbank (`participants.safety_ok_at`). Der Vorsprung startet erst, wenn alle bestätigt haben; bis dahin steht die Zeit still (`pause_kind = sicherheit`). Der Host sieht, wer fehlt, und kann notfalls trotzdem starten.
- Fangen: kein QR-Code mehr. Immer beide Wege, jeder für sich: der Hunter gibt den 6-stelligen Zahlencode des Spielers ein (gilt sofort) oder meldet "Spieler X gefangen" und der Spieler bestätigt oder lehnt ab. Ablehnen heisst: der Fang gilt nicht. Ohne Antwort entscheidet wie bisher der GPS-Abstand. `catch.method` ist fest `['qr', 'touch_confirm']` ('qr' heisst intern weiter so, ist aber der Zahlencode).
- Spiel abgebrochen: keiner hat gewonnen, niemand gilt als verloren.
- Regeneration-Joker: keine Pings und keine Blitzjagd auf den Spieler, Fangen geht aber weiterhin (so war es schon, jetzt steht es im Text).
- Wiederholung zeigt den ganzen Weg jeder Person ab Spielstart (ein Punkt alle 10 s, die genaueste Messung), nicht nur die Pings. Die Standortdaten werden wie bisher nach 30 Tagen gelöscht. (Ersetzt in Runde 16b: sie bleiben erhalten.)
- Chat: Spieler haben genau einen Verlauf mit den Huntern (ihre Nachrichten, Antworten der Hunter und Nachrichten an alle). Hunter sehen je Spieler denselben Verlauf.
- Hunter sehen einen Timer bis zum nächsten Ping (auf der Karte und unter Aktionen). Spieler ausserhalb des Spielfelds oder in einer Gefahrenzone: das Handy vibriert ohne Pause, bis sie wieder drin sind. Ist GPS aus, kommt seit 3 min kein Standort an oder sind Benachrichtigungen aus, erscheint ein grosser Hinweis.
- Pings auf der Karte als Kartennadel aus einem Guss (abgerundetes Schild, weich auslaufende Spitze, feiner Zielpunkt): die Spitze zeigt genau auf den Ort (`src/lib/pin.ts`). Beschriftungen auf Karten immer dunkel mit heller Schrift.
- Spiel erstellen: Grundeinstellungen sind die des zuletzt erstellten Spiels. Eigene Varianten lassen sich speichern (`config_templates`, nur für die eigene Person). Vergangene Spiele haben "Nochmal spielen": gleiche Einstellungen und, wenn man es bei der Rückfrage wählt, dieselbe Karte (`copy_map`; Stufen der automatischen Verkleinerung entstehen beim Start neu). Termin als Datum und Uhrzeit nebeneinander.
- Gruppen: vergangene Spiele stehen im "Verlauf", ohne Beitreten-Knopf.
- Karten-Editor beginnt immer bei Schritt 1 und springt nie von selbst weiter. Empfohlene Fläche nach Marvins Formel: `2 km² × (Ping-Abstand ÷ 4 min)^0,84 × (Anzahl Pings ÷ 5)^0,5 × ((Spieler + Hunter) ÷ 2)^0,3 × Fortbewegung`, Anzahl Pings = Spieldauer ÷ Ping-Abstand, Fortbewegung zu Fuss 1, Velo/Trottinett 2, ÖV 3 (schnellstes erlaubtes Mittel). Die App erstellt auf Wunsch einen Kreis oder ein Rechteck (3 : 2) mit dieser Fläche; selbst zeichnen geht weiterhin. Hinweis: nur ein Richtwert, die Umgebung zählt mit. Die Grösse des Spielfelds ist mit Marvin abgestimmt (erledigt).
- In der Kopfzeile heisst es "Spielfeld-Stufe 1/4" statt "Phase 1/4": die Stufe der Verkleinerung des Spielfelds.
- Push-Nachrichten (Alarm bei gesperrtem Bildschirm, auch wenn die App beendet ist) sind noch nicht gebaut: Android braucht ein Firebase-Projekt von Marvin, das iPhone das Apple Developer Program (99 USD/Jahr). Marvin hat am 2026-11-11 entschieden: vorerst nicht. Standort im Hintergrund gibt es in der Handy-App schon.
- Pings nie verschoben: Der Server nimmt für einen Ping den genauesten echten Messpunkt der letzten 20 Sekunden (vorher Median von Breite und Länge einzeln über 30 s, was einen Punkt ergeben konnte, an dem niemand war). Auf dem iPhone misst die App immer mit "Best" und Aktivität "Fitness" (zu Fuss), nie mit "Navigation", damit iOS den Standort nicht auf Strassen zieht (Patch des Plugins in `patches/`, angewendet mit `patch-package` beim `npm install`). Ist der Standort ungenauer als 150 m, kommt ein grosser Hinweis, "Genauer Standort" einzuschalten.

## Runde 16 (2026-11-12)
- Spieler sehen die Pings der anderen Spieler, sobald die Hunter sie sehen. Ausgenommen: Blitzjagd-Pings der anderen. Zweck: sich besser auf der Karte verteilen.
- Jeder Spieler wählt selbst: nur letzter / letzte 3 / alle / eigene Anzahl Pings, und ob die Pings der anderen Spieler sichtbar sind (nur auf dem eigenen Gerät).
- Neuer Joker „Nähe-Radar“ 📡: beim Erstellen werden Abstand (50–500 m, Standard 500 m) und Dauer eingestellt. Solange er wirkt, sieht der Spieler nur, ob ein Hunter näher ist (nie wo). Kommt ein Hunter nah, klingelt das Handy laut wie bei einer Blitzjagd. Zählt Hunter mit Standort der letzten 10 min.
- Joker „Richtung zum nächsten Hunter“ wird nicht gebaut (Marvin).
- Der Nähe-Alarm (zwei Spieler zu nahe beieinander) ist ganz entfernt (Marvin): keine Warnung, kein Ping an die Hunter, keine Einstellung mehr. Migration 0024 nimmt die Prüfung aus dem Spieltakt und löscht Funktion und Tabelle. Frühere Einträge zum Nähe-Alarm gelten nicht mehr.
- Nachtrag (0025): Mit dem Nähe-Alarm fällt auch „Ab jetzt dürft ihr auch zusammen sein“ in der Fluchtpunkt-Meldung und in den Hilfetexten weg. Hilfetexte sagen nicht mehr „ohne Pause“ (der Host kann pausieren, die Pause wird angehängt).
- Nachtrag (0026): Nähe-Radar klingelt jedes Mal, wenn ein Hunter neu nah kommt (nicht erneut, solange er nah bleibt; eine kurze GPS-Lücke zählt nicht als weg). Alle Teilnehmenden senden ihren Standort fix alle 5 s (Einstellung „GPS-Intervall“ entfernt, Marvin). Die Wege werden fix 30 Tage nach Spielende gelöscht (Einstellung „Standortdaten löschen nach“ entfernt, Marvin, wegen 500 MB Gratis-Speicher bei Supabase). Jeder Teilnehmende kann bei einem vergangenen Spiel „Für immer behalten“ drücken (und wieder aufheben, solange es jünger als 30 Tage ist); dann wird bei diesem Spiel nichts gelöscht. Mit einem gelöschten Spiel verschwinden die Daten weiterhin.

## Runde 17 (2026-11-14)
- Sprache wird beim allerersten Öffnen gewählt (eigener Bildschirm vor der Anmeldung), zusätzlich oben im Profil-Formular. Beispiel-Benutzername ohne echten Namen („fuchs_92“).
- Spielfeld verlassen: kein Countdown mehr. Sofort live für die Hunter, Alarm und Dauer-Vibration, bis man zurück ist. Gefahrenzonen behalten den Countdown (Marvin). Migration 0027.
- Fluchtpunkt: öffnet erst, wenn die Spielzeit abgelaufen ist. Danach läuft das Spiel weiter, bis alle Spieler gefangen oder angekommen sind, höchstens die eingestellte Zeit („Danach höchstens“, 5–240 min, Standard 60; Marvin wollte eine Höchstzeit). Wer dann nicht angekommen ist, hat verloren. Ohne Fluchtpunkt endet das Spiel mit der Spielzeit; wer noch frei ist, gewinnt, sonst die Hunter. Die Einstellung „nutzbar ab vor Schluss“ entfällt (fest 0). Ersetzt die Regeln zum Fluchtpunkt aus 0022.
- Blitzjagd: jede weitere Abfrage wird wie der Start mit „Ja“ bestätigt.
- Karte: nur ein Norden-Knopf (N), kein Kompass, kein Standort-Knopf, kein 3D-Knopf (3D mit zwei Fingern, Häuser erscheinen beim Neigen). Kleine Karte: Infos über und unter der Karte; grosse Karte: eigener Buchstabe, Zeit, nächster Ping, Radar, SOS oben; Joker, Fang-Code (Spieler) bzw. Blitzjagd, Fangen (Hunter) unten. „gesendet vor“ entfernt. Meldungen lassen sich wegwischen (nur auf dem eigenen Gerät).
- Karten-Editor: Spielfeld mit − / + verkleinern und vergrössern. Fluchtpunkte müssen mit dem ganzen Ankunftskreis in der innersten Zone liegen und werden sonst automatisch verschoben. Fehler der Karte erscheinen schon beim Speichern.
- Laufendes Spiel: auf Start, Gruppen, Profil und den Spielseiten grosse Meldung „Zurück ins Spiel“; mit „Nicht jetzt“ bleibt ein roter Balken.
- Chat wie bei WhatsApp: Liste aller Chats (letzte Nachricht, Zeit, ungelesen), antippen öffnet.
- Antippen-Vibration nur in der Handy-App und nur, wenn sie auf dem Handy eingeschaltet ist (iPhone: System-Haptik; Android: Haptisches Feedback). Alarm-Ton auf dem iPhone auch bei Stumm-Schalter.
- Offen (Vorschlag an Marvin): was aus „Aktionen“ der Spieler wohin kommt; wie die App selbsterklärender wird; Sprachkanal für Hunter (Empfehlung: nicht in die App).
- Nachtrag Runde 17 (Marvin): Standardsprache = Sprache des Handys, sonst Englisch (nicht mehr Deutsch). Kein Sprachkanal in der App.
- Spielansicht neu: Leiste Karte · Aktionen · Chat · Mehr. Aktionen der Spieler nur Joker und Fang-Code (plus Nähe-Radar, wenn aktiv). Wichtiges (Fang bestätigen, ausserhalb, Gefahrenzone, Blitzjagd auf dich, Verschanzen-Frage, Fluchtpunkt, „Ich bin am Fluchtpunkt“) erscheint nur, wenn es gilt, direkt bei der Karte (auch im Vollbild). Mehr: Meldungen, Status, Verschanzen melden, Aufgeben, Alarm, Spiel steuern (Host), Spielregeln.
- Selbsterklärend: lange Erklärungen hinter ⓘ, kurze Knopf-Texte mit Zeichen. Hinweise beim ersten Spiel je Rolle direkt auf der Karte (einmalig). Helfer beim Erstellen geht jeden Bereich durch und öffnet sich beim ersten Mal von selbst, ebenso in der Lobby (Karte, Einladen, Rollen, Bereit, Start). Keine Übungsrunde, keine verkürzte Erstellung (Marvin).

## Runde 18 (2026-11-14)
- Helfer und Hinweise: kleine Karte ganz unten am Bildschirm (nicht mehr in der Mitte). Zeigt sie auf etwas weit unten (z. B. die Leiste), rückt sie nach oben.
- Hunter zeichnen auf der Karte: Stift am Kartenrand öffnet die Werkzeuge Punkt, Strich, Kreis, Fläche, Farbe, Text, Verschieben, Löschen, Alles löschen. Alle Hunter sehen es sofort und jeder kann alles ändern; Spieler und Zuschauer nie (Tabelle hunter_drawings, Migration 0028).
