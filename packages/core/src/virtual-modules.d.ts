/**
 * Modules with no file behind them, declared so `tsc` can see what the bundler
 * will produce. The plugins that answer for these are in `vite.config.ts`.
 */

declare module 'virtual:varnick-version' {
  /** The root manifest's version, read when the renderer was served or built. */
  export const VARNICK_VERSION: string
}
