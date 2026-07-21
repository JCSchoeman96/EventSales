import { expect, test } from "@playwright/test";

function recordPathAndStatus(pathname: string, status: number): void {
  test.info().annotations.push({
    type: "staging_pathname",
    description: pathname,
  });
  test.info().annotations.push({
    type: "http_status",
    description: String(status),
  });
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
  const nginxError =
    /nginx/i.test(body) &&
    (/502/i.test(body) ||
      /503/i.test(body) ||
      /504/i.test(body) ||
      /internal server error/i.test(body));

  return cloudflareError || gatewayError || phpOrWpError || nginxError;
}

test.describe("staging HTTP Basic Auth access", () => {
  test("reaches staging root and wp-admin without 401 or 5xx", async ({
    page,
    baseURL,
  }) => {
    expect(baseURL, "Playwright baseURL must be configured").toBeTruthy();

    const configuredOrigin = new URL(baseURL!).origin;

    // Heavy WordPress frontends may not fire DOMContentLoaded quickly.
    // Commit is enough to assert the HTTP Basic Auth response.
    const rootResponse = await page.goto("./", {
      waitUntil: "commit",
    });

    expect(rootResponse, "root navigation response must exist").not.toBeNull();
    const rootStatus = rootResponse!.status();
    expect(rootStatus, "root must not return 401").not.toBe(401);
    expect(rootStatus, "root must be below 500").toBeLessThan(500);

    await page.locator("body").waitFor({ state: "attached" });
    const rootBody = await page.content();
    expect(rootBody).not.toContain("401 Authorization Required");
    expect(rootBody).not.toMatch(/nginx.*authorization required/i);
    expect(rootBody).not.toMatch(/authorization required/i);
    expect(
      looksLikeErrorSurface(rootBody),
      "root must not show Cloudflare/nginx/PHP/WordPress 5xx surfaces",
    ).toBe(false);

    const adminUrl = new URL("wp-admin/", baseURL!).toString();
    const adminResponse = await page.goto(adminUrl, {
      waitUntil: "commit",
    });

    expect(adminResponse, "wp-admin navigation response must exist").not.toBeNull();
    const adminStatus = adminResponse!.status();
    expect(adminStatus, "wp-admin must not return 401").not.toBe(401);
    expect(adminStatus, "wp-admin must be below 500").toBeLessThan(500);

    await page.locator("body").waitFor({ state: "attached" });

    // Staging may use classic wp-login.php or a themed login route
    // (e.g. /teken-aan/) while still remaining a WordPress login surface.
    const loginForm = page.locator(
      [
        "#loginform",
        "form#loginform",
        "input#user_login",
        "body.login",
        "form.woocommerce-form-login",
        'form input[type="password"]',
      ].join(", "),
    );
    const adminShell = page.locator("body.wp-admin, #wpadminbar, #wpbody");
    await expect
      .poll(
        async () => {
          const isLogin = (await loginForm.count()) > 0;
          const isAdmin = (await adminShell.count()) > 0;
          return isLogin || isAdmin;
        },
        { timeout: 15_000 },
      )
      .toBe(true);

    const finalUrl = new URL(page.url());
    expect(
      finalUrl.origin,
      "final URL must remain on the configured staging origin",
    ).toBe(configuredOrigin);

    recordPathAndStatus(finalUrl.pathname, adminStatus);

    const adminBody = await page.content();
    expect(adminBody).not.toContain("401 Authorization Required");
    expect(adminBody).not.toMatch(/nginx.*authorization required/i);
    expect(
      looksLikeErrorSurface(adminBody),
      "wp-admin must not show Cloudflare/nginx/PHP/WordPress 5xx surfaces",
    ).toBe(false);
  });
});
