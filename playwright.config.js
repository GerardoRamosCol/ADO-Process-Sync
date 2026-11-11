const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests",
  testMatch: "process-sync.browser.spec.js",
  fullyParallel: false,
  use: { baseURL: "http://127.0.0.1:8895", channel: process.env.PLAYWRIGHT_CHANNEL, screenshot: "only-on-failure", trace: "retain-on-failure" },
  webServer: {
    command: "pwsh -NoLogo -NoProfile -File scripts/Start-AdoProcessSyncApp.ps1 -NoBrowser -Port 8895",
    url: "http://127.0.0.1:8895/",
    reuseExistingServer: false,
    timeout: 30000,
  },
});