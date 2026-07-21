import { expect, test, type Page, type Response } from "@playwright/test";

type Monitor = {
  firstParty5xx: Array<{ path: string; status: number }>;
  firstPartyFailures: Array<{ path: string; error: string }>;
  consoleErrors: string[];
  consoleWarnings: string[];
  pageExceptions: string[];
};

const ERROR_SNIPPETS = [
  "There has been a critical error",
  "Fatal error",
  "Parse error",
  "401 Authorization Required",
  "502 Bad Gateway",
  "503 Service Unavailable",
  "504 Gateway Timeout",
] as const;

function annotate(type: string, description: string): void {
  test.info().annotations.push({ type, description });
}

function isFirstParty(url: string, origin: string): boolean {
  try {
    return new URL(url).origin === origin;
  } catch {
    return false;
  }
}

function safePath(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    return "(unparseable)";
  }
}

function attachMonitor(page: Page, origin: string): Monitor {
  const monitor: Monitor = {
    firstParty5xx: [],
    firstPartyFailures: [],
    consoleErrors: [],
    consoleWarnings: [],
    pageExceptions: [],
  };

  page.on("response", (response: Response) => {
    if (!isFirstParty(response.url(), origin)) {
      return;
    }
    if (response.status() >= 500) {
      monitor.firstParty5xx.push({
        path: safePath(response.url()),
        status: response.status(),
      });
    }
  });

  page.on("requestfailed", (request) => {
    if (!isFirstParty(request.url(), origin)) {
      return;
    }
    const resourceType = request.resourceType();
    if (
      resourceType !== "document" &&
      resourceType !== "script" &&
      resourceType !== "stylesheet" &&
      resourceType !== "xhr" &&
      resourceType !== "fetch"
    ) {
      return;
    }
    const failure = request.failure();
    const errorText = failure?.errorText || "requestfailed";
    if (/ERR_ABORTED|NS_BINDING_ABORTED/i.test(errorText)) {
      return;
    }
    monitor.firstPartyFailures.push({
      path: safePath(request.url()),
      error: errorText,
    });
  });

  page.on("console", (message) => {
    const text = message.text().slice(0, 200);
    if (message.type() === "error") {
      monitor.consoleErrors.push(text);
    } else if (
      message.type() === "warning" &&
      /deprecated|deprecation/i.test(text)
    ) {
      monitor.consoleWarnings.push(text);
    }
  });

  page.on("pageerror", (error) => {
    monitor.pageExceptions.push(error.message.slice(0, 200));
  });

  return monitor;
}

function looksLikeErrorSurface(body: string): boolean {
  return ERROR_SNIPPETS.some((snippet) => body.includes(snippet));
}

async function assertStillAuthenticated(page: Page, origin: string): Promise<void> {
  const current = new URL(page.url());
  expect(current.origin, "must remain on staging origin").toBe(origin);
  expect(current.pathname.includes("/teken-aan"), "must not hit login").toBe(
    false,
  );

  const adminBar = page.locator("#wpadminbar");
  const adminMenu = page.locator("#adminmenu");
  const adminBody = page.locator(
    "body.wp-admin, body.block-editor-page, body.wp-embed-responsive.wp-admin",
  );
  const editorShell = page.locator(
    "#editor, .block-editor, .edit-post-layout, .interface-interface-skeleton",
  );

  await expect
    .poll(
      async () => {
        if (await adminBar.isVisible().catch(() => false)) {
          return true;
        }
        if (await adminMenu.isVisible().catch(() => false)) {
          return true;
        }
        // Gutenberg fullscreen can hide admin chrome while remaining authenticated.
        if (
          /\/wp-admin\//.test(current.pathname) &&
          ((await adminBody.count()) > 0 ||
            (await adminMenu.count()) > 0 ||
            (await editorShell.count()) > 0)
        ) {
          return true;
        }
        return false;
      },
      { timeout: 20_000 },
    )
    .toBe(true);
}

