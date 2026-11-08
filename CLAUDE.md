# Hunt Mode (Manhunt-App)

Web-App (PWA) für das Stadtspiel Manhunt: Spieler verstecken sich, Hunter (Taskforce) jagen sie.
Live: https://marvsill.github.io/manhunt-app/ · Repo: github.com/MarvSill/manhunt-app

## Arbeitsweise
- Besitzer: Marvin. Antworten auf Deutsch, kurz und Schritt für Schritt. Er möchte, dass Claude alles selbst erledigt.
- Ein Push auf `main` veröffentlicht automatisch (GitHub Action "App veröffentlichen": Datenbank-Migrationen, Build, GitHub Pages).
  Darum: Änderungen auf einem Branch machen, Typecheck und Tests laufen lassen, dann Pull Request.
- Nie den Supabase service_role Key oder das Datenbank-Passwort in den Code. Geheimnisse nur als GitHub Secret (`SUPABASE_ACCESS_TOKEN`).
- Spezifikation: `docs/Manhunt_App_Spezifikation.pdf`. Nur ergänzen, nie Inhalte löschen. Entscheidungen: `DECISIONS.md`.

## Befehle
- `npm install` einmalig, dann `npm run dev` (App unter http://localhost:5173, nutzt die Live-Datenbank aus `.env.local`)
- `npm run typecheck` · `npm test` (Unit-Tests, vitest) · `npm run build`

## Aufbau
- `src/pages/` Bildschirme ausserhalb des Spiels (Start, Erstellen, Lobby, Karten-Editor, Regeln, Profil, Gruppen, Einführung, Datenschutz)
- `src/play/` Spielansicht je Rolle (Spieler, Hunter, Spielleitung), Chat, Notfall, Ergebnis
- `src/components/` wiederverwendbare Teile (Karte, Regel-Editor, Schnell-Einstellungen, Icons, Hilfe)
- `src/shared/` Regelwerk: `config.ts` (alle Einstellungen, zod), `presets.ts`, `validation.ts`, `timeRules.ts` (Zeiten passen immer zur Spieldauer)
- `src/lib/` Supabase-Zugriff, Engine-API, GPS-Tracker
- `supabase/migrations/` Datenbank und Spiel-Engine (PL/pgSQL, läuft alle 15 s per pg_cron). Neue Änderungen immer als neue Datei `00NN_name.sql`, nie alte ändern.
- `scripts/supabase-setup.mjs` richtet Supabase aus der GitHub Action ein.

## Regeln, die gelten
- Notfall geht immer an alle Hunter und die Spielleitung; Nummern 117 / 144 / 112.
- Spieler schreiben nie mit anderen Spielern; Ankündigungen nur die Spielleitung.
- Joker nur für Spieler (Regeneration, Hunter-Standorte, Catch-Free).
- Standort wird nur gesendet, solange die App offen ist (Browser-Grenze).
