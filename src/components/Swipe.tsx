import { useRef, useState, type ReactNode } from 'react';

/** Zur Seite wischen = wegwischen (wie Meldungen auf dem Handy). Ein kurzes Antippen bleibt ein normaler Klick. */
export default function Swipe({ onDismiss, children, className, role }: { onDismiss: () => void; children: ReactNode; className?: string; role?: string }) {
  const start = useRef<{ x: number; y: number; id: number } | null>(null);
  const [dx, setDx] = useState(0);
  const [gone, setGone] = useState(false);
  return (
    <div
      className={className}
      role={role}
      style={{ transform: gone ? `translateX(${dx > 0 ? 120 : -120}%)` : `translateX(${dx}px)`, opacity: gone ? 0 : 1 - Math.min(0.7, Math.abs(dx) / 300), transition: start.current ? 'none' : 'transform .2s, opacity .2s', touchAction: 'pan-y' }}
      onPointerDown={(e) => { start.current = { x: e.clientX, y: e.clientY, id: e.pointerId }; }}
      onPointerMove={(e) => {
        const s = start.current;
        if (!s || s.id !== e.pointerId) return;
        const x = e.clientX - s.x;
        if (Math.abs(x) > 8 && Math.abs(x) > Math.abs(e.clientY - s.y)) setDx(x);
      }}
      onPointerUp={() => {
        const far = Math.abs(dx) > 90;
        start.current = null;
        if (far) {
          setGone(true);
          setTimeout(onDismiss, 180);
        } else setDx(0);
      }}
      onPointerCancel={() => { start.current = null; setDx(0); }}
    >
      {children}
    </div>
  );
}