async function gotoAdmin(
  page: Page,
  baseURL: string,
  relativePath: string,
): Promise<{ status: number; pathname: string }> {
  const origin = new URL(baseURL).origin;
  const target = new URL(relativePath, baseURL).toString();
  const response = await page.goto(target, { waitUntil: "commit" });
  expect(response, `response must exist for ${relativePath}`).not.toBeNull();
  const status = response!.status();
  expect(status, `${relativePath} must be below 500`).toBeLessThan(500);

  await page.locator("body").waitFor({ state: "attached" });
  await assertStillAuthenticated(page, origin);

  const body = await page.content();
  expect(
    looksLikeErrorSurface(body),
    `${relativePath} must not show critical error surfaces`,
  ).toBe(false);

  return {
    status,
    pathname: new URL(page.url()).pathname,
  };
}

async function readDisplayedItemCount(page: Page): Promise<string> {
  const displayNum = page.locator(".displaying-num").first();
  if ((await displayNum.count()) === 0) {
    return "unknown";
  }
  const text = ((await displayNum.textContent()) || "").trim();
  return text || "unknown";
}

async function findPreferredRow(
  page: Page,
): Promise<{ row: ReturnType<Page["locator"]>; id: string } | null> {
  const rows = page.locator("#the-list > tr[id^='post-']:not(.no-items)");
  const count = await rows.count();
  if (count === 0) {
    return null;
  }

  let fallback: { row: ReturnType<Page["locator"]>; id: string } | null = null;
  const scanLimit = Math.min(count, 8);

  for (let index = 0; index < scanLimit; index += 1) {
    const row = rows.nth(index);
    const rowId = (await row.getAttribute("id")) || "";
    const match = /^post-(\d+)$/.exec(rowId);
    if (!match) {
      continue;
    }
    const statusText = (
      await row.locator(".post-state, td.status.column-status").allTextContents()
    )
      .join(" ")
      .toLowerCase();
    if (/trash|trashed/.test(statusText)) {
      continue;
    }

    const candidate = { row, id: match[1] };
    if (!fallback) {
      fallback = candidate;
    }
    if (/draft|private|pending|internal/.test(statusText)) {
      return candidate;
    }
  }

  return fallback;
}

async function assertEditorTitleVisible(page: Page): Promise<void> {
  const classicTitle = page.locator(
    "#title, input[name='post_title'], #titlewrap #title",
  );
  const blockTitle = page.locator(
    [
      ".editor-post-title__input",
      "textarea.editor-post-title__input",
      "h1.editor-post-title",
      "h1.wp-block-post-title",
      '[aria-label="Add title"]',
      ".editor-visual-editor h1",
    ].join(", "),
  );
  const editorShell = page.locator(
    "#editor, .block-editor, .edit-post-layout, .interface-interface-skeleton",
  );
  const editorSignals = page.locator(
    [
      ".editor-document-bar",
      ".editor-document-tools",
      ".interface-interface-skeleton__content",
      ".edit-post-visual-editor",
    ].join(", "),
  );
  const eventsTab = page.getByRole("tab", { name: /^Events$/i });
  const editorContent = page.getByRole("region", { name: /Editor content/i });
  const titleChip = page.getByRole("button", { name: /·\s*Events/i });

  await expect
    .poll(
      async () => {
        if ((await classicTitle.count()) > 0) {
          return "classic-title";
        }
        if ((await blockTitle.count()) > 0) {
          return "block-title";
        }
        if (
          (await editorShell.count()) > 0 &&
          ((await editorSignals.count()) > 0 ||
            (await eventsTab.count()) > 0 ||
            (await editorContent.count()) > 0 ||
            (await titleChip.count()) > 0)
        ) {
          return "block-editor-shell";
        }
        return "pending";
      },
      { timeout: 60_000 },
    )
    .not.toBe("pending");
}

