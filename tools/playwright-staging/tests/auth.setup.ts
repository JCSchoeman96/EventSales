import fs from "node:fs";
import path from "node:path";
import { expect, test as setup } from "@playwright/test";

const AUTH_DIR = path.join(__dirname, "..", "playwright", ".auth");
const AUTH_FILE = path.join(AUTH_DIR, "wp-admin.json");

function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function looksLikeErrorSurface(body: string): boolean {
  const cloudflareError =
    /cloudflare/i.test(body) &&
    (/attention required/i.test(body) ||
      /error code/i.test(body) ||
      /cf-error/i.test(body));
  const gatewayError =
    /502 bad gateway/i.test(body) ||
    /503 service/i.test(body) ||
    /504 gateway/i.test(body) ||
    /internal server error/i.test(body);
  const phpOrWpError =
    /there has been a critical error on this website/i.test(body) ||
    /fatal error/i.test(body) ||
    /parse error/i.test(body);
  const nginxAuth =
    /401 Authorization Required/i.test(body) ||
    /nginx.*authorization required/i.test(body);

  return cloudflareError || gatewayError || phpOrWpError || nginxAuth;
}

function looksLikeChallenge(body: string): boolean {
  return (
    /cf-browser-verification/i.test(body) ||
    /challenge-platform/i.test(body) ||
    /iframe[^>]+recaptcha/i.test(body) ||
    /iframe[^>]+hcaptcha/i.test(body) ||
    /iframe[^>]+turnstile/i.test(body) ||
    /two-factor/i.test(body) ||
    /one-time password/i.test(body) ||
    /authentication code/i.test(body)
  );
}

setup("create WordPress admin storage state", async ({ page, baseURL }) => {
  const username = requireEnv("STAGING_WP_ADMIN_USERNAME");
  const password = requireEnv("STAGING_WP_ADMIN_PASSWORD");

  expect(baseURL, "Playwright baseURL must be configured").toBeTruthy();
  const stagingOrigin = new URL(baseURL!).origin;

  if (fs.existsSync(AUTH_FILE)) {
    fs.unlinkSync(AUTH_FILE);
  }
  fs.mkdirSync(AUTH_DIR, { recursive: true, mode: 0o700 });
  fs.chmodSync(AUTH_DIR, 0o700);

  let firstParty5xx = 0;
  page.on("response", (response) => {
    try {
      const responseUrl = new URL(response.url());
      if (responseUrl.origin === stagingOrigin && response.status() >= 500) {
        firstParty5xx += 1;
      }
    } catch {
      // Ignore unparseable URLs.
    }
  });

  const adminUrl = new URL("wp-admin/", baseURL!).toString();
  const loginResponse = await page.goto(adminUrl, { waitUntil: "commit" });
  expect(loginResponse, "wp-admin navigation response must exist").not.toBeNull();
  expect(loginResponse!.status(), "login page must be below 500").toBeLessThan(
    500,
  );

  await page.locator("body").waitFor({ state: "attached" });

  const loginUrl = new URL(page.url());
  expect(loginUrl.origin, "login must remain on staging origin").toBe(
    stagingOrigin,
  );
  expect(
    loginUrl.pathname.replace(/\/$/, ""),
    "expected themed login redirect",
  ).toBe("/teken-aan");

  const loginBody = await page.content();
  expect(
    looksLikeErrorSurface(loginBody),
    "login page must not show auth/5xx error surfaces",
  ).toBe(false);
  expect(
    looksLikeChallenge(loginBody),
    "login must not present CAPTCHA/MFA/Cloudflare challenge",
  ).toBe(false);

  // Prefer standard WordPress field names inside the wp-login form.
  // Fallback labels discovered on /teken-aan/: Gebruikersnaam / Wagwoord.
  const loginForm = page.locator('form[action*="wp-login.php"]');
  await expect(loginForm).toBeVisible({ timeout: 15_000 });

  const usernameInput = loginForm.locator('input[name="log"]');
  const passwordInput = loginForm.locator('input[name="pwd"]');
  const submitButton = loginForm.getByRole("button", { name: /teken aan/i });

  await expect(usernameInput).toBeVisible();
  await expect(passwordInput).toBeVisible();
  await expect(submitButton).toBeVisible();

  await usernameInput.fill(username);
  await passwordInput.fill(password);

  // Submit exactly once.
  await submitButton.click();

  const adminBar = page.locator("#wpadminbar");
  const adminMenu = page.locator("#adminmenu");
  const adminBody = page.locator("body.wp-admin, body.folded, body.auto-fold");

  await expect
    .poll(
      async () => {
        const current = new URL(page.url());
        if (current.origin !== stagingOrigin) {
          return "left-origin";
        }
        if (current.pathname.includes("/teken-aan")) {
          return "still-login";
        }

        const body = await page.content();
        if (looksLikeChallenge(body)) {
          return "challenge";
        }
        if (looksLikeErrorSurface(body)) {
          return "error-surface";
        }

        const pathOk = /\/wp-admin(\/|$)/.test(current.pathname);
        const markerVisible =
          (await adminBar.count()) > 0 ||
          (await adminMenu.count()) > 0 ||
          (await adminBody.count()) > 0;

        if (markerVisible) {
          return "authenticated";
        }
        if (pathOk) {
          return "pending";
        }

        if (/login_error|incorrect|ongeldig|verkeerd/i.test(body)) {
          return "rejected";
        }

        return "pending";
      },
      { timeout: 45_000 },
    )
    .toBe("authenticated");

  expect(firstParty5xx, "first-party 5xx count during login").toBe(0);

  const finalUrl = new URL(page.url());
  expect(finalUrl.origin, "final origin must remain staging").toBe(stagingOrigin);
  expect(finalUrl.pathname.includes("/teken-aan"), "must leave login page").toBe(
    false,
  );

  const markerVisible =
    (await adminBar.isVisible().catch(() => false)) ||
    (await adminMenu.isVisible().catch(() => false)) ||
    (await adminBody.count()) > 0;
  expect(markerVisible, "authenticated admin marker must be visible").toBe(
    true,
  );

  await page.context().storageState({ path: AUTH_FILE });
  fs.chmodSync(AUTH_FILE, 0o600);

  expect(fs.existsSync(AUTH_FILE), "auth state file must exist").toBe(true);
  const mode = fs.statSync(AUTH_FILE).mode & 0o777;
  expect(mode, "auth file permissions must be 600").toBe(0o600);
});
