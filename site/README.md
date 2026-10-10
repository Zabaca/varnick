# site

varnick.com: one Cloudflare Worker, `varnick-site`, that serves `src/page.html` as a single constant
document. This folder is the source of truth for the page. Its routes (`varnick.com/*` and
`www.varnick.com/*`) are plain routes in `wrangler.jsonc`, so the zone's DNS is not touched.

## Deploy

Deploys go through [zbc](https://github.com/Zabaca/zbc), set up in [`../deploy/`](../deploy/):

```sh
cd deploy
bun install
bunx @zabaca/zbc apply production varnick-site
```

`zbc` is Zabaca's infra CLI. The deploy token is in
`deploy/packages/infra/environments/production/secrets.yaml`, encrypted with sops to the maintainers' age keys,
so only they can apply. A Worker deploy replaces the live page at once; the previous version can be rolled
back with `wrangler rollback`.

`deploy/` holds a copy of zbc's engine and its `cloudflare` module (zbc's "copy mode"). It sits in its own
folder because zbc looks for `packages/infra/`, and on macOS that name is the same folder as the Swift
`Packages/`. `zbc update`, run in `deploy/`, refreshes the copy.

## Option: apply from CI

Nothing applies this automatically. Deploying on a push to `main` would need an age private key stored as a
repository secret on GitHub, with its public key added to `deploy/.sops.yaml` and the secrets re-encrypted
(`sops updatekeys`). That puts the power to deploy varnick.com in the repository's CI, so it is the
maintainers' decision, not something to add as part of a change.
