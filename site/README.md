# Office Resume Site Deployment

This directory contains the static marketing site for Office Resume.

## Recommended Cloudflare Setup

Use **Cloudflare Workers Static Assets**.

Cloudflare currently recommends Workers Static Assets for new static sites and full-stack apps, rather than Pages-first setups.

This site is static HTML/CSS only, so it does not need a Worker script. The `wrangler.jsonc` file configures an assets-only Worker.

## Local Deploy

Deploy directly from your machine:

```bash
cd site
npx wrangler login
npx wrangler deploy
```

Because `site/wrangler.jsonc` points `assets.directory` at the current directory, Wrangler will upload the static files in `site/` as a Worker deployment.

After deploy, Cloudflare will give you a `workers.dev` URL unless you attach a custom domain or route.

## GitHub Auto Deploy

This repo can deploy the site automatically from GitHub Actions.

Default solo flow:

1. Work locally.
2. Let local hooks and local review catch issues before push.
3. Push to `main`.
4. GitHub Actions deploys the Worker automatically if `site/` changed.

Required GitHub repository secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Cloudflare's GitHub Actions documentation requires those two values because `wrangler login` is interactive and cannot run inside CI.

If you want review to block deployment, protect `main` and require pull requests. Otherwise, the default solo path is direct push to `main` after local checks pass.

## Local Preview

Preview locally with Wrangler:

```bash
cd site
npx wrangler dev
```

## Optional Cloudflare-Native Auto Deploy

If you prefer Cloudflare-managed Git deploys instead of GitHub Actions, use **Workers Builds**:

1. Go to `Workers & Pages` in the Cloudflare dashboard.
2. Create a new `Worker`.
3. Choose `Import a repository`.
4. Select this repository.
5. Set the project root directory to `site`.
6. Make sure the Worker name in Cloudflare matches the `name` in `site/wrangler.jsonc`.
7. Save and deploy.

## Custom Domain

After the first deployment:

1. Open the Worker in Cloudflare.
2. Add a custom domain or route.
3. If the domain already uses Cloudflare DNS, Cloudflare can create the DNS record automatically.

## Notes

- `site/` is static HTML/CSS only.
- No Node build step is required.
- No `main` script is needed for this Worker because static assets are sufficient.
