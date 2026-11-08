# Hunt Mode

Web-App (PWA) für ein Verfolgungsspiel in der Stadt: Spieler verstecken sich, die Hunter jagen sie als Team.
Live: https://marvsill.github.io/hunt-mode/ · Repo: github.com/MarvSill/hunt-mode

## Arbeitsweise
- Besitzer: Marvin. Antworten auf Deutsch, kurz und Schritt für Schritt. Er möchte, dass Claude alles selbst erledigt.
- Ein Push auf `main` veröffentlicht automatisch (GitHub Action "App veröffentlichen": Datenbank-Migrationen, Build, GitHub Pages).
  Darum: Änderungen auf einem Branch machen, Typecheck und Tests laufen lassen, dann Pull Request.
- Nie den Supabase service_role Key oder das Datenbank-Passwort in den Code. Geheimnisse nur als GitHub Secret (`SUPABASE_ACCESS_TOKEN`).
- Spezifikation: liegt nur lokal in `docs/` (nicht im Repo). Nur ergänzen, nie Inhalte löschen. Entscheidungen: `DECISIONS.md` (geht bei Widerspruch vor).
- Keine Bezüge zu anderen Spielen, Serien oder deren Begriffen in App, Code oder Texten.

## Befehle
- `npm install` einmalig, dann `npm run dev` (App unter http://localhost:5173, nutzt die Live-Datenbank aus `.env.local`)
- `npm run typecheck` · `npm test` (Unit-Tests, vitest) · `npm run build`

## Aufbau
- `src/pages/` Bildschirme ausserhalb des Spiels (Start, Erstellen, Lobby, Karten-Editor, Regeln, Profil, Gruppen, Einführung, Datenschutz)
- `src/play/` Spielansicht je Rolle (Spieler, Hunter, Zuschauer), Chat, Notfall, Ergebnis
- `src/components/` wiederverwendbare Teile (Karte, Regel-Editor, Schnell-Einstellungen, Icons, Hilfe)
- `src/shared/` Regelwerk: `config.ts` (alle Einstellungen, zod), `presets.ts` (Vorlagen), `validation.ts`, `timeRules.ts` (Zeiten passen immer zur Spieldauer)
- `src/lib/` Supabase-Zugriff, Engine-API, GPS-Tracker
- `supabase/migrations/` Datenbank und Spiel-Engine (PL/pgSQL, läuft alle 15 s per pg_cron). Neue Änderungen immer als neue Datei `00NN_name.sql`, nie alte ändern.
- `scripts/supabase-setup.mjs` richtet Supabase aus der GitHub Action ein.

## Regeln, die gelten
- Keine Spielleitung: die App regelt alles, der Host wählt selbst eine Rolle.
- Das Spiel läuft am Stück: keine Spieltage, keine jagdfreien Zeiten, keine Pause.
- Begriffe: Hunter-Team, Blitzjagd, Ping, Fluchtpunkt, Schutzschild.
- Notfall geht immer an alle Hunter (und den Host); Nummern 117 / 144 / 112.
- Chat: Spieler schreiben den Huntern (alle Hunter lesen mit), Hunter einem oder allen Spielern, Hunter-Team unter sich. Spieler nie mit anderen Spielern.
- Joker nur für Spieler (Regeneration, Hunter-Standorte, Schutzschild), jeweils nach einer eingestellten Spielzeit.
- Standort wird nur gesendet, solange die App offen ist (Browser-Grenze).
