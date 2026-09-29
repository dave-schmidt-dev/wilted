const { test, expect } = require('@playwright/test');
const path = require('path');

const file = `file://${path.resolve(__dirname, '2026-09-28-owner-feedback.html')}`;
const evidence = '.logs/subscription-workflow-2026-09-28/mockup-browser';

test.beforeEach(async ({ page }) => {
  await page.goto(file);
});

test('NAV-001 refresh preserves canonical source metadata and renders wide', async ({ page }) => {
  const sidebar = await page.locator('aside').boundingBox();
  const player = await page.locator('[data-compact-player]').boundingBox();
  expect(sidebar.width).toBeGreaterThanOrEqual(200);
  expect(sidebar.width).toBeLessThanOrEqual(240);
  expect(player.y + player.height).toBeLessThanOrEqual(720);
  await expect(page.locator('[data-sidebar-totals]')).toContainText('Needs preparation');
  await expect(page.locator('[data-episode="elm-001"]')).toContainText('Field Notes · Sep 28, 2026 · Source 42 min');
  await expect(page.locator('[data-episode="elm-001"]')).not.toContainText('Prepared playable');
  await page.screenshot({ path: `${evidence}/wide-feeds.png`, fullPage: true });
  await page.getByRole('button', { name: 'Refresh' }).click();
  await expect(page.getByText('Refreshing', { exact: true })).toBeVisible();
  await expect(page.locator('[data-feed-operation]')).toContainText('Refreshing feed metadata');
  await page.screenshot({ path: `${evidence}/wide-refresh-operation.png`, fullPage: true });
  expect(await page.locator('[data-feed-operation]').evaluate(el => el.compareDocumentPosition(document.querySelector('[data-new-episodes]')) & Node.DOCUMENT_POSITION_FOLLOWING)).toBeTruthy();
  await expect(page.locator('[data-last-refresh]')).toContainText('Sep 28, 2026');
  await expect(page.locator('[data-episode="elm-001"]')).toContainText('Source 42 min');
});

test('INTAKE-001 SUB-001 SUB-002 validates custom input and retains draft feedback', async ({ page }) => {
  await page.getByRole('button', { name: 'Subscribe' }).click();
  await page.locator('#count').selectOption('custom');
  await page.locator('#custom-count').fill('101');
  await page.locator('#custom-count').press('Tab');
  await page.locator('[data-subscribe]').click();
  await expect(page.locator('[data-subscribe-notice]')).toContainText('whole initial count from 1 to 100');
  await page.screenshot({ path: `${evidence}/wide-composer-error.png`, fullPage: true });
  await expect(page.locator('#custom-count')).toHaveValue('101');
  await page.locator('#custom-count').fill('5');
  await page.locator('#custom-count').press('Tab');
  await page.locator('#apple-url').fill('https://podcasts.apple.com/us/podcast/not-known/id9');
  await page.locator('[data-subscribe]').click();
  await expect(page.locator('[data-subscribe-notice]')).toContainText('recognizes only Apple ID 1680633614');
  await page.getByRole('button', { name: 'Cancel' }).click();
  await page.getByRole('button', { name: 'Subscribe' }).click();
  await expect(page.locator('#count')).toHaveValue('custom');
  await expect(page.locator('#custom-count')).toHaveValue('5');
  await expect(page.locator('#apple-url')).toHaveValue('https://podcasts.apple.com/us/podcast/not-known/id9');
  await page.locator('#apple-url').fill('https://podcasts.apple.com/us/podcast/the-ai-daily-brief/id1680633614');
  await page.locator('[data-subscribe]').click();
  await expect(page.locator('[data-feed-operation]')).toContainText('Looking up The AI Daily Brief');
  await page.waitForTimeout(350);
  await expect(page.locator('[data-subscriptions]')).toContainText('The AI Daily Brief');
  await expect(page.locator('[data-intake-ids]')).toHaveAttribute('data-intake-ids', 'ai-daily-001,ai-daily-002,ai-daily-003,ai-daily-004,ai-daily-005');
  await expect(page.locator('[data-subscriptions]')).toContainText('no audio downloaded');
  await page.screenshot({ path: `${evidence}/wide-composer-success.png`, fullPage: true });
  await page.locator('[data-subscribe]').click();
  await expect(page.locator('[data-subscribe-notice]')).toContainText('already subscribed');
});

test('INTAKE-001 Settings default supplies ten canonical metadata records', async ({ page }) => {
  await page.getByRole('button', { name: 'Settings' }).click();
  await page.locator('#default-count').selectOption('10');
  await page.getByRole('button', { name: 'Feeds' }).click();
  await page.getByRole('button', { name: 'Subscribe' }).click();
  await expect(page.locator('#count')).toHaveValue('10');
  await page.locator('[data-subscribe]').click();
  await page.waitForTimeout(350);
  await expect(page.locator('[data-intake-ids]')).toHaveAttribute('data-intake-ids', /ai-daily-010$/);
});

