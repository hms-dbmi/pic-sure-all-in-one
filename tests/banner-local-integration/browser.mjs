import fs from 'node:fs';
import { chromium } from 'playwright';

const [mode, resultPath] = process.argv.slice(2);
if (!['empty', 'published'].includes(mode) || !resultPath) {
  throw new Error('usage: browser.mjs <empty|published> <result.json>');
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
let failure;
try {
  const feed = page.waitForResponse(
    (response) => new URL(response.url()).pathname === '/picsure/operations/banners/active/v2',
    { timeout: 30000 },
  );
  await page.goto('http://frontend/login', { waitUntil: 'domcontentloaded', timeout: 30000 });
  const response = await feed;
  const body = JSON.parse(await response.text());
  await page.getByTestId('login-title').waitFor({ state: 'visible', timeout: 30000 });
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const region = page.getByTestId('site-banner-region');
  const regionCount = await region.count();
  const bannerText = regionCount === 1 ? await region.getByTestId('site-banner').allTextContents() : [];
  if (response.status() !== 200) throw new Error(`v2 feed returned HTTP ${response.status()}`);
  if (mode === 'empty' && (body.length !== 0 || regionCount !== 0)) {
    throw new Error(`empty state left feed rows or a banner gap: ${JSON.stringify({ body, regionCount })}`);
  }
  if (mode === 'published' && (body.length !== 1 || regionCount !== 1 || !bannerText.join(' ').includes('T22A synthetic banner'))) {
    throw new Error(`published banner did not render: ${JSON.stringify({ body, regionCount, bannerText })}`);
  }
  fs.writeFileSync(resultPath, `${JSON.stringify({ mode, feedStatus: response.status(), feedCount: body.length, regionCount, bannerText, retriesDisabled: true }, null, 2)}\n`);
} catch (error) {
  failure = error;
  fs.writeFileSync(resultPath, `${JSON.stringify({ mode, error: String(error), html: await page.content().catch(() => '') }, null, 2)}\n`);
} finally {
  await browser.close();
}
if (failure) throw failure;
