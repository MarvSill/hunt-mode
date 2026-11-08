import type { ConfigIssue } from '../shared/validation';

const LABEL = { error: 'Fehler', warning: 'Hinweis', autofix: 'Angepasst' } as const;
const CLASS = { error: 'error', warning: 'warning', autofix: 'info' } as const;

/**
 * Prüfergebnis der Regeln. `compact`: automatische Anpassungen nur als eine aufklappbare Zeile,
 * und nichts anzeigen, wenn alles passt.
 */
export default function IssueList({ issues, compact }: { issues: ConfigIssue[]; compact?: boolean }) {
  const fixes = issues.filter((i) => i.level === 'autofix');
  const rest = compact ? issues.filter((i) => i.level !== 'autofix') : issues;
  if (issues.length === 0) return compact ? null : <div className="notice ok">✓ Regeln geprüft: alles passt zusammen.</div>;
  return (
    <div className="stack" style={{ gap: 8 }}>
      {rest.map((i) => (
        <div key={i.code} className={`notice ${CLASS[i.level]}`}>
          <strong>{LABEL[i.level]}:</strong> {i.message}
        </div>
      ))}
      {compact && fixes.length > 0 && (
        <details className="notice info small">
          <summary>{fixes.length === 1 ? '1 Wert wurde' : `${fixes.length} Werte wurden`} automatisch angepasst, damit alles zusammenpasst</summary>
          <ul style={{ margin: '8px 0 0', paddingLeft: 18 }}>
            {fixes.map((i) => <li key={i.code}>{i.message}</li>)}
          </ul>
        </details>
      )}
    </div>
  );
}
