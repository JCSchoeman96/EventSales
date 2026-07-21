# Playwright staging access

Isolated Playwright setup for verifying HTTPS staging access through HTTP Basic Authentication, WordPress admin session storage, and read-only admin smoke checks.

## Prerequisites

- Repository-root `.env` at `../../.env` (never commit this file)
- Required keys for Basic Auth access:
  - `STAGING_BASE_URL` (HTTPS, hostname ending in `.wpstage.net`)
  - `STAGING_HTTP_USERNAME`
  - `STAGING_HTTP_PASSWORD`
- Additional keys for WordPress admin auth state:
  - `STAGING_WP_ADMIN_USERNAME`
  - `STAGING_WP_ADMIN_PASSWORD`

Copy placeholders from `.env.example` into the **repository-root** `.env` only. Do not create a local `.env` in this directory.

## Install

```bash
cd tools/playwright-staging
npm ci
npx playwright install chromium
```

## Run

```bash
npm run test:unit
npm run test:access
npm run test:access:headed
npm run test:auth
npm run test:session
npm run test:session:headed
npm run test:admin-readonly
npm run test:admin-readonly:headed
npm run report
```

Projects:

- `unit` — production/staging URL validation (`tests/staging-url.spec.ts`)
- `access` — Basic Auth reachability (`tests/basic-auth.spec.ts`)
- `setup` — create `playwright/.auth/wp-admin.json` (`tests/auth.setup.ts`)
- `admin` — authenticated session + read-only smoke (`tests/authenticated-session.spec.ts`, `tests/wp-admin-readonly.spec.ts`)

## Safety

- Loads only the repository-root `.env`
- Scopes Basic Auth credentials to the staging origin
- Rejects non-HTTPS URLs, production hostnames, embedded URL credentials, and query/fragment values
- Stores WordPress auth state under `playwright/.auth/` with mode `600` (gitignored)
- Read-only admin smoke never clicks Save/Update/Publish/Trash/Activate/Run/etc.
- First-party console errors fail the smoke suite; third-party analytics/font noise stays informational
- Action Scheduler checks use read-only status+search filters for `eventsales-catalog-change`
- Live staging projects disable traces, screenshots, and videos because those artifacts can capture HTTP Basic Auth headers, WordPress credentials, authenticated cookies, or protected admin content
- List and HTML reporters remain enabled; annotations and failure text stay pathname-sanitized
- Artifact directories (`test-results/`, `playwright-report/`, `playwright/.auth/`) remain gitignored
- Does not use SFTP or deploy plugins
- Does not log credentials, headers, cookies, nonces, query values, or storage-state contents
