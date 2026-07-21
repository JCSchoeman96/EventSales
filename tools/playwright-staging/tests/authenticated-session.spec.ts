import { expect, test } from "@playwright/test";

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

  return cloudflareError || gatewayError || phpOrWpError;
}

async function assertAuthenticatedAdmin(
  page: import("@playwright/test").Page,
  baseURL: string,
): Promise<{ pathname: string; status: number; markerVisible: boolean }> {
  const stagingOrigin = new URL(baseURL).origin;
  let firstParty5xx = 0;

  const onResponse = (response: import("@playwright/test").Response) => {
    try {
      const responseUrl = new URL(response.url());
      if (responseUrl.origin === stagingOrigin && response.status() >= 500) {
        firstParty5xx += 1;
      }
    } catch {
      // Ignore unparseable URLs.
    }
  };
  page.on("response", onResponse);

  try {
    const adminUrl = new URL("wp-admin/", baseURL).toString();
    const response = await page.goto(adminUrl, { waitUntil: "commit" });
    expect(response, "wp-admin response must exist").not.toBeNull();
    const status = response!.status();
    expect(status, "wp-admin must be below 500").toBeLessThan(500);

    await page.locator("body").waitFor({ state: "attached" });

    const finalUrl = new URL(page.url());
    expect(finalUrl.origin, "must remain on staging origin").toBe(stagingOrigin);
    expect(
      finalUrl.pathname.includes("/teken-aan"),
      "must not redirect to login",
    ).toBe(false);

    const adminBar = page.locator("#wpadminbar");
    const adminMenu = page.locator("#adminmenu");
    await expect
      .poll(
        async () =>
          (await adminBar.isVisible().catch(() => false)) ||
          (await adminMenu.isVisible().catch(() => false)),
        { timeout: 20_000 },
      )
      .toBe(true);

    const body = await page.content();
    expect(
      looksLikeErrorSurface(body),
      "must not show PHP/WordPress/Cloudflare 5xx surfaces",
    ).toBe(false);
    expect(firstParty5xx, "first-party 5xx count").toBe(0);

    const markerVisible =
      (await adminBar.isVisible().catch(() => false)) ||
      (await adminMenu.isVisible().catch(() => false));

    return {
      pathname: finalUrl.pathname,
      status,
      markerVisible,
    };
  } finally {
    page.off("response", onResponse);
  }
}

test.describe("authenticated WordPress admin session", () => {
  test("restores wp-admin session and survives refresh", async ({
    page,
    baseURL,
  }) => {
    expect(baseURL, "Playwright baseURL must be configured").toBeTruthy();

    const first = await assertAuthenticatedAdmin(page, baseURL!);
    expect(first.markerVisible).toBe(true);

    await page.reload({ waitUntil: "commit" });
    await page.locator("body").waitFor({ state: "attached" });

    const stagingOrigin = new URL(baseURL!).origin;
    const afterReload = new URL(page.url());
    expect(afterReload.origin).toBe(stagingOrigin);
    expect(afterReload.pathname.includes("/teken-aan")).toBe(false);

    const adminBar = page.locator("#wpadminbar");
    const adminMenu = page.locator("#adminmenu");
    await expect
      .poll(
        async () =>
          (await adminBar.isVisible().catch(() => false)) ||
          (await adminMenu.isVisible().catch(() => false)),
        { timeout: 20_000 },
      )
      .toBe(true);

    const body = await page.content();
    expect(looksLikeErrorSurface(body)).toBe(false);

    test.info().annotations.push({
      type: "final_pathname",
      description: afterReload.pathname,
    });
    test.info().annotations.push({
      type: "http_status",
      description: String(first.status),
    });
    test.info().annotations.push({
      type: "admin_marker_visible",
      description: "true",
    });
  });
});
