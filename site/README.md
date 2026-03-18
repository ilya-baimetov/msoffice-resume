# Office Resume Site Assets

This directory contains the static marketing site assets for Office Resume.

The site is deployed as part of the unified `office-resume` Cloudflare Worker:
- static assets from `site/`
- backend/API routes from `OfficeResumeBackend/`
- Worker entrypoint at `/Users/ilya.baimetov/Projects/msoffice-resume/worker.js`

## Routing Model

The shared Worker serves:
- site assets and HTML at `/`
- backend auth, billing, and entitlement routes at `/api/*`

The Worker script runs first only for `/api` and `/api/*`, forwards those requests into the backend handler, and serves all other requests from the `ASSETS` binding.

## Local Deploy

Deploy from the repository root:

```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume
npx wrangler login
npx wrangler deploy
```

## CI Validation

GitHub Actions does not deploy the Worker, but the repo keeps a dry-run validation:

```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume
npx wrangler deploy --dry-run
```

Deployment is owned by Cloudflare, not GitHub.

## Local Preview

Preview the unified Worker locally from the repository root:

```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume
npx wrangler dev
```

## Cloudflare-Native Auto Deploy

Use **Workers Builds** against this repository:

1. Go to `Workers & Pages` in the Cloudflare dashboard.
2. Create or connect the Worker named `office-resume`.
3. Choose `Import a repository`.
4. Select this repository.
5. Set the project root directory to the repository root.
6. Make sure the Worker name in Cloudflare matches the `name` in `/Users/ilya.baimetov/Projects/msoffice-resume/wrangler.jsonc`.
7. Save and deploy.

## Custom Domain

After the first deployment:

1. Open the Worker in Cloudflare.
2. Attach `officeresume.com` or the desired custom domain.
3. If the domain already uses Cloudflare DNS, Cloudflare can create the DNS record automatically.

## Notes

- `site/` stays static HTML/CSS only.
- No Node build step is required for the site assets.
- The backend and site share the same Worker name and deployment.
