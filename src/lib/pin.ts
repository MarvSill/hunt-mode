/**
 * Ping als Kartennadel: eine Form aus einem Guss (abgerundetes Schild mit weich auslaufender Spitze).
 * Die Spitze mit dem feinen Zielpunkt zeigt genau auf den Ort. Optional ein farbiger Ring (letzter Ping, Blitzjagd).
 */
export const PIN_TIP_OFFSET = 3; // so weit liegt der Zielpunkt über dem unteren Rand (px)

export function pinElement(color: string, text: string, ring?: string, opacity = 1): HTMLElement {
  const h = 24; // Höhe des Schilds
  const w = Math.max(28, 12 + text.length * 8.5); // Breite je nach Textlänge
  const r = 9; // Rundung
  const tail = 9; // Länge der Spitze
  const o = 5; // Rand für Ring und Schatten
  const W = w + o * 2;
  const H = h + tail + o + PIN_TIP_OFFSET + 2;
  const cx = o + w / 2;
  const top = o;
  const bot = o + h;
  const tip = bot + tail;
  const d = [
    `M${o + r},${top}`, `H${o + w - r}`, `A${r},${r} 0 0 1 ${o + w},${top + r}`, `V${bot - r}`, `A${r},${r} 0 0 1 ${o + w - r},${bot}`,
    `H${cx + 6}`, `C${cx + 3},${bot} ${cx + 1.2},${tip - 3} ${cx},${tip}`, `C${cx - 1.2},${tip - 3} ${cx - 3},${bot} ${cx - 6},${bot}`,
    `H${o + r}`, `A${r},${r} 0 0 1 ${o},${bot - r}`, `V${top + r}`, `A${r},${r} 0 0 1 ${o + r},${top}`, 'Z',
  ].join(' ');
  const el = document.createElement('div');
  el.className = 'hm-pin';
  el.style.cssText = `width:${W}px;height:${H}px;opacity:${opacity}`;
  el.innerHTML = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" aria-hidden="true">
    <ellipse cx="${cx}" cy="${tip + 1}" rx="5" ry="1.8" fill="rgba(0,0,0,.28)"/>
    ${ring ? `<path d="${d}" fill="none" stroke="${ring}" stroke-width="7" stroke-linejoin="round"/>` : ''}
    <path d="${d}" fill="${color}" stroke="#fff" stroke-width="2.2" stroke-linejoin="round" style="filter:drop-shadow(0 1.5px 2px rgba(0,0,0,.35))"/>
    <text x="${cx}" y="${top + h / 2 + 0.5}" text-anchor="middle" dominant-baseline="central" fill="#fff"
      font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" font-size="12.5" font-weight="800" letter-spacing="-0.2">${text}</text>
    <circle cx="${cx}" cy="${tip}" r="2.6" fill="#fff" stroke="${color}" stroke-width="1.6"/>
  </svg>`;
  return el;
}
