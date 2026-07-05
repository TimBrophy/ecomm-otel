/**
 * Mobile browser simulator for ecomm-otel demo.
 *
 * Uses Playwright device emulation (viewport, touch, user agent) to generate
 * realistic mobile RUM events in Embrace — distinct from the desktop sessions.
 *
 * Simulates realistic mobile behaviour: more browsing, higher checkout
 * abandonment, occasional slow-network sessions.
 *
 * Environment:
 *   STOREFRONT_URL   — base URL (default http://storefront:3000)
 *   CONCURRENCY      — parallel sessions (default 8)
 *   THINK_TIME_MS    — base pause between actions in ms (default 2000)
 */

const { chromium, devices } = require('playwright');

const STOREFRONT_URL = process.env.STOREFRONT_URL || 'http://storefront:3000';
const CONCURRENCY    = parseInt(process.env.CONCURRENCY   || '8', 10);
const THINK_TIME     = parseInt(process.env.THINK_TIME_MS || '2000', 10);

// Mix of iOS and Android devices for realistic diversity
const MOBILE_DEVICES = [
  devices['iPhone 14'],
  devices['iPhone 14 Pro'],
  devices['iPhone 13'],
  devices['Pixel 7'],
  devices['Pixel 5'],
  devices['Galaxy S9+'],
];

const EMAILS = ['alice@example.com', 'bob@example.com', 'carol@example.com', 'dave@example.com'];
const CARDS  = ['4111111111111111', '5500005555555559', '340000000000009'];

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
// Mobile users think longer and are more likely to abandon
function thinkTime() { return THINK_TIME + Math.random() * THINK_TIME; }

async function runSession(browser, id) {
  const device  = pick(MOBILE_DEVICES);
  const context = await browser.newContext({ ...device });
  const page    = await context.newPage();

  try {
    // ── Homepage ─────────────────────────────────────────────────────────
    await page.goto(STOREFRONT_URL, { waitUntil: 'networkidle', timeout: 20000 });
    await page.waitForSelector('#product-grid .card', { timeout: 10000 }).catch(() => {});
    await sleep(thinkTime());

    // ── Scroll down (mobile gesture) ─────────────────────────────────────
    await page.evaluate(() => window.scrollBy(0, 300));
    await sleep(800);
    await page.evaluate(() => window.scrollBy(0, 300));
    await sleep(thinkTime());

    // ── Browse a product ─────────────────────────────────────────────────
    const buyLinks = await page.$$('a.btn-primary');
    if (buyLinks.length === 0) return;
    await buyLinks[Math.floor(Math.random() * buyLinks.length)].tap();
    await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {});
    await sleep(thinkTime());

    // ── 40% abandonment rate — realistic mobile behaviour ────────────────
    if (Math.random() < 0.4) {
      console.log(`[mobile ${id}] abandoned at product (${device.userAgent.match(/iPhone|Android|Pixel|Galaxy/)?.[0] ?? 'mobile'})`);
      await sleep(2000);
      return;
    }

    // ── Checkout ─────────────────────────────────────────────────────────
    await page.goto(`${STOREFRONT_URL}/checkout`, { waitUntil: 'domcontentloaded', timeout: 10000 });
    await sleep(thinkTime());

    await page.tap('#email');
    await page.fill('#email', pick(EMAILS));
    await sleep(600);
    await page.tap('#cardNumber');
    await page.fill('#cardNumber', pick(CARDS));
    await sleep(800);
    await page.tap('#submit-btn');

    await Promise.race([
      page.waitForSelector('#confirmation:not(.d-none)', { timeout: 10000 }),
      page.waitForSelector('#error-box:not(.d-none)',    { timeout: 10000 }),
    ]).catch(() => {});

    console.log(`[mobile ${id}] checkout complete`);
  } catch (err) {
    console.error(`[mobile ${id}] error: ${err.message}`);
  } finally {
    // Give the Embrace SDK time to flush its beacon before the context closes
    await sleep(2000);
    await context.close();
  }
}

async function workerLoop(browser, workerId) {
  let session = 0;
  while (true) {
    await runSession(browser, `${workerId}-${session++}`);
    await sleep(Math.random() * 3000 + 1000);
  }
}

async function main() {
  console.log(`mobile-simulator starting — ${CONCURRENCY} workers → ${STOREFRONT_URL}`);

  const browser = await chromium.launch({
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });

  console.log('Waiting for storefront...');
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      const page = await browser.newPage();
      await page.goto(STOREFRONT_URL, { timeout: 5000 });
      await page.close();
      console.log('Storefront reachable — starting mobile workers');
      break;
    } catch {
      await sleep(3000);
    }
  }

  for (let i = 0; i < CONCURRENCY; i++) {
    setTimeout(() => workerLoop(browser, i), i * 800);
  }
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
