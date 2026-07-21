import path from "node:path";
import { defineConfig, devices } from "@playwright/test";
import dotenv from "dotenv";
import { normalizeAndValidateBaseUrl } from "./staging-url";

dotenv.config({
  path: path.resolve(__dirname, "../../.env"),
  quiet: true,
});

function requireEnv(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const stagingBaseUrl = normalizeAndValidateBaseUrl(requireEnv("STAGING_BASE_URL"));
const httpUsername = requireEnv("STAGING_HTTP_USERNAME");
const httpPassword = requireEnv("STAGING_HTTP_PASSWORD");
const stagingOrigin = new URL(stagingBaseUrl).origin;
const authStatePath = path.join(__dirname, "playwright", ".auth", "wp-admin.json");

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  outputDir: "test-results/",
  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: "playwright-report/" }],
  ],
  use: {
    baseURL: stagingBaseUrl,
    headless: true,
    navigationTimeout: 30_000,
    ignoreHTTPSErrors: false,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    httpCredentials: {
      username: httpUsername,
      password: httpPassword,
      origin: stagingOrigin,
    },
  },
  projects: [
    {
      name: "unit",
      testMatch: /staging-url\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
      },
    },
    {
      name: "access",
      testMatch: /basic-auth\.spec\.ts/,
      timeout: 90_000,
      use: {
        ...devices["Desktop Chrome"],
      },
    },
    {
      name: "setup",
      testMatch: /auth\.setup\.ts/,
      timeout: 60_000,
      use: {
        ...devices["Desktop Chrome"],
      },
    },
    {
      name: "admin",
      testMatch: /(authenticated-session|wp-admin-readonly)\.spec\.ts/,
      timeout: 300_000,
      dependencies: ["setup"],
      use: {
        ...devices["Desktop Chrome"],
        storageState: authStatePath,
      },
    },
  ],
});
