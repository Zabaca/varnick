import { cloudflareModule } from '../../modules/cloudflare'

// varnick.com's page, deployed from this repo's `site/`.
//
// `site/` is one Worker with no assets and no build step, so this instance has no
// `build`. The Worker's shape (name, compatibility date, routes, workers.dev off)
// lives in `site/wrangler.jsonc`, where the `cloudflare` module expects topology;
// this file supplies the account and the workdir, and the token comes from
// `secrets.yaml`.
//
// The routes are plain routes, not a wrangler `custom_domain`: a custom domain has
// wrangler create and own a DNS record, and the zone's existing proxied record is
// the one that serves the hostname. So this instance never touches DNS.
//
// No `workerVars` and no `workerSecrets`: the page is a constant and the Worker
// reads no configuration.
export default cloudflareModule.instance({
  name: 'varnick-site',
  config: {
    workdir: '../site',
    accountId: '99a19e584439be0568f33aad0477372b',
  },
})
