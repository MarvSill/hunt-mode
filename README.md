# Hunt Mode

Web-App (PWA) für ein Verfolgungsspiel in der Stadt: Spieler verstecken sich und
fliehen durch die Stadt, die Hunter jagen sie als Team. Das Spiel läuft am Stück,
ohne Pause und ohne Spielleitung: die App regelt alles selbst.

## Was die App kann

- Konten mit E-Mail und Passwort, Profil mit Notfallkontakt, Gruppen (Crews) mit Einladungslink und Chat
- Vollständiges, einstellbares Regelwerk mit 3 Vorlagen (Schnell 90 min, Stadtabend 3 h, Wochenende 24 h),
  Regel-Prüfung und Regel-Editor mit Protokoll
- Spiel erstellen, per Code/Link beitreten, Live-Lobby, Rollen (auch für den Host), Gerätecheck
- **Karten-Editor**: Spielfeld, das alle X Minuten kleiner werden kann, Sektionen, Center/Kern/Aussen mit
  eigenem Ping-Intervall, Sperrzonen, sichere Zonen, Fluchtpunkt-Kandidaten, HQ; Ortssuche, GeoJSON-Import/-Export
- **Spiel-Engine auf dem Server** (läuft alle 15 s, auch wenn niemand die App offen hat):
  Vorsprung, Pings mit Frische-Regel, Blitzjagden mit allen Einschränkungen,
  Fang per rotierendem QR-Code oder Bestätigung, Ausserhalb-Zeit, Sperrzonen, ÖV-Pflicht und Erkennung,
  Verschanzen, Nähe-Alarm, Budget mit Kauf-Ping, Joker mit Freischaltzeit (Regeneration, Hunter-Standorte,
  Schutzschild), Verstösse mit Eskalation, Notfall, Fluchtpunkt, Spielende und Sieger
- **Ansichten** für Spieler, Hunter (inkl. Zentrale) und Zuschauer: Live-Karte, Meldungen mit Ton/Vibration,
  Chat (Spieler ↔ Hunter, Hunter-Team; Spieler untereinander nie)
- **Probelauf**: Spiel mit Vorspul-Knöpfen (+1/+5/+15/+60 min), um alles in wenigen Minuten auszuprobieren
- Ergebnis-Bildschirm mit Wiederholung (Zeitschieber über alle Spuren und Pings)

Grenzen und Entscheidungen stehen in [DECISIONS.md](DECISIONS.md).

## Einrichten (einmalig, fast alles automatisch)

Die GitHub Action [`App veröffentlichen`](.github/workflows/deploy.yml) erledigt alles selbst:
Supabase-Projekt `hunt-mode` in Frankfurt anlegen, Datenbank einspielen (PostGIS, pg_cron, Speicher
für Fotos), Anmeldung einstellen, App bauen und auf GitHub Pages stellen. Sie läuft bei jedem Push
auf `main`, von Hand unter **Actions**, und alle 3 Tage (hält das Gratis-Projekt wach).

Von Hand nötig sind nur:

1. **Repository öffentlich machen** (GitHub Pages ist für private Repositories kostenpflichtig):
   **Settings** > **General** > ganz unten **Change visibility** > **Public**.
2. **Pages einschalten**: **Settings** > **Pages** > bei **Source** „GitHub Actions“ wählen.
3. **Supabase-Token**: auf supabase.com mit GitHub anmelden, oben rechts Profil > **Account preferences**
   > **Access Tokens** > **Generate new token**.
4. Das Token in GitHub eintragen: **Settings** > **Secrets and variables** > **Actions** >
   **New repository secret**, Name `SUPABASE_ACCESS_TOKEN`.

Danach unter **Actions** > **App veröffentlichen** > **Run workflow**. Die App ist dann unter
`https://<github-name>.github.io/hunt-mode/` erreichbar. Auf dem Handy öffnen und
„Zum Home-Bildschirm hinzufügen“: dann läuft sie wie eine App.

Konten brauchen keine Bestätigungsmail: Der Gratis-Mailversand von Supabase erreicht nur
Team-Mitglieder. Wer Bestätigungsmails will, trägt einen SMTP-Dienst ein (Supabase >
**Authentication** > **Emails** > **SMTP Settings**) und schaltet „Confirm email“ wieder ein.

### Von Hand (ohne Action)

Inhalt von [`supabase/alles_in_einem.sql`](supabase/alles_in_einem.sql) im Supabase **SQL Editor**
ausführen, unter **Authentication** Site URL und Redirect URLs (`<adresse>/**`) setzen, und die App
mit `VITE_SUPABASE_URL` und `VITE_SUPABASE_ANON_KEY` (Publishable key, nie den Secret-Key) bauen,
z. B. auf Vercel. Läuft die App unter einem Unterpfad, zusätzlich `VITE_BASE=/pfad/` setzen.

## Entwickeln

```bash
npm install
cp .env.example .env.local   # Werte eintragen
npm run dev                  # http://localhost:5173
npm test                     # Regel-Tests
npm run build                # Typprüfung und Produktions-Build
npm run sql                  # supabase/alles_in_einem.sql neu erzeugen
```

Lokal mit eigener Datenbank: `npx supabase start` (braucht Docker) wendet die Migrationen an;
Bestätigungs-Mails landen dann in Mailpit unter http://127.0.0.1:54324.

## Aufbau

| Ordner | Inhalt |
| --- | --- |
| `src/shared/` | Regelwerk ohne UI: Konfigurationsschema, Vorlagen, Prüfungen, Rollenverteilung (mit Tests) |
| `src/lib/` | Supabase-Anbindung, Anmeldung, Spiel-Aktionen |
| `src/pages/`, `src/components/` | Bildschirme (Start, Lobby, Regeln, Karten-Editor, Gruppen) |
| `src/play/` | Laufendes Spiel: Karte, Spieler- und Hunter-Ansicht, Chat, Notfall, Ergebnis |
| `supabase/migrations/` | Datenbank: Tabellen, Rechte (RLS), Spiel-Engine (`0004`), Aktionen (`0005`), Spielstand je Rolle (`0006`), Zeitplan (`0007`) |

## Auf dem Laptop mit VS Code und Claude Code

1. Ordner in VS Code öffnen (`code .`), die empfohlenen Erweiterungen installieren (Claude Code ist dabei).
2. `npm install`, dann `npm run dev`: die App läuft unter http://localhost:5173 mit der Live-Datenbank.
3. In Claude Code einfach auf Deutsch sagen, was geändert werden soll. `CLAUDE.md` erklärt Claude das Projekt.
4. Änderungen kommen über einen Pull Request auf `main`; danach ist die App automatisch aktualisiert.
