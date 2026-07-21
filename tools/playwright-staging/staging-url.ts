/**
 * Pure staging URL validation for EventSales Playwright harness.
 * Never logs or returns secret values.
 */

export function normalizeAndValidateBaseUrl(raw: string): string {
  let normalized = raw.trim();
  if (!normalized.endsWith("/")) {
    normalized = `${normalized}/`;
  }

  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    throw new Error("STAGING_BASE_URL is not a valid URL");
  }

  if (parsed.protocol !== "https:") {
    throw new Error("STAGING_BASE_URL must use HTTPS");
  }

  if (parsed.username || parsed.password) {
    throw new Error("STAGING_BASE_URL must not contain credentials");
  }

  if (parsed.search || parsed.hash) {
    throw new Error(
      "STAGING_BASE_URL must not contain query parameters or fragments",
    );
  }

  const hostname = parsed.hostname.toLowerCase();
  const productionHostnames = new Set([
    "voelgoed.co.za",
    "www.voelgoed.co.za",
    "eventsales.voelgoed.co.za",
  ]);

  if (
    productionHostnames.has(hostname) ||
    hostname === "voelgoed.co.za" ||
    hostname.endsWith(".voelgoed.co.za")
  ) {
    throw new Error(
      "STAGING_BASE_URL must not target production domains (including voelgoed.co.za)",
    );
  }

  if (!hostname.endsWith(".wpstage.net")) {
    throw new Error("STAGING_BASE_URL hostname must end with .wpstage.net");
  }

  return normalized;
}
