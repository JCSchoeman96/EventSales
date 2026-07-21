import { expect, test } from "@playwright/test";
import { normalizeAndValidateBaseUrl } from "../staging-url";

test.describe("staging URL validation", () => {
  test("accepts HTTPS .wpstage.net URLs and normalizes trailing slash", () => {
    expect(
      normalizeAndValidateBaseUrl("https://example.e.wpstage.net/w"),
    ).toBe("https://example.e.wpstage.net/w/");
    expect(
      normalizeAndValidateBaseUrl("https://example.e.wpstage.net/"),
    ).toBe("https://example.e.wpstage.net/");
  });

  test("rejects non-HTTPS URLs", () => {
    expect(() =>
      normalizeAndValidateBaseUrl("http://example.e.wpstage.net/"),
    ).toThrow(/HTTPS/);
  });

  test("rejects production hostnames", () => {
    const productionUrls = [
      "https://voelgoed.co.za/",
      "https://www.voelgoed.co.za/",
      "https://eventsales.voelgoed.co.za/",
      "https://shop.voelgoed.co.za/",
    ];

    for (const url of productionUrls) {
      expect(() => normalizeAndValidateBaseUrl(url), url).toThrow(
        /production domains/,
      );
    }
  });

  test("rejects hostnames that are not .wpstage.net", () => {
    expect(() =>
      normalizeAndValidateBaseUrl("https://example.com/"),
    ).toThrow(/wpstage\.net/);
  });

  test("rejects embedded URL credentials without echoing them", () => {
    const withUserInfo = [
      "https://user:secret@example.e.wpstage.net/w/",
      "https://onlyuser@example.e.wpstage.net/w/",
    ];

    for (const url of withUserInfo) {
      try {
        normalizeAndValidateBaseUrl(url);
        throw new Error("expected rejection");
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        expect(message).toMatch(/must not contain credentials/);
        expect(message).not.toMatch(/user:secret|onlyuser|secret/i);
        expect(message).not.toContain("@");
      }
    }
  });

  test("rejects query strings and fragments", () => {
    expect(() =>
      normalizeAndValidateBaseUrl(
        "https://example.e.wpstage.net/w/?utm=1",
      ),
    ).toThrow(/query parameters or fragments/);

    expect(() =>
      normalizeAndValidateBaseUrl("https://example.e.wpstage.net/w/#section"),
    ).toThrow(/query parameters or fragments/);
  });

  test("error messages never include credential-like values", () => {
    try {
      normalizeAndValidateBaseUrl("https://voelgoed.co.za/");
      throw new Error("expected rejection");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      expect(message).not.toMatch(/password|authorization|cookie|nonce|Bearer/i);
      expect(message).toMatch(/production domains/);
    }
  });
});
