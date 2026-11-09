import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Unterpfad, z. B. /hunt-mode/ auf GitHub Pages.
const base = process.env.VITE_BASE || '/';

export default defineConfig({
  base,
  plugins: [
    react(),
    VitePWA({
      // In der Handy-App kein Service Worker (die App hat ihre Dateien schon dabei).
      disable: process.env.VITE_NATIVE === '1',
      registerType: 'autoUpdate',
      includeAssets: ['icon.svg', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png', 'apple-touch-icon.png'],
      workbox: {
        maximumFileSizeToCacheInBytes: 3 * 1024 * 1024,
        navigateFallbackDenylist: [/^\/auth/, /^\/rest/],
        // Kartenkacheln für Funklöcher zwischenspeichern (Kapitel 23.6).
        runtimeCaching: [
          {
            // Kartenstile und Vektor-Kacheln (OpenFreeMap, CARTO) für Funklöcher zwischenspeichern.
            urlPattern: /^https:\/\/(tiles\.openfreemap\.org|basemaps\.cartocdn\.com|tiles\.basemaps\.cartocdn\.com)\/.*/,
            handler: 'StaleWhileRevalidate',
            options: { cacheName: 'map-tiles', expiration: { maxEntries: 4000, maxAgeSeconds: 14 * 24 * 3600 }, cacheableResponse: { statuses: [0, 200] } },
          },
          {
            urlPattern: /^https:\/\/[abc]\.tile\.openstreetmap\.org\/.*/,
            handler: 'CacheFirst',
            options: { cacheName: 'osm-tiles', expiration: { maxEntries: 2000, maxAgeSeconds: 14 * 24 * 3600 }, cacheableResponse: { statuses: [0, 200] } },
          },
        ],
      },
      manifest: {
        name: 'Hunt Mode',
        short_name: 'Hunt Mode',
        description: 'Verstecken in der Stadt mit Freunden: Spieler verstecken sich, die Hunter jagen sie.',
        lang: 'de',
        theme_color: '#0d1117',
        background_color: '#0d1117',
        display: 'standalone',
        orientation: 'portrait',
        start_url: base,
        scope: base,
        id: base,
        categories: ['games', 'sports'],
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
          { src: 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
          { src: 'icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
        ],
      },
    }),
  ],
  test: {
    include: ['src/**/*.test.ts'],
  },
});
