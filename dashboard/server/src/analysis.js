const { pool } = require('./db');

// Appends "AND source_ea = $n" / "AND account_login = $n" clauses as needed,
// pushing values onto `params` in the same order. Returns the WHERE clause.
function buildWhere(baseClause, params, { sourceEa, accountLogin } = {}) {
  let where = baseClause;
  if (sourceEa) {
    params.push(sourceEa);
    where += ` AND source_ea = $${params.length}`;
  }
  if (accountLogin) {
    params.push(Number(accountLogin));
    where += ` AND account_login = $${params.length}`;
  }
  return where;
}

// Overall + per-EA summary stats computed from CLOSE rows.
async function getSummary(filters = {}) {
  const params = [];
  const where = buildWhere("WHERE event = 'CLOSE'", params, filters);
  const { rows } = await pool.query(
    `SELECT
      source_ea,
      account_login,
      COUNT(*)                                               AS trades,
      COUNT(*) FILTER (WHERE profit > 0)                     AS wins,
      COUNT(*) FILTER (WHERE profit < 0)                     AS losses,
      COUNT(*) FILTER (WHERE profit = 0)                     AS breakeven,
      COALESCE(SUM(profit), 0)                                AS net_profit,
      COALESCE(AVG(profit) FILTER (WHERE profit > 0), 0)      AS avg_win,
      COALESCE(AVG(profit) FILTER (WHERE profit < 0), 0)      AS avg_loss,
      COALESCE(MAX(profit), 0)                                AS best_trade,
      COALESCE(MIN(profit), 0)                                AS worst_trade
    FROM trades
    ${where}
    GROUP BY source_ea, account_login
    ORDER BY source_ea`,
    params
  );

  return rows.map((r) => {
    const trades = Number(r.trades);
    const wins = Number(r.wins);
    const winRate = trades > 0 ? (wins / trades) * 100 : 0;
    const avgWin = Number(r.avg_win);
    const avgLoss = Number(r.avg_loss); // negative
    const lossRate = trades > 0 ? Number(r.losses) / trades : 0;
    const expectancy = (winRate / 100) * avgWin + lossRate * avgLoss;
    return {
      sourceEa: r.source_ea,
      accountLogin: r.account_login !== null ? Number(r.account_login) : null,
      trades,
      wins,
      losses: Number(r.losses),
      breakeven: Number(r.breakeven),
      winRatePct: Number(winRate.toFixed(2)),
      netProfit: Number(Number(r.net_profit).toFixed(2)),
      avgWin: Number(avgWin.toFixed(2)),
      avgLoss: Number(avgLoss.toFixed(2)),
      bestTrade: Number(r.best_trade),
      worstTrade: Number(r.worst_trade),
      expectancyPerTrade: Number(expectancy.toFixed(3)),
    };
  });
}

// Equity curve: running cumulative profit over time, per EA.
async function getEquityCurve(filters = {}) {
  const params = [];
  const where = buildWhere("WHERE event = 'CLOSE'", params, filters);
  const { rows } = await pool.query(
    `SELECT source_ea, event_time, profit,
            SUM(profit) OVER (PARTITION BY source_ea ORDER BY event_time, id) AS running_total
     FROM trades
     ${where}
     ORDER BY event_time ASC`,
    params
  );
  return rows.map((r) => ({
    sourceEa: r.source_ea,
    time: r.event_time,
    profit: Number(r.profit),
    runningTotal: Number(r.running_total),
  }));
}

// Recent trades (joined OPEN+CLOSE by ticket where possible, else raw rows).
async function getRecentTrades(limit = 50, filters = {}) {
  const params = [limit];
  let where = "WHERE event = 'CLOSE'";
  if (filters.sourceEa) {
    params.push(filters.sourceEa);
    where += ` AND source_ea = $${params.length}`;
  }
  if (filters.accountLogin) {
    params.push(Number(filters.accountLogin));
    where += ` AND account_login = $${params.length}`;
  }
  const { rows } = await pool.query(
    `SELECT source_ea, account_login, event_time, ticket, type, volume, price, profit, comment
     FROM trades
     ${where}
     ORDER BY event_time DESC
     LIMIT $1`,
    params
  );
  return rows;
}