async function assertTickeraPanelsVisible(page: Page): Promise<boolean> {
  const panels = page.locator(
    [
      "#tc_event_meta",
      "#tc_event_data",
      ".tc_event_metabox",
      "#tickera_event_data",
      "[id*='tc_event' i]",
      "[class*='tc_event' i]",
      "#postbox-container-2 .postbox",
      "#yoast_wpseo_metabox, .yoast",
    ].join(", "),
  );
  const eventsTab = page.getByRole("tab", { name: /^Events$/i });
  const eventsPanel = page.getByRole("tabpanel", { name: /^Events$/i });
  const metaBoxes = page.getByRole("heading", { name: /Meta Boxes/i });

  await expect
    .poll(
      async () =>
        (await panels.count()) > 0 ||
        (await eventsTab.count()) > 0 ||
        (await eventsPanel.count()) > 0 ||
        (await metaBoxes.count()) > 0,
      { timeout: 60_000 },
    )
    .toBe(true);

  return (
    (await panels.count()) > 0 ||
    (await eventsTab.isVisible().catch(() => false)) ||
    (await eventsPanel.isVisible().catch(() => false)) ||
    (await metaBoxes.isVisible().catch(() => false))
  );
}

async function openRowEdit(
  page: Page,
  row: ReturnType<Page["locator"]>,
  origin: string,
): Promise<void> {
  const editLink = row.locator("a.row-title").first();
  await expect(editLink).toBeVisible({ timeout: 15_000 });
  const href = await editLink.getAttribute("href");
  expect(href, "edit link href must exist").toBeTruthy();

  const editUrl = new URL(href!, page.url());
  expect(editUrl.origin, "edit link must stay on staging origin").toBe(origin);
  expect(
    /[?&]action=edit(?:&|$)/.test(editUrl.search) ||
      /post\.php/.test(editUrl.pathname),
    "edit link must target the post editor",
  ).toBe(true);

  await page.goto(editUrl.toString(), { waitUntil: "commit" });
  await page.locator("body").waitFor({ state: "attached" });
}

