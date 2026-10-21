import React, { useEffect, useMemo, useState, useCallback } from 'react';
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  BarChart,
  Bar,
  Legend,
} from 'recharts';
import { api } from './api.js';
import NewsPanel from './NewsPanel.jsx';
import Sidebar from './Sidebar.jsx';

const REFRESH_MS = 15 * 60 * 1000; // 15 minutes, matches the EA's own bar interval

const PAGE_TITLES = {
  overview: 'ภาพรวม',
  performance: 'ผลการเทรด',
  trades: 'รายการไม้ล่าสุด',
  news: 'ข่าวทอง / การเงิน',
  settings: 'ตั้งค่า',
};

function formatTime(iso) {
  const d = new Date(iso);
  return d.toLocaleString('th-TH', { hour12: false });
}

function SummaryCard({ row }) {
  const good = row.netProfit >= 0;
  return (
    <div className="card">
      <div className="card-title">{row.sourceEa}</div>
      <div className={`card-net ${good ? 'pos' : 'neg'}`}>
        {good ? '+' : ''}
        {row.netProfit.toFixed(2)} USD
      </div>
      <div className="card-grid">
        <div>
          <span className="label">Trades</span>
          <span>{row.trades}</span>
        </div>
        <div>
          <span className="label">Win rate</span>
          <span>{row.winRatePct}%</span>
        </div>
        <div>
          <span className="label">Wins / Losses</span>
          <span>
            {row.wins} / {row.losses}
          </span>
        </div>
        <div>
          <span className="label">Avg win</span>
          <span>{row.avgWin.toFixed(2)}</span>
        </div>
        <div>
          <span className="label">Avg loss</span>
          <span>{row.avgLoss.toFixed(2)}</span>
        </div>
        <div>
          <span className="label">Expectancy/trade</span>
          <span className={row.expectancyPerTrade >= 0 ? 'pos' : 'neg'}>
            {row.expectancyPerTrade.toFixed(3)}
          </span>
        </div>
      </div>
    </div>
  );
}

function CapitalBlock({ capitalStats, capitalInput, setCapitalInput, onSave }) {
  return (
    <section className="capital-block">
      <div className="capital-row">
        <span>ทุนเริ่มต้น:</span>
        <input
          type="number"
          min="1"
          step="1"
          value={capitalInput}
          onChange={(e) => setCapitalInput(e.target.value)}
          className="capital-input"
        />
        <span>USD</span>
        <button onClick={onSave} className="save-btn">
          บันทึก
        </button>
      </div>

      {capitalStats && (
        <div className="pl-cards">
          <div className="pl-card">
            <div className="pl-title">กำไรวันนี้</div>
            <div className="pl-value pos">
              +{capitalStats.today.profit.toFixed(2)} <span className="pl-pct">(+{capitalStats.today.profitPct}%)</span>
            </div>
          </div>
          <div className="pl-card">
            <div className="pl-title">ขาดทุนวันนี้</div>
            <div className="pl-value neg">
              {capitalStats.today.loss.toFixed(2)} <span className="pl-pct">({capitalStats.today.lossPct}%)</span>
            </div>
          </div>
          <div className="pl-card">
            <div className="pl-title">กำไรเดือนนี้</div>
            <div className="pl-value pos">
              +{capitalStats.month.profit.toFixed(2)} <span className="pl-pct">(+{capitalStats.month.profitPct}%)</span>
            </div>
          </div>
          <div className="pl-card">
            <div className="pl-title">ขาดทุนเดือนนี้</div>
            <div className="pl-value neg">
              {capitalStats.month.loss.toFixed(2)} <span className="pl-pct">({capitalStats.month.lossPct}%)</span>
            </div>
          </div>
          <div className="pl-card highlight">
            <div className="pl-title">สุทธิวันนี้ / เดือนนี้</div>
            <div className={`pl-value ${capitalStats.today.net >= 0 ? 'pos' : 'neg'}`}>
              {capitalStats.today.net >= 0 ? '+' : ''}
              {capitalStats.today.net.toFixed(2)} ({capitalStats.today.netPct >= 0 ? '+' : ''}
              {capitalStats.today.netPct}%)
            </div>
            <div className={`pl-value small ${capitalStats.month.net >= 0 ? 'pos' : 'neg'}`}>
              {capitalStats.month.net >= 0 ? '+' : ''}
              {capitalStats.month.net.toFixed(2)} ({capitalStats.month.netPct >= 0 ? '+' : ''}
              {capitalStats.month.netPct}%)
            </div>
          </div>
        </div>
      )}
    </section>
  );
}

