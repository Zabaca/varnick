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
    port: 1420,
    strictPort: true,
  },
})
