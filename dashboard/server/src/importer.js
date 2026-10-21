const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse/sync');
const { pool } = require('./db');

// EA log CSV header: Time,Event,Ticket,Type,Volume,Price,SL,TP,Profit,Comment
// Time format written by the EA: "YYYY.MM.DD HH:MM:SS"
function parseEaTime(s) {
  const m = /^(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/.exec(s.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, se] = m;
  return new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +se)).toISOString();
}

function sourceEaFromFileName(fileName) {
  return path.basename(fileName).replace(/_log\.csv$/i, '');
}

// Parses CSV text and upserts every row into the trades table.
// Returns { inserted, skipped, total }.
async function importCsvText(fileName, csvText) {
  const sourceEa = sourceEaFromFileName(fileName);
  // relax_column_count: older log files were created before the "Account"
  // column existed - their header has 10 fields but rows written after the
  // EA was recompiled have 11. Without this, csv-parse throws on the whole
  // file instead of just leaving `Account` undefined on the old rows.
  const records = parse(csvText, {
    columns: true,
    skip_empty_lines: true,
    trim: true,
    relax_column_count: true,
  });

  let inserted = 0;
  let skipped = 0;

  for (const row of records) {
    const eventTime = parseEaTime(row.Time || '');
    if (!eventTime) {
      skipped++;
      continue;
    }
    const ticket = Number(row.Ticket || 0);
    const event = row.Event || '';
    const accountLogin = row.Account !== undefined && row.Account !== '' ? Number(row.Account) : null;
    try {
      const result = await pool.query(
        `INSERT INTO trades
           (source_ea, event_time, event, ticket, type, volume, price, sl, tp, profit, comment, account_login)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
         ON CONFLICT (source_ea, ticket, event) DO NOTHING`,
        [
          sourceEa,
          eventTime,
          event,
          ticket,
          row.Type || '',
          Number(row.Volume || 0),
          Number(row.Price || 0),
          Number(row.SL || 0),
          Number(row.TP || 0),
          Number(row.Profit || 0),
          row.Comment || '',
          accountLogin,
        ]
      );
      if (result.rowCount > 0) inserted++;
      else skipped++;
    } catch (err) {
      console.error('Failed to insert row', row, err.message);
      skipped++;
    }
  }

  return { inserted, skipped, total: records.length };
}

// Watches a directory for *_log.csv files and imports new content
// incrementally, tracking how many bytes of each file have been read.
async function pollLogDirectory(logDir) {
  if (!fs.existsSync(logDir)) return;

  const files = fs.readdirSync(logDir).filter((f) => f.toLowerCase().endsWith('_log.csv'));
  for (const file of files) {
    const fullPath = path.join(logDir, file);
    let stat;
    try {
      stat = fs.statSync(fullPath);
    } catch {
      continue;
    }

    const cursorRes = await pool.query(
      'SELECT bytes_read FROM import_cursors WHERE file_name = $1',
      [file]
    );
    const bytesRead = cursorRes.rows[0] ? Number(cursorRes.rows[0].bytes_read) : 0;

    if (stat.size < bytesRead) {
      // File was truncated/recreated (e.g. EA restarted a fresh log) - re-import from scratch.
      await reimportWholeFile(file, fullPath);
      continue;
    }
    if (stat.size === bytesRead) continue; // nothing new

    // Always re-parse from the start of the file: the CSV header must be
    // present for csv-parse, and log files here are small (a few thousand
    // rows at most), so re-parsing is cheap and avoids partial-row bugs.
    const text = fs.readFileSync(fullPath, 'utf8');
    const { inserted, skipped, total } = await importCsvText(file, text);
    await pool.query(
      `INSERT INTO import_cursors (file_name, bytes_read, updated_at)
       VALUES ($1, $2, now())
       ON CONFLICT (file_name) DO UPDATE SET bytes_read = $2, updated_at = now()`,
      [file, stat.size]
    );
    if (inserted > 0) {
      console.log(`[importer] ${file}: +${inserted} new rows (total parsed ${total}, skipped ${skipped})`);
    }
  }
}

async function reimportWholeFile(file, fullPath) {
  const text = fs.readFileSync(fullPath, 'utf8');
  const { inserted } = await importCsvText(file, text);
  const stat = fs.statSync(fullPath);
  await pool.query(
    `INSERT INTO import_cursors (file_name, bytes_read, updated_at)
     VALUES ($1, $2, now())
     ON CONFLICT (file_name) DO UPDATE SET bytes_read = $2, updated_at = now()`,
    [file, stat.size]
  );
  console.log(`[importer] ${file}: re-imported after truncation/reset (+${inserted} rows)`);
}

module.exports = { importCsvText, pollLogDirectory, sourceEaFromFileName };