function TradesTable({ trades, limit }) {
  const rows = limit ? trades.slice(0, limit) : trades;
  return (
    <section className="table-block">
      <table>
        <thead>
          <tr>
            <th>เวลา</th>
            <th>EA</th>
            <th>บัญชี</th>
            <th>Ticket</th>
            <th>ประเภท</th>
            <th>Volume</th>
            <th>ราคาปิด</th>
            <th>กำไร/ขาดทุน</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((t) => (
            <tr key={`${t.source_ea}-${t.ticket}`}>
              <td>{formatTime(t.event_time)}</td>
              <td>{t.source_ea}</td>
              <td>{t.account_login ?? '-'}</td>
              <td>{t.ticket}</td>
              <td>{t.type}</td>
              <td>{t.volume}</td>
              <td>{t.price}</td>
              <td className={Number(t.profit) >= 0 ? 'pos' : 'neg'}>{Number(t.profit).toFixed(2)}</td>
            </tr>
          ))}
          {rows.length === 0 && (
            <tr>
              <td colSpan={8} className="empty">
                ไม่มีข้อมูล
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </section>
  );
}

export default function App() {
  const [page, setPage] = useState('overview');
  const [collapsed, setCollapsed] = useState(false);

  const [eas, setEas] = useState([]);
  const [selectedEa, setSelectedEa] = useState('');
  const [accounts, setAccounts] = useState([]);
  const [selectedAccount, setSelectedAccount] = useState('');
  const [summary, setSummary] = useState([]);
  const [equity, setEquity] = useState([]);
  const [hourly, setHourly] = useState([]);
  const [trades, setTrades] = useState([]);
  const [capitalStats, setCapitalStats] = useState(null);
  const [capitalInput, setCapitalInput] = useState('');
  const [lastUpdated, setLastUpdated] = useState(null);
  const [error, setError] = useState(null);
  const [uploadMsg, setUploadMsg] = useState('');

  const loadAll = useCallback(async () => {
    try {
      const filters = { ea: selectedEa || undefined, account: selectedAccount || undefined };
      const [eaList, accountList, summaryRows, equityRows, hourlyRows, tradeRows, capStats] = await Promise.all([
        api.eas(),
        api.accounts(),
        api.summary(filters),
        api.equityCurve(filters),
        api.hourly(filters),
        api.trades({ ...filters, limit: 100 }),
        api.capitalStats(filters),
      ]);
      setEas(eaList);
      setAccounts(accountList);
      setSummary(summaryRows);
      setEquity(equityRows);
      setHourly(hourlyRows);
      setTrades(tradeRows);
      setCapitalStats(capStats);
      setCapitalInput(String(capStats.startingCapital));
      setLastUpdated(new Date());
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }, [selectedEa, selectedAccount]);

  async function handleSaveCapital() {
    try {
      await api.setCapital(Number(capitalInput));
      await loadAll();
    } catch (err) {
      setError(err.message);
    }
  }

  useEffect(() => {
    loadAll();
    const id = setInterval(loadAll, REFRESH_MS);
    return () => clearInterval(id);
  }, [loadAll]);

  const equityChartData = useMemo(
    () =>
      equity.map((r, i) => ({
        idx: i + 1,
        time: formatTime(r.time),
        runningTotal: r.runningTotal,
      })),
    [equity]
  );

  async function handleUpload(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const result = await api.upload(file);
      setUploadMsg(`อัปโหลดสำเร็จ: +${result.inserted} แถวใหม่ (ทั้งหมด ${result.total})`);
      await loadAll();
    } catch (err) {
      setUploadMsg(`อัปโหลดล้มเหลว: ${err.message}`);
    }
  }

  const visibleSummary = summary.filter((r) => !selectedEa || r.sourceEa === selectedEa);

  return (
    <div className="shell">
      <Sidebar active={page} onSelect={setPage} collapsed={collapsed} onToggleCollapse={() => setCollapsed((c) => !c)} />

      <div className="main">
        <header className="topbar">
          <h1>{PAGE_TITLES[page]}</h1>
          <div className="topbar-right">
            <select value={selectedEa} onChange={(e) => setSelectedEa(e.target.value)}>
              <option value="">ทุก EA</option>
              {eas.map((ea) => (
                <option key={ea} value={ea}>
                  {ea}
                </option>
              ))}
            </select>
            <select value={selectedAccount} onChange={(e) => setSelectedAccount(e.target.value)}>
              <option value="">ทุกบัญชี</option>
              {accounts.map((acc) => (
                <option key={acc} value={acc}>
                  {acc}
                </option>
              ))}
            </select>
            <span className="refresh-info">
              รีเฟรชทุก 15 นาที
              {lastUpdated && ` · ล่าสุด ${lastUpdated.toLocaleTimeString('th-TH')}`}
            </span>
          </div>
        </header>

        <div className="content">
          {error && <div className="error-banner">โหลดข้อมูลไม่สำเร็จ: {error}</div>}
          {uploadMsg && <div className="info-banner">{uploadMsg}</div>}

          {page === 'overview' && (
            <>
              <CapitalBlock
                capitalStats={capitalStats}
                capitalInput={capitalInput}
                setCapitalInput={setCapitalInput}
                onSave={handleSaveCapital}
              />
              <section className="cards">
                {visibleSummary.length === 0 && <div className="empty">ยังไม่มีข้อมูล log ในระบบ</div>}
                {visibleSummary.map((row) => (
                  <SummaryCard key={row.sourceEa} row={row} />
                ))}
              </section>
              <section className="chart-block">
                <h2>Equity curve (กำไร/ขาดทุนสะสม)</h2>
                <ResponsiveContainer width="100%" height={280}>
                  <LineChart data={equityChartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#232833" />
                    <XAxis dataKey="idx" stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <YAxis stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <Tooltip
                      contentStyle={{ background: '#161a22', border: '1px solid #2a2f3a' }}
                      labelFormatter={(idx) => equityChartData[idx - 1]?.time || ''}
                    />
                    <Line type="monotone" dataKey="runningTotal" stroke="#4ade80" dot={false} strokeWidth={2} />
                  </LineChart>
                </ResponsiveContainer>
              </section>
              <TradesTable trades={trades} limit={8} />
            </>
          )}

          {page === 'performance' && (
            <>
              <section className="cards">
                {visibleSummary.length === 0 && <div className="empty">ยังไม่มีข้อมูล log ในระบบ</div>}
                {visibleSummary.map((row) => (
                  <SummaryCard key={row.sourceEa} row={row} />
                ))}
              </section>
              <section className="chart-block">
                <h2>Equity curve (กำไร/ขาดทุนสะสม)</h2>
                <ResponsiveContainer width="100%" height={340}>
                  <LineChart data={equityChartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#232833" />
                    <XAxis dataKey="idx" stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <YAxis stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <Tooltip
                      contentStyle={{ background: '#161a22', border: '1px solid #2a2f3a' }}
                      labelFormatter={(idx) => equityChartData[idx - 1]?.time || ''}
                    />
                    <Line type="monotone" dataKey="runningTotal" stroke="#4ade80" dot={false} strokeWidth={2} />
                  </LineChart>
                </ResponsiveContainer>
              </section>
              <section className="chart-block">
                <h2>ผลตามช่วงเวลา (ชั่วโมงเซิร์ฟเวอร์)</h2>
                <ResponsiveContainer width="100%" height={300}>
                  <BarChart data={hourly}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#232833" />
                    <XAxis dataKey="hour" stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <YAxis stroke="#8890a0" tick={{ fontSize: 11 }} />
                    <Tooltip contentStyle={{ background: '#161a22', border: '1px solid #2a2f3a' }} />
                    <Legend />
                    <Bar dataKey="trades" fill="#60a5fa" name="จำนวนไม้" />
                    <Bar dataKey="winRatePct" fill="#4ade80" name="Win rate %" />
                  </BarChart>
                </ResponsiveContainer>
              </section>
            </>
          )}

          {page === 'trades' && <TradesTable trades={trades} />}

          {page === 'news' && <NewsPanel />}

          {page === 'settings' && (
            <section className="settings-block">
              <div className="settings-card">
                <h2>ทุนเริ่มต้น</h2>
                <p className="settings-desc">ใช้คำนวณ % กำไร/ขาดทุนในหน้าภาพรวม</p>
                <div className="capital-row">
                  <input
                    type="number"
                    min="1"
                    step="1"
                    value={capitalInput}
                    onChange={(e) => setCapitalInput(e.target.value)}
                    className="capital-input"
                  />
                  <span>USD</span>
                  <button onClick={handleSaveCapital} className="save-btn">
                    บันทึก
                  </button>
                </div>
              </div>

              <div className="settings-card">
                <h2>นำเข้า log CSV ด้วยมือ</h2>
                <p className="settings-desc">
                  ใช้กรณี auto-watcher ยังไม่เห็นไฟล์ log ล่าสุด (ปกติระบบดึงอัตโนมัติทุก 60 วิ)
                </p>
                <label className="upload-btn">
                  เลือกไฟล์ CSV
                  <input type="file" accept=".csv" onChange={handleUpload} hidden />
                </label>
              </div>
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
