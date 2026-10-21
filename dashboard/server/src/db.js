const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PGHOST || 'db',
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || 'goldtrend',
  password: process.env.PGPASSWORD || 'goldtrend',
  database: process.env.PGDATABASE || 'goldtrend',
});

module.exports = { pool };
