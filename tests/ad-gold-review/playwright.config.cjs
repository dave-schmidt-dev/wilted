// @ts-check
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

process.env._PW_CONFIG_LOADING = '1';
const { globalSetup } = require('./review.spec.cjs');
const fixtureRoot = globalSetup();
delete process.env._PW_CONFIG_LOADING;
delete require.cache[require.resolve('./review.spec.cjs')];

module.exports = defineConfig({
  testDir: '.',
  testMatch: /.*\.spec\.cjs/,
  timeout: 30000,
  globalTeardown: path.resolve(__dirname, 'review.spec.cjs'),
  use: {
    baseURL: 'http://127.0.0.1:8765',
    ...devices['Desktop Chrome'],
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: {
    command: `python3 ../../Producer/Workers/ad_gold_review.py --root "${fixtureRoot}" --port 8765`,
    url: 'http://127.0.0.1:8765/',
    reuseExistingServer: false,
    timeout: 10000,
  },
});
