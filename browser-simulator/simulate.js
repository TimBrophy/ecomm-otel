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

const REGIONS = [
  { name: 'Amsterdam',     locale: 'nl-NL', timezoneId: 'Europe/Amsterdam',   geolocation: { latitude: 52.37, longitude:   4.90 } },
  { name: 'London',        locale: 'en-GB', timezoneId: 'Europe/London',       geolocation: { latitude: 51.51, longitude:  -0.12 } },
  { name: 'Paris',         locale: 'fr-FR', timezoneId: 'Europe/Paris',        geolocation: { latitude: 48.86, longitude:   2.35 } },
  { name: 'New York',      locale: 'en-US', timezoneId: 'America/New_York',    geolocation: { latitude: 40.71, longitude: -74.01 } },
  { name: 'Los Angeles',   locale: 'en-US', timezoneId: 'America/Los_Angeles', geolocation: { latitude: 34.05, longitude: -118.24 } },
  { name: 'Singapore',     locale: 'en-SG', timezoneId: 'Asia/Singapore',      geolocation: { latitude:  1.35, longitude: 103.82 } },
  { name: 'Tokyo',         locale: 'ja-JP', timezoneId: 'Asia/Tokyo',          geolocation: { latitude: 35.68, longitude: 139.69 } },
  { name: 'Sydney',        locale: 'en-AU', timezoneId: 'Australia/Sydney',    geolocation: { latitude: -33.87, longitude: 151.21 } },
  { name: 'Dubai',         locale: 'ar-AE', timezoneId: 'Asia/Dubai',          geolocation: { latitude: 25.20, longitude:  55.27 } },
  { name: 'São Paulo',     locale: 'pt-BR', timezoneId: 'America/Sao_Paulo',   geolocation: { latitude: -23.55, longitude: -46.63 } },
];

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function runSession(browser, id) {
  const region  = pick(REGIONS);
  const context = await browser.newContext({
    locale:      region.locale,
    timezoneId:  region.timezoneId,
    geolocation: region.geolocation,
    permissions: ['geolocation'],
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
    await page.goto(`${STOREFRONT_URL}/checkout`, { waitUntil: 'networkidle', timeout: 15000 });
    await page.fill('#email',      pick(EMAILS));
    await page.fill('#cardNumber', pick(CARDS));
    await sleep(500);
    await page.click('#submit-btn');
    // Wait for confirmation or error — either counts as completed interaction
    await Promise.race([
      page.waitForSelector('#confirmation:not(.d-none)', { timeout: 8000 }),
      page.waitForSelector('#error-box:not(.d-none)',    { timeout: 8000 }),
    ]).catch(() => {});

    // Navigate back to homepage — triggers the Embrace SDK's visibilitychange /
    // beforeunload flush so the checkout_attempt span is exported before the
    // context closes (same mechanism as a real user moving to the next page).
    await page.goto(STOREFRONT_URL, { waitUntil: 'domcontentloaded', timeout: 10000 }).catch(() => {});

    console.log(`[session ${id}] checkout complete (${region.name})`);
  } catch (err) {
    console.error(`[session ${id}] error: ${err.message}`);
  } finally {
    await sleep(1000);
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
