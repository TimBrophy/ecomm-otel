const express = require('express');
const axios = require('axios');

const app = express();
const PORT = process.env.PORT || 3000;
const API_GATEWAY_URL = process.env.API_GATEWAY_URL || 'http://api-gateway:8080';
const EMBRACE_APP_ID = process.env.EMBRACE_APP_ID || '';

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static('public'));

// ─── Shared HTML helpers ────────────────────────────────────────────────────

function bootstrapCss() {
  return `<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">`;
}

function pageHead(title) {
  const embraceSnippet = EMBRACE_APP_ID
    ? `\n  <script>window.__EMBRACE_APP_ID__ = '${EMBRACE_APP_ID}';</script>\n  <script src="/embrace-bundle.js" defer></script>`
    : '';
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} — eComm Store</title>
  ${bootstrapCss()}${embraceSnippet}
</head>`;
}

function navBar() {
  return `
<nav class="navbar navbar-expand-lg navbar-dark bg-dark mb-4">
  <div class="container">
    <a class="navbar-brand" href="/">eComm Store</a>
    <div class="navbar-nav ms-auto">
      <a class="nav-link" href="/">Home</a>
      <a class="nav-link" href="/checkout">Checkout</a>
    </div>
  </div>
</nav>`;
}

// ─── Pages ──────────────────────────────────────────────────────────────────

app.get('/', (req, res) => {
  res.send(`${pageHead('Home')}
<body>
${navBar()}
<div class="container">
  <h1 class="mb-4">Our Products</h1>
  <div id="product-grid" class="row g-4">
    <div class="col-12 text-center text-muted">Loading products…</div>
  </div>