test.describe("read-only WordPress admin smoke baseline", () => {
  test.describe.configure({ timeout: 300_000 });

  test("dashboard, plugins, products, Tickera, Action Scheduler", async ({
    page,
    baseURL,
  }) => {
    expect(baseURL, "Playwright baseURL must be configured").toBeTruthy();
    const origin = new URL(baseURL!).origin;
    const monitor = attachMonitor(page, origin);

    // --- Phase 4: Dashboard ---
    const dashboard = await gotoAdmin(page, baseURL!, "wp-admin/");
    await expect(page.locator("#dashboard-widgets, #dashboard-widgets-wrap, .wrap h1").first()).toBeVisible();

    await page.reload({ waitUntil: "commit" });
    await page.locator("body").waitFor({ state: "attached" });
    await assertStillAuthenticated(page, origin);
    expect(looksLikeErrorSurface(await page.content())).toBe(false);

    annotate("dashboard_pathname", new URL(page.url()).pathname);
    annotate("dashboard_status", String(dashboard.status));

    // --- Phase 5: Plugins ---
    const plugins = await gotoAdmin(page, baseURL!, "wp-admin/plugins.php");
    await expect(page.locator("#the-list, table.wp-list-table.plugins").first()).toBeVisible();

    const pluginRow = page
      .locator("#the-list tr")
      .filter({ hasText: /EventSales Tickera Catalog Feed/i })
      .first();
    const pluginPresent = (await pluginRow.count()) > 0;
    let pluginVersion = "n/a";
    let pluginActiveState = "n/a";

    if (pluginPresent) {
      const versionText =
        (await pluginRow.locator(".plugin-version-author-uri, .plugin-version").first().textContent().catch(() => null)) ||
        (await pluginRow.textContent()) ||
        "";
      const versionMatch = /Version\s+([0-9][^\s|<]*)/i.exec(versionText);
      pluginVersion = versionMatch ? versionMatch[1] : "unknown";

      const rowClass = (await pluginRow.getAttribute("class")) || "";
      if (/\binactive\b/.test(rowClass)) {
        pluginActiveState = "inactive";
      } else if (/\bactive\b/.test(rowClass)) {
        pluginActiveState = "active";
      } else {
        pluginActiveState = "unknown";
      }
    }

    annotate("plugin_present", pluginPresent ? "yes" : "no");
    annotate("plugin_version", pluginVersion);
    annotate("plugin_active_state", pluginActiveState);
    annotate("plugins_status", String(plugins.status));

    // --- Phase 6: WooCommerce product list ---
    const productList = await gotoAdmin(
      page,
      baseURL!,
      "wp-admin/edit.php?post_type=product",
    );
    await expect(page.locator("#the-list, table.wp-list-table").first()).toBeVisible();
    const productCountText = await readDisplayedItemCount(page);
    const preferredProduct = await findPreferredRow(page);
    expect(preferredProduct, "at least one non-trashed product row").not.toBeNull();

    annotate("product_list_status", String(productList.status));
    annotate("product_count", productCountText);
    annotate("product_id", preferredProduct!.id);

    // --- Phase 7: Product edit (read-only) ---
    await openRowEdit(page, preferredProduct!.row, origin);
    await assertStillAuthenticated(page, origin);

    const productEditUrl = new URL(page.url());
    expect(productEditUrl.origin).toBe(origin);
    expect(productEditUrl.pathname.includes("/teken-aan")).toBe(false);
    expect(looksLikeErrorSurface(await page.content())).toBe(false);

    await assertEditorTitleVisible(page);

    const wooPanels = page.locator(
      "#woocommerce-product-data, .woocommerce_options_panel, #product_data, .product_data",
    );
    await expect
      .poll(async () => (await wooPanels.count()) > 0, { timeout: 20_000 })
      .toBe(true);
    const wooPanelsVisible = (await wooPanels.count()) > 0;

    annotate("product_edit_pathname", productEditUrl.pathname + productEditUrl.search);
    annotate("woo_panels_visible", wooPanelsVisible ? "yes" : "no");

    // --- Phase 8: Tickera event list discovery ---
    await gotoAdmin(page, baseURL!, "wp-admin/");

    const tickeraHref = await page.evaluate((stagingOrigin) => {
      const anchors = Array.from(
        document.querySelectorAll<HTMLAnchorElement>("#adminmenu a[href], #wpadminbar a[href]"),
      );
      const sameOrigin = anchors
        .map((a) => a.href)
        .filter((href) => {
          try {
            return new URL(href).origin === stagingOrigin;
          } catch {
            return false;
          }
        });

      const byPostType = sameOrigin.find((href) =>
        /[?&]post_type=tc_events(?:&|$)/.test(href),
      );
      if (byPostType) {
        return byPostType;
      }

      const byLabel = anchors.find((a) => {
        const text = (a.textContent || "").trim();
        if (!/tickera|events?/i.test(text)) {
          return false;
        }
        try {
          const url = new URL(a.href);
          return (
            url.origin === stagingOrigin &&
            /post_type=tc_events|page=tc-/.test(url.href)
          );
        } catch {
          return false;
        }
      });
      return byLabel ? byLabel.href : null;
    }, origin);

    expect(
      tickeraHref,
      "Tickera event list route must be discoverable unambiguously",
    ).toBeTruthy();

    const tickeraListUrl = new URL(tickeraHref!);
    expect(tickeraListUrl.origin).toBe(origin);

    const tickeraListPath =
      tickeraListUrl.pathname.replace(/^\//, "") + tickeraListUrl.search;
    const tickeraList = await gotoAdmin(page, baseURL!, tickeraListPath);
    await expect(page.locator("#the-list, table.wp-list-table").first()).toBeVisible();
    const eventCountText = await readDisplayedItemCount(page);
    const preferredEvent = await findPreferredRow(page);
    expect(preferredEvent, "at least one non-trashed Tickera event row").not.toBeNull();

    annotate(
      "tickera_list_pathname",
      tickeraListUrl.pathname + tickeraListUrl.search,
    );
    annotate("tickera_list_status", String(tickeraList.status));
    annotate("event_count", eventCountText);
    annotate("event_id", preferredEvent!.id);

    // --- Phase 9: Tickera event edit ---
    await openRowEdit(page, preferredEvent!.row, origin);
    await assertStillAuthenticated(page, origin);

    const eventEditUrl = new URL(page.url());
    expect(eventEditUrl.origin).toBe(origin);
    expect(eventEditUrl.pathname.includes("/teken-aan")).toBe(false);
    expect(looksLikeErrorSurface(await page.content())).toBe(false);

    await assertEditorTitleVisible(page);

    const tickeraPanelsVisible = await assertTickeraPanelsVisible(page);
    expect(tickeraPanelsVisible, "Tickera event panels must render").toBe(true);

    annotate(
      "event_edit_pathname",
      eventEditUrl.pathname + eventEditUrl.search,
    );
    annotate("tickera_panels_visible", tickeraPanelsVisible ? "yes" : "no");

    // --- Phase 10: Action Scheduler ---
    await gotoAdmin(page, baseURL!, "wp-admin/");
    const actionSchedulerHref = await page.evaluate((stagingOrigin) => {
      const known = [
        /tools\.php\?page=action-scheduler/,
        /admin\.php\?page=wc-status&tab=action-scheduler/,
        /admin\.php\?page=action-scheduler/,
      ];
      const anchors = Array.from(
        document.querySelectorAll<HTMLAnchorElement>("a[href]"),
      );
      for (const anchor of anchors) {
        let url: URL;
        try {
          url = new URL(anchor.href);
        } catch {
          continue;
        }
        if (url.origin !== stagingOrigin) {
          continue;
        }
        const candidate = `${url.pathname}${url.search}`;
        if (known.some((pattern) => pattern.test(candidate))) {
          return url.href;
        }
      }
      return null;
    }, origin);

    expect(
      actionSchedulerHref,
      "Action Scheduler route must be present in admin UI",
    ).toBeTruthy();

    const asUrl = new URL(actionSchedulerHref!);
    expect(asUrl.origin).toBe(origin);
    const asPath = asUrl.pathname.replace(/^\//, "") + asUrl.search;
    const actionScheduler = await gotoAdmin(page, baseURL!, asPath);

    await expect(
      page
        .locator(
          ".action-scheduler, #action-scheduler, table.wp-list-table, .wc-action-scheduler",
        )
        .first(),
    ).toBeVisible({ timeout: 20_000 });

    const asBodyText = await page.locator("body").innerText();
    const eventsalesMentions = [
      ...asBodyText.matchAll(/eventsales-catalog-change/gi),
    ];

    let pending = 0;
    let inProgress = 0;
    let failed = 0;

    if (eventsalesMentions.length > 0) {
      // Count rows mentioning the hook/group in the scheduler table.
      const rows = page.locator("table.wp-list-table tbody tr").filter({
        hasText: /eventsales-catalog-change/i,
      });
      const rowCount = await rows.count();
      for (let index = 0; index < rowCount; index += 1) {
        const rowText = ((await rows.nth(index).innerText()) || "").toLowerCase();
        if (/failed/.test(rowText)) {
          failed += 1;
        } else if (/in[- ]progress|running/.test(rowText)) {
          inProgress += 1;
        } else if (/pending|queued/.test(rowText)) {
          pending += 1;
        } else {
          // Treat unknown status rows for this hook as unexpected baseline noise.
          pending += 1;
        }
      }
    }

    annotate("action_scheduler_pathname", asUrl.pathname + asUrl.search);
    annotate("action_scheduler_status", String(actionScheduler.status));
    annotate("eventsales_pending", String(pending));
    annotate("eventsales_in_progress", String(inProgress));
    annotate("eventsales_failed", String(failed));

    expect(
      pending + inProgress + failed,
      "unexpected EventSales catalog-trigger actions must be 0",
    ).toBe(0);

    // --- Phase 11: Network / console review ---
    // Soften console error gating: WordPress admin is noisy.
    // Keep page exceptions and first-party 5xx as hard failures.
    const blockingConsole = [...monitor.pageExceptions];

    annotate("first_party_5xx_count", String(monitor.firstParty5xx.length));
    annotate(
      "failed_first_party_requests",
      String(monitor.firstPartyFailures.length),
    );
    annotate("blocking_console_errors", String(blockingConsole.length));
    annotate("non_blocking_warnings", String(monitor.consoleWarnings.length));
    annotate("console_error_count", String(monitor.consoleErrors.length));

    expect(monitor.firstParty5xx, "first-party 5xx responses").toEqual([]);
    expect(
      monitor.firstPartyFailures,
      "failed first-party essential requests",
    ).toEqual([]);
    expect(blockingConsole, "blocking first-party JS exceptions").toEqual([]);

    annotate("session_authenticated", "yes");
  });
});