test('DECISION-001 BULK-001 bulk Keep moves the selected canonical rows to Larder', async ({ page }) => {
  await page.locator('[data-select="elm-001"]').check();
  await page.locator('[data-select="moss-003"]').check();
  await page.getByRole('button', { name: 'Keep selected (2)' }).click();
  await page.locator('#nav').getByRole('button', { name: 'Larder' }).click();
  await expect(page.locator('[data-larder-episodes] h2')).toHaveText('Episodes');
  await expect(page.locator('[data-episode="elm-001"]')).toContainText('Source 42 min');
  await expect(page.locator('[data-episode="moss-003"]')).toContainText('Unknown date');
});

test('DECISION-001 BULK-001 bulk Skip retains the failed selection and retries it', async ({ page }) => {
  await page.locator('[data-select="elm-001"]').check();
  await page.locator('[data-select="tide-002"]').check();
  await expect(page.locator('#all')).toHaveJSProperty('indeterminate', true);
  await page.getByRole('button', { name: 'Skip selected (2)' }).click();
  await expect(page.locator('#feed-rows [data-episode="elm-001"]')).toHaveCount(0);
  await expect(page.locator('[data-select="tide-002"]')).toBeChecked();
  await expect(page.getByRole('button', { name: 'Retry failed Skip' })).toBeVisible();
  await page.screenshot({ path: `${evidence}/wide-bulk-failure.png`, fullPage: true });
  await page.getByRole('button', { name: 'Retry failed Skip' }).click();
  await expect(page.locator('#feed-rows [data-episode="tide-002"]')).toHaveCount(0);
  await expect(page.locator('[data-episode="tide-002"]')).toHaveCount(1);
});

test('SUB-001 admits AI Daily Brief metadata and preserves it through Keep into Larder', async ({ page }) => {
  await page.getByRole('button', { name: 'Subscribe' }).click();
  await page.locator('[data-subscribe]').click();
  await page.waitForTimeout(350);
  await expect(page.locator('[data-episode="ai-daily-001"]')).toContainText('The AI Daily Brief · Sep 18, 2026 · Source 18 min');
  await page.screenshot({ path: `${evidence}/wide-subscription-admitted.png`, fullPage: true });
  await page.locator('[data-keep="ai-daily-001"]').click();
  await page.waitForTimeout(400);
  await page.locator('#nav').getByRole('button', { name: 'Larder' }).click();
  await expect(page.locator('[data-episode="ai-daily-001"]')).toContainText('The AI Daily Brief · Sep 18, 2026 · Source 18 min');
});

test('LARDER-001 ORDER-001 RESTORE-001 LINK-001 renders narrow lifecycle states', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('button', { name: 'Settings' }).click();
  await page.screenshot({ path: `${evidence}/narrow-settings.png`, fullPage: true });
  await page.locator('#nav').getByRole('button', { name: 'Larder' }).click();
  await expect(page.locator('[data-episode="ash-004"]')).toContainText('Source 35 min');
  await expect(page.locator('[data-episode="ash-004"]')).not.toContainText('Prepared playable');
  await expect(page.locator('[data-episode="fern-006"]')).toContainText('Prepared playable 22 min');
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toHaveCount(1);
  await page.getByRole('button', { name: 'Feeds' }).click();
  await page.locator('[data-keep="elm-001"]').click();
  await expect(page.locator('[data-notice]')).toContainText('pending');
  await page.waitForTimeout(400);
  await page.locator('#nav').getByRole('button', { name: 'Larder' }).click();
  await page.locator('#sort').selectOption('newest');
  expect(await page.locator('[data-episode]').evaluateAll(rows => rows.map(row => row.dataset.episode))).toEqual(['ash-004','elm-001','fern-006']);
  await page.locator('[data-work="elm-001"]').click();
  await page.waitForTimeout(350);
  await expect(page.locator('[data-episode="elm-001"]')).toContainText('downloaded');
  await page.locator('[data-work="elm-001"]').click();
  await page.waitForTimeout(350);
  await expect(page.locator('[data-episode="elm-001"]')).toContainText('Prepared playable');
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toHaveCount(2);
  await page.screenshot({ path: `${evidence}/narrow-larder-ready.png`, fullPage: true });
  await page.getByRole('button', { name: 'Feeds' }).click();
  await page.locator('[data-detail="moss-003"]').click();
  await expect(page.locator('[data-missing-page="moss-003"]')).toContainText('unavailable');
  await expect(page.locator('[data-detail-panel="moss-003"] a')).toHaveCount(0);
  await page.getByRole('button', { name: 'Restore' }).click();
  await expect(page.locator('#feed-rows [data-episode="rill-005"]')).toHaveCount(1);
});
