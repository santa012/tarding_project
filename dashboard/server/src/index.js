const express = require('express');
const cors = require('cors');
const multer = require('multer');
const { pool } = require('./db');
const { importCsvText, pollLogDirectory } = require('./importer');
const { refreshNews, getCachedNews } = require('./news');
const {
  getSummary,
  getEquityCurve,
  getRecentTrades,
  getHourlyBreakdown,
  listSourceEas,
  listAccounts,
  getCapitalStats,
  getStartingCapital,
  setStartingCapital,
} = require('./analysis');

// Pulls {ea, account} filters out of a request's query string, consistently
// across every route below.
function filtersFromQuery(req) {
  return { sourceEa: req.query.ea || undefined, accountLogin: req.query.account || undefined };
}

const PORT = process.env.PORT || 4000;
const LOG_DIR = process.env.LOG_DIR || '/data/mt5-logs';
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || 60_000);
const NEWS_INTERVAL_MS = Number(process.env.NEWS_INTERVAL_MS || 5 * 60_000);

const app = express();
app.use(cors());
app.use(express.json());

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });

app.get('/api/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/eas', async (_req, res) => {
  res.json(await listSourceEas());
});

app.get('/api/accounts', async (_req, res) => {
  res.json(await listAccounts());
});

app.get('/api/summary', async (req, res) => {
  res.json(await getSummary(filtersFromQuery(req)));
});

app.get('/api/equity-curve', async (req, res) => {
  res.json(await getEquityCurve(filtersFromQuery(req)));
});

app.get('/api/trades', async (req, res) => {
  const limit = Math.min(Number(req.query.limit || 50), 500);
  res.json(await getRecentTrades(limit, filtersFromQuery(req)));
});

app.get('/api/hourly', async (req, res) => {
  res.json(await getHourlyBreakdown(filtersFromQuery(req)));
});

app.get('/api/capital-stats', async (req, res) => {
  res.json(await getCapitalStats(filtersFromQuery(req)));
});

app.get('/api/settings/capital', async (_req, res) => {
  res.json({ value: await getStartingCapital() });
});

app.get('/api/news', (_req, res) => {
  res.json(getCachedNews());
});

app.put('/api/settings/capital', async (req, res) => {
  try {
    const value = await setStartingCapital(req.body.value);
    res.json({ ok: true, value });
  } catch (err) {
    res.status(400).json({ ok: false, error: err.message });
  }
});

// Manual upload path: drag a *_log.csv file from the MT5 Files folder here
// if the auto-watcher isn't pointed at the right directory.
app.post('/api/upload', upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'no file uploaded' });
  try {
    const text = req.file.buffer.toString('utf8');
    const result = await importCsvText(req.file.originalname, text);
    res.json({ ok: true, ...result });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

async function migrate() {
  // Runs on every boot so it also applies to a Postgres volume created
  // before this table existed (init.sql only runs on a brand-new volume).
  await pool.query(`
    CREATE TABLE IF NOT EXISTS settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  `);
  await pool.query(`ALTER TABLE trades ADD COLUMN IF NOT EXISTS account_login BIGINT`);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_trades_account_login ON trades (account_login)`);
}

async function start() {
  await migrate();
  app.listen(PORT, () => {
    console.log(`Dashboard API listening on :${PORT}`);
    console.log(`Watching log directory: ${LOG_DIR} every ${POLL_INTERVAL_MS}ms`);
    console.log(`Refreshing news every ${NEWS_INTERVAL_MS}ms`);
  });
  pollLoop();
  newsLoop();
}

async function pollLoop() {
  try {
    await pollLogDirectory(LOG_DIR);
  } catch (err) {
    console.error('[importer] poll failed:', err.message);
  } finally {
    setTimeout(pollLoop, POLL_INTERVAL_MS);
  }
}

async function newsLoop() {
  try {
    const result = await refreshNews();
    console.log(
      `[news] refreshed: ${result.items.length} items | ` +
        result.feedStatus.map((f) => `${f.name}=${f.ok ? f.count : 'FAIL'}`).join(', ')
    );
  } catch (err) {
    console.error('[news] refresh failed:', err.message);
  } finally {
    setTimeout(newsLoop, NEWS_INTERVAL_MS);
  }
}

start().catch((err) => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
