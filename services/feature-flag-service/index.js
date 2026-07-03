require('./tracing');

const express = require('express');
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8090;

// In-memory flag store — reset to defaults on startup
const defaults = { realtime_fraud_detection: false };
let flags = { ...defaults };

app.get('/health', (_, res) => res.json({ status: 'ok' }));

app.get('/flags/:name', (req, res) => {
  const value = flags[req.params.name];
  if (value === undefined) return res.status(404).json({ error: 'flag not found' });
  res.json({ name: req.params.name, value });
});

app.get('/flags', (_, res) => res.json(flags));

app.post('/flags', (req, res) => {
  const { name, value } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  flags[name] = value;
  console.log(`[flag] ${name} = ${value}`);
  res.json({ name, value });
});

app.post('/flags/reset', (_, res) => {
  flags = { ...defaults };
  console.log('[flag] reset to defaults');
  res.json(flags);
});

app.listen(PORT, () => console.log(`feature-flag-service listening on :${PORT}`));
