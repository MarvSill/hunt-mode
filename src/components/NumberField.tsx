import { useState } from 'react';

/**
 * Zahlenfeld zum Eintippen: beim Antippen wird die Zahl markiert (einfach drüber tippen),
 * das Feld darf beim Tippen leer sein, keine Schritt-Regeln des Browsers.
 * Gültige Zahlen gelten sofort; beim Verlassen wird auf min/max gekürzt.
 */
export default function NumberField({ value, min, max, onChange, label }: {
  value: number; min: number; max: number; onChange: (v: number) => void; label: string;
}) {
  const [text, setText] = useState<string | null>(null);
  return (
    <input
      type="text"
      inputMode="numeric"
      pattern="[0-9]*"
      enterKeyHint="done"
      autoComplete="off"
      aria-label={label}
      value={text ?? String(value)}
      onFocus={(e) => {
        const el = e.currentTarget;
        setText(String(value));
        setTimeout(() => el.select(), 0);
      }}
      onChange={(e) => {
        const s = e.target.value.replace(/\D/g, '').slice(0, 6);
        setText(s);
        const n = Number(s);
        if (s !== '' && n >= min && n <= max) onChange(n);
      }}
      onBlur={() => {
        if (text !== null && text !== '') {
          const n = Number(text);
          if (n < min || n > max) onChange(Math.min(max, Math.max(min, n)));
        }
        setText(null);
      }}
      onKeyDown={(e) => {
        if (e.key === 'Enter') e.currentTarget.blur();
      }}
    />
  );
}
