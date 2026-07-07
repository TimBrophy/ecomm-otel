require('./tracing');

const express = require('express');
const axios = require('axios');
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;
const PRODUCT_SERVICE_URL   = process.env.PRODUCT_SERVICE_URL   || 'http://product-service:8081';
const CHECKOUT_SERVICE_URL  = process.env.CHECKOUT_SERVICE_URL  || 'http://checkout-service:8082';
const ORDER_SERVICE_URL     = process.env.ORDER_SERVICE_URL     || 'http://order-service:8083';

app.get('/health', (_, res) => res.json({ status: 'ok' }));

app.get('/api/products', async (req, res) => {
  try {
    const { data } = await axios.get(`${PRODUCT_SERVICE_URL}/products`, {
      headers: propagate(req),
    });
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'product-service unavailable', detail: err.message });
  }
});

app.get('/api/checkout/validate', async (req, res) => {
  try {
    const { data } = await axios.get(`${CHECKOUT_SERVICE_URL}/checkout/validate`, {
      headers: propagate(req),
    });
    res.json(data);
  } catch (err) {
    const status = err.response?.status || 502;
    res.status(status).json({ error: 'checkout validation failed', detail: err.message });
  }
});

app.post('/api/checkout', async (req, res) => {
  try {
    const { data } = await axios.post(`${CHECKOUT_SERVICE_URL}/checkout`, req.body, {
      headers: { 'Content-Type': 'application/json', ...propagate(req) },
    });
    res.json(data);
  } catch (err) {
    const status = err.response?.status || 502;
    res.status(status).json({ error: 'checkout failed', detail: err.message });
  }
});

app.get('/api/orders/:id', async (req, res) => {
  try {
    const { data } = await axios.get(`${ORDER_SERVICE_URL}/orders/${req.params.id}`, {
      headers: propagate(req),
    });
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'order-service unavailable', detail: err.message });
  }
});

// Forward W3C trace context headers downstream
function propagate(req) {
  const headers = {};
  if (req.headers['traceparent']) headers['traceparent'] = req.headers['traceparent'];
  if (req.headers['tracestate'])  headers['tracestate']  = req.headers['tracestate'];
  return headers;
}

app.listen(PORT, () => console.log(`api-gateway listening on :${PORT}`));