// Win rate bucketed by hour-of-day (server time as recorded in the log),
// useful for spotting which sessions actually work for a strategy.
async function getHourlyBreakdown(filters = {}) {
  const params = [];
  const where = buildWhere("WHERE event = 'CLOSE'", params, filters);
  const { rows } = await pool.query(
    `SELECT EXTRACT(HOUR FROM event_time)::int AS hour,
            COUNT(*) AS trades,
            COUNT(*) FILTER (WHERE profit > 0) AS wins,
            COALESCE(SUM(profit), 0) AS net_profit
     FROM trades
     ${where}
     GROUP BY hour
     ORDER BY hour`,
    params
  );
  return rows.map((r) => ({
    hour: r.hour,
    trades: Number(r.trades),
    wins: Number(r.wins),
    winRatePct: Number(r.trades) > 0 ? Number(((r.wins / r.trades) * 100).toFixed(1)) : 0,
    netProfit: Number(Number(r.net_profit).toFixed(2)),
  }));
}

async function listSourceEas() {
  const { rows } = await pool.query('SELECT DISTINCT source_ea FROM trades ORDER BY source_ea');
  return rows.map((r) => r.source_ea);
}

// Distinct account logins seen in the logs, for the dashboard's account filter.
async function listAccounts() {
  const { rows } = await pool.query(
    'SELECT DISTINCT account_login FROM trades WHERE account_login IS NOT NULL ORDER BY account_login'
  );
  return rows.map((r) => Number(r.account_login));
}

const DEFAULT_CAPITAL = 100;

async function getStartingCapital() {
  const { rows } = await pool.query("SELECT value FROM settings WHERE key = 'starting_capital'");
  if (rows.length === 0) return DEFAULT_CAPITAL;
  const v = Number(rows[0].value);
  return Number.isFinite(v) && v > 0 ? v : DEFAULT_CAPITAL;
}

async function setStartingCapital(value) {
  const v = Number(value);
  if (!Number.isFinite(v) || v <= 0) throw new Error('capital must be a positive number');
  await pool.query(
    `INSERT INTO settings (key, value) VALUES ('starting_capital', $1)
     ON CONFLICT (key) DO UPDATE SET value = $1`,
    [String(v)]
  );
  return v;
}

// Profit/loss split for today and this calendar month, plus % of starting capital.
// filters optional - when omitted, aggregates across all EAs/accounts.
async function getCapitalStats(filters = {}) {
  const params = [];
  const where = buildWhere("WHERE event = 'CLOSE'", params, filters);
  const { rows } = await pool.query(
    `SELECT
       COALESCE(SUM(profit) FILTER (WHERE profit > 0 AND event_time >= date_trunc('day', now())), 0)   AS today_profit,
       COALESCE(SUM(profit) FILTER (WHERE profit < 0 AND event_time >= date_trunc('day', now())), 0)   AS today_loss,
       COALESCE(SUM(profit) FILTER (WHERE profit > 0 AND event_time >= date_trunc('month', now())), 0) AS month_profit,
       COALESCE(SUM(profit) FILTER (WHERE profit < 0 AND event_time >= date_trunc('month', now())), 0) AS month_loss
     FROM trades
     ${where}`,
    params
  );

  const r = rows[0];
  const capital = await getStartingCapital();
  const todayProfit = Number(r.today_profit);
  const todayLoss = Number(r.today_loss);
  const monthProfit = Number(r.month_profit);
  const monthLoss = Number(r.month_loss);
  const todayNet = todayProfit + todayLoss;
  const monthNet = monthProfit + monthLoss;

  const pct = (n) => Number(((n / capital) * 100).toFixed(2));

  return {
    startingCapital: capital,
    today: {
      profit: Number(todayProfit.toFixed(2)),
      loss: Number(todayLoss.toFixed(2)),
      net: Number(todayNet.toFixed(2)),
      profitPct: pct(todayProfit),
      lossPct: pct(todayLoss),
      netPct: pct(todayNet),
    },
    month: {
      profit: Number(monthProfit.toFixed(2)),
      loss: Number(monthLoss.toFixed(2)),
      net: Number(monthNet.toFixed(2)),
      profitPct: pct(monthProfit),
      lossPct: pct(monthLoss),
      netPct: pct(monthNet),
    },
  };
}

module.exports = {
  getSummary,
  getEquityCurve,
  getRecentTrades,
  getHourlyBreakdown,
  listSourceEas,
  listAccounts,
  getCapitalStats,
  getStartingCapital,
  setStartingCapital,
};
