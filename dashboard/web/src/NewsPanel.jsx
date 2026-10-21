import React, { useEffect, useState, useCallback } from 'react';
import { api } from './api.js';

const NEWS_REFRESH_MS = 5 * 60 * 1000; // 5 minutes - closer to real-time than the main 15-min refresh

function timeAgo(iso) {
  if (!iso) return '';
  const diffMs = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diffMs / 60000);
  if (mins < 1) return 'เมื่อสักครู่';
  if (mins < 60) return `${mins} นาทีที่แล้ว`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs} ชม.ที่แล้ว`;
  return `${Math.floor(hrs / 24)} วันที่แล้ว`;
}

export default function NewsPanel() {
  const [news, setNews] = useState({ items: [], updatedAt: null, feedStatus: [] });
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const data = await api.news();
      setNews(data);
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }, []);

  useEffect(() => {
    load();
    const id = setInterval(load, NEWS_REFRESH_MS);
    return () => clearInterval(id);
  }, [load]);

  const failedFeeds = news.feedStatus?.filter((f) => !f.ok) || [];

  return (
    <section className="news-block">
      <div className="news-header">
        <h2>ข่าวทอง / การเงิน (เรียลไทม์)</h2>
        <span className="refresh-info">
          รีเฟรชทุก 5 นาที
          {news.updatedAt && ` · อัปเดตล่าสุด ${new Date(news.updatedAt).toLocaleTimeString('th-TH')}`}
        </span>
      </div>

      {error && <div className="error-banner">โหลดข่าวไม่สำเร็จ: {error}</div>}
      {failedFeeds.length > 0 && (
        <div className="info-banner">
          บางแหล่งข่าวดึงไม่ได้ตอนนี้: {failedFeeds.map((f) => f.name).join(', ')}
        </div>
      )}

      <ul className="news-list">
        {news.items.length === 0 && !error && <li className="empty">กำลังโหลดข่าว...</li>}
        {news.items.map((it, i) => (
          <li key={`${it.link}-${i}`} className="news-item">
            <a href={it.link} target="_blank" rel="noreferrer">
              {it.title}
            </a>
            <div className="news-meta">
              <span className="news-source">{it.source}</span>
              <span>·</span>
              <span>{timeAgo(it.pubDate)}</span>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
