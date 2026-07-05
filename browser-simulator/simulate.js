/**
 * Headless browser simulator for ecomm-otel demo.
 *
 * Drives real Chromium sessions through the storefront so that Embrace Web SDK
 * fires genuine browser RUM events: Core Web Vitals, network timing, JS errors.
 *
 * Environment:
 *   STOREFRONT_URL   — base URL (default http://storefront:3000)
 *   CONCURRENCY      — parallel browser sessions (default 3)
 *   THINK_TIME_MS    — pause between page actions in ms (default 1500)
 */

const { chromium } = require('playwright');

const STOREFRONT_URL = process.env.STOREFRONT_URL || 'http://storefront:3000';
const CONCURRENCY    = parseInt(process.env.CONCURRENCY   || '3', 10);
const THINK_TIME     = parseInt(process.env.THINK_TIME_MS || '1500', 10);

const EMAILS = ['alice@example.com', 'bob@example.com', 'carol@example.com', 'dave@example.com'];
const CARDS  = ['4111111111111111', '5500005555555559', '340000000000009'];

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function runSession(browser, id) {
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (ecomm-otel-browser-simulator/1.0) Chrome/120',
  });
  const page = await context.newPage();

  try {
    // ── Homepage — triggers LCP, FID baseline ─────────────────────────────
    await page.goto(STOREFRONT_URL, { waitUntil: 'networkidle', timeout: 15000 });
    await page.waitForSelector('#product-grid .card', { timeout: 10000 }).catch(() => {});
    await sleep(THINK_TIME);

    // ── Pick a product and click Buy Now ─────────────────────────────────
    const buyLinks = await page.$$('a.btn-primary');
    if (buyLinks.length > 0) {
      await buyLinks[Math.floor(Math.random() * buyLinks.length)].click();
      await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {});
      await sleep(THINK_TIME);
    }

    // ── Checkout ─────────────────────────────────────────────────────────
    await page.goto(`${STOREFRONT_URL}/checkout`, { waitUntil: 'domcontentloaded', timeout: 10000 });
    await page.fill('#email',      pick(EMAILS));
    await page.fill('#cardNumber', pick(CARDS));
    await sleep(500);
    await page.click('#submit-btn');
    // Wait for confirmation or error — either counts as completed interaction
    await Promise.race([
      page.waitForSelector('#confirmation:not(.d-none)', { timeout: 8000 }),
      page.waitForSelector('#error-box:not(.d-none)',    { timeout: 8000 }),
    ]).catch(() => {});

    console.log(`[session ${id}] checkout complete`);
  } catch (err) {
    console.error(`[session ${id}] error: ${err.message}`);
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
    // Brief cooldown between sessions to spread traffic naturally
    await sleep(Math.random() * 2000 + 500);
  }
}

async function main() {
  console.log(`browser-simulator starting — ${CONCURRENCY} workers → ${STOREFRONT_URL}`);

  const browser = await chromium.launch({
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });

  // Wait for storefront to be ready before spawning workers
  console.log('Waiting for storefront...');
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      const page = await browser.newPage();
      await page.goto(STOREFRONT_URL, { timeout: 5000 });
      await page.close();
      console.log('Storefront reachable — starting workers');
      break;
    } catch {
      await sleep(3000);
    }
  }

  // Stagger worker startup to avoid a thundering-herd on the first page load
  for (let i = 0; i < CONCURRENCY; i++) {
    setTimeout(() => workerLoop(browser, i), i * 1000);
  }
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
