// @ts-check
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const os = require('os');

let fixtureDir = null;

function createWavBuffer(durationSeconds = 20, sampleRate = 16000) {
  const numSamples = Math.floor(durationSeconds * sampleRate);
  const dataSize = numSamples * 2;
  const buffer = Buffer.alloc(44 + dataSize);

  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + dataSize, 4);
  buffer.write('WAVE', 8);

  buffer.write('fmt ', 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);

  buffer.write('data', 36);
  buffer.writeUInt32LE(dataSize, 40);
  return buffer;
}

function buildFixture(rootDir) {
  const showDir = path.join(rootDir, 'fixture-show');
  fs.mkdirSync(showDir, { recursive: true });

  fs.writeFileSync(
    path.join(showDir, 'episode.json'),
    JSON.stringify({
      show: 'Fixture Show',
      slug: 'fixture-show',
      title: 'Episode 101',
      episodeID: 'fx-101',
      audioFile: 'audio.wav',
      audioSha256: 'deadbeef',
      durationSeconds: 20.0,
      publishedAt: '2026-01-01T00:00:00Z',
    }),
    'utf-8'
  );

  fs.writeFileSync(path.join(showDir, 'audio.wav'), createWavBuffer(20, 16000));

  fs.writeFileSync(
    path.join(showDir, 'labels.opus.json'),
    JSON.stringify({
      pattern: 'sponsor at 5s',
      ranges: [
        {
          id: 'range-1',
          start_s: 5.0,
          end_s: 10.0,
          kind: 'sponsor',
          label: 'must-cut',
          confidence: 'low',
          sponsor: 'Acme Corp',
          note: 'Opus midroll detection',
        },
      ],
      gaps: [[10.0, 15.0]],
    }),
    'utf-8'
  );

  fs.writeFileSync(
    path.join(showDir, 'transcript.json'),
    JSON.stringify({
      model: 'whisper-large-v3',
      segments: [{ start_s: 0.0, end_s: 20.0, text: 'intro before sponsor start now outro' }],
      words: [
        [0.0, 1.0, 'intro'],
        [2.0, 3.0, 'before'],
        [4.0, 4.8, 'sponsor'],
        [4.8, 5.2, 'start'],
        [5.5, 6.0, 'now'],
        [9.5, 10.0, 'adend'],
        [15.0, 16.0, 'outro'],
      ],
    }),
    'utf-8'
  );
}

function globalSetup() {
  if (!fixtureDir) {
    fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ad-gold-root-'));
    buildFixture(fixtureDir);
  }
  return fixtureDir;
}

function globalTeardown() {
  if (fixtureDir && fs.existsSync(fixtureDir)) {
    fs.rmSync(fixtureDir, { recursive: true, force: true });
    fixtureDir = null;
  }
}

module.exports = globalTeardown;
module.exports.globalSetup = globalSetup;
module.exports.globalTeardown = globalTeardown;

if (!process.env._PW_CONFIG_LOADING) {
  test('ad gold review workflow', async ({ page }) => {
    await page.goto('/');

    const showItem = page.locator('[data-testid="show-fixture-show"]');
    await expect(showItem).toBeVisible();
    await expect(showItem).toContainText('Fixture Show');

    await showItem.click();
    await expect(page.locator('#show-name')).toContainText('Fixture Show');

    const rangeRow = page.locator('[data-testid="range-range-1"]');
    await expect(rangeRow).toBeVisible();

    // Confirm range with keyboard shortcut 'y'
    await rangeRow.click();
    await page.keyboard.press('y');
    await expect(rangeRow.locator('.badge', { hasText: 'confirmed' })).toBeVisible();
    await expect(page.locator('#save-status')).toHaveText('Saved');

    // Click start-edge word and observe start time change
    const startWord = rangeRow.locator('.edge-line').first().locator('.edge-word', { hasText: 'before' });
    await startWord.click();
    await expect(rangeRow.locator('.range-time')).toContainText('0:02');
    await expect(page.locator('#save-status')).toHaveText('Saved');

    // Add an owner range
    await page.locator('[data-testid="btn-add-ad"]').click();
    const ownerRange = page.locator('.range-row', { has: page.locator('[data-testid="delete"]') });
    await expect(ownerRange).toBeVisible();
    await expect(page.locator('#save-status')).toHaveText('Saved');

    // Reload and verify all three persisted
    await page.reload();
    await expect(page.locator('#show-name')).toContainText('Fixture Show');

    const reloadedR1 = page.locator('[data-testid="range-range-1"]');
    await expect(reloadedR1).toBeVisible();
    await expect(reloadedR1.locator('.badge', { hasText: 'confirmed' })).toBeVisible();
    await expect(reloadedR1.locator('.range-time')).toContainText('0:02');

    const reloadedOwner = page.locator('.range-row', { has: page.locator('[data-testid="delete"]') });
    await expect(reloadedOwner).toBeVisible();

    // Confirm rest of show sets badge to confirmed
    await page.locator('[data-testid="btn-confirm-rest"]').click();
    await expect(page.locator('#show-status-badge')).toHaveText('confirmed');
    await expect(page.locator('#save-status')).toHaveText('Saved');

    // An untranscribed stretch is listed and can become an owner range
    const gapRow = page.locator('[data-testid="gap-10"]');
    await expect(gapRow).toContainText('0:10 - 0:15');
    await gapRow.locator('[data-testid="gap-add"]').click();
    await expect(page.locator('.range-row .range-time', { hasText: '0:10 - 0:15' })).toBeVisible();

    // Move range-1's end to the playhead
    await page.waitForFunction(() => document.getElementById('audio-player').readyState >= 1);
    await page.evaluate(() => { document.getElementById('audio-player').currentTime = 12; });
    await page.locator('[data-testid="range-range-1"] [data-testid="end-here"]').click();
    await expect(page.locator('[data-testid="range-range-1"] .range-time')).toContainText('0:02 - 0:12');
    await expect(page.locator('#save-status')).toHaveText('Saved');
  });
}