</div>
<script>
  (async function loadProducts() {
    const grid = document.getElementById('product-grid');
    try {
      const res = await fetch('/api/products');
      if (!res.ok) throw new Error('Network response was not ok: ' + res.status);
      const products = await res.json();
      if (!Array.isArray(products) || products.length === 0) {
        grid.innerHTML = '<div class="col-12 text-center text-muted">No products found.</div>';
        return;
      }
      grid.innerHTML = products.map(p => \`
        <div class="col-sm-6 col-md-4 col-lg-3">
          <div class="card h-100 shadow-sm">
            <div class="card-body d-flex flex-column">
              <h5 class="card-title">\${p.name || p.id}</h5>
              <p class="card-text text-muted flex-grow-1">\${p.description || ''}</p>
              <p class="card-text fw-bold fs-5">\${p.price != null ? '€' + Number(p.price).toFixed(2) : ''}</p>
              <a href="/checkout?productId=\${p.id}" class="btn btn-primary mt-auto">Buy Now</a>
            </div>
          </div>
        </div>
      \`).join('');
    } catch (err) {
      grid.innerHTML = '<div class="col-12"><div class="alert alert-danger">Failed to load products: ' + err.message + '</div></div>';
    }
  })();
</script>
</body>
</html>`);
});

app.get('/product/:id', async (req, res) => {
  const productId = req.params.id;
  let product = null;
  let errorMsg = null;

  try {
    const response = await axios.get(`${API_GATEWAY_URL}/api/products/${productId}`);
    product = response.data;
  } catch (err) {
    errorMsg = err.response ? `API error ${err.response.status}` : err.message;
  }

  const body = product
    ? `
      <div class="card shadow-sm" style="max-width:480px">
        <div class="card-body">
          <h2 class="card-title">${product.name || productId}</h2>
          <p class="card-text text-muted">${product.description || 'No description available.'}</p>
          <p class="card-text fw-bold fs-4">${product.price != null ? '€' + Number(product.price).toFixed(2) : ''}</p>
          <a href="/checkout?productId=${productId}" class="btn btn-primary">Buy Now</a>
          <a href="/" class="btn btn-outline-secondary ms-2">Back</a>
        </div>
      </div>`
    : `<div class="alert alert-danger">Could not load product: ${errorMsg}</div><a href="/" class="btn btn-secondary">Back</a>`;

  res.send(`${pageHead('Product')}
<body>
${navBar()}
<div class="container">${body}</div>
</body>
</html>`);
});

app.get('/checkout', async (req, res) => {
  const productId = req.query.productId || '';

  // Pre-flight: validate checkout readiness via api-gateway → checkout-service.
  // When realtime_fraud_detection is active the call blocks 200–500 ms while
  // checkout-service pings FraudShield, making TTFB (and therefore LCP) degrade
  // in the browser. The distributed trace links this page load to the root cause.
  const preflightStart = Date.now();
  try {
    await axios.get(`${API_GATEWAY_URL}/api/checkout/validate`);
  } catch (_) {
    // Non-fatal — page renders even if validation is unreachable
  }
  const preflightMs = Date.now() - preflightStart;
  res.setHeader('Server-Timing', `checkout-validate;dur=${preflightMs}`);

  res.send(`${pageHead('Checkout')}
<body>
${navBar()}
<div class="container" style="max-width:540px">
  <h1 class="mb-4">Checkout</h1>
  <div id="confirmation" class="alert alert-success d-none"></div>
  <div id="error-box" class="alert alert-danger d-none"></div>
  <form id="checkout-form">
    <input type="hidden" name="productId" id="productId" value="${productId}">
    <div class="mb-3">
      <label for="email" class="form-label">Email address</label>
      <input type="email" class="form-control" id="email" name="email" required placeholder="you@example.com">
    </div>
    <div class="mb-3">
      <label for="cardNumber" class="form-label">Card number</label>
      <input type="text" class="form-control" id="cardNumber" name="cardNumber" required
             placeholder="4111 1111 1111 1111" maxlength="19" autocomplete="cc-number">
    </div>
    <button type="submit" class="btn btn-success w-100" id="submit-btn">Place Order</button>
  </form>
</div>
<script>
  document.getElementById('checkout-form').addEventListener('submit', async function(e) {
    e.preventDefault();
    const btn = document.getElementById('submit-btn');
    const confirmBox = document.getElementById('confirmation');
    const errorBox = document.getElementById('error-box');
    confirmBox.classList.add('d-none');
    errorBox.classList.add('d-none');
    btn.disabled = true;
    btn.textContent = 'Processing…';

    const payload = {
      productId: document.getElementById('productId').value,
      email: document.getElementById('email').value,
      cardNumber: document.getElementById('cardNumber').value,
    };

    try {
      const res = await fetch('/api/checkout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        document.getElementById('checkout-form').classList.add('d-none');
        confirmBox.textContent = 'Order confirmed! ' + (data.message || ('Order ID: ' + (data.orderId || 'N/A')));
        confirmBox.classList.remove('d-none');
      } else {
        throw new Error(data.error || data.message || ('HTTP ' + res.status));
      }
    } catch (err) {
      errorBox.textContent = 'Checkout failed: ' + err.message;
      errorBox.classList.remove('d-none');
      btn.disabled = false;
      btn.textContent = 'Place Order';
    }
  });
</script>
</body>
</html>`);
});

// ─── API proxy routes ────────────────────────────────────────────────────────

app.get('/api/products', async (req, res) => {
  try {
    const response = await axios.get(`${API_GATEWAY_URL}/api/products`, {
      headers: { 'x-forwarded-for': req.ip },
    });
    res.status(response.status).json(response.data);
  } catch (err) {
    const status = err.response ? err.response.status : 502;
    const data = err.response ? err.response.data : { error: 'upstream unavailable' };
    res.status(status).json(data);
  }
});

app.post('/api/checkout', async (req, res) => {
  const start = Date.now();
  try {
    const response = await axios.post(`${API_GATEWAY_URL}/api/checkout`, req.body, {
      headers: {
        'Content-Type': 'application/json',
        'x-forwarded-for': req.ip,
      },
    });
    res.setHeader('Server-Timing', `checkout-api;dur=${Date.now() - start}`);
    res.status(response.status).json(response.data);
  } catch (err) {
    res.setHeader('Server-Timing', `checkout-api;dur=${Date.now() - start}`);
    const status = err.response ? err.response.status : 502;
    const data = err.response ? err.response.data : { error: 'upstream unavailable' };
    res.status(status).json(data);
  }
});

// ─── Health check ────────────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'storefront' });
});

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`storefront listening on port ${PORT}`);
  console.log(`API_GATEWAY_URL: ${API_GATEWAY_URL}`);
});
