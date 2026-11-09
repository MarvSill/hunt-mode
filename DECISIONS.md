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
