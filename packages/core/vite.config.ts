import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath, URL } from 'node:url'

// Userspace is aliased but never statically imported from Core — see
// docs/adr/0004-core-never-statically-imports-userspace.md. Surfaces are
// discovered and loaded with dynamic import() so a broken one cannot take
// the chat down with it.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
      '@userspace': fileURLToPath(new URL('../userspace', import.meta.url)),
    },
  },
  server: {
    /*
      Localhost by default. Set VARNICK_HOST to bind elsewhere:

        VARNICK_HOST=$(tailscale ip -4) bun run dev   # tailnet only
        VARNICK_HOST=0.0.0.0            bun run dev   # tailnet AND local wifi

      Prefer the first. 0.0.0.0 puts a dev server holding an agent session on
      every network the machine is attached to, including whatever coffee-shop
      wifi it joins next.
    */
    host: process.env.VARNICK_HOST ?? 'localhost',
    port: 1420,
    strictPort: true,
    /*
      Vite rejects requests whose Host header it does not recognise, which is a
      DNS-rebinding protection worth keeping. A leading dot allows the subdomains
      of one suffix, so MagicDNS names resolve without opening it up generally.
    */
    allowedHosts: ['.ts.net'],
  },
})
