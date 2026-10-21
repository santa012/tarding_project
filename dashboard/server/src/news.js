const Parser = require('rss-parser');

const parser = new Parser({ timeout: 10_000 });

// Public finance/gold RSS feeds. Any feed that fails to fetch is skipped
// (not fatal) so one broken URL doesn't take the whole panel down.
const FEEDS = [
  { name: 'Investing.com - Commodities', url: 'https://www.investing.com/rss/news_11.rss' },
  { name: 'MarketWatch', url: 'http://feeds.marketwatch.com/marketwatch/topstories/' },
  { name: 'Yahoo Finance', url: 'https://finance.yahoo.com/news/rssindex' },
];

let cache = { items: [], updatedAt: null, feedStatus: [] };

async function fetchOneFeed(feed) {
  try {
    const parsed = await parser.parseURL(feed.url);
    const items = (parsed.items || []).slice(0, 15).map((it) => ({
      source: feed.name,
      title: it.title || '(no title)',
      link: it.link || '',
      pubDate: it.pubDate || it.isoDate || null,
    }));
    return { name: feed.name, ok: true, count: items.length, items };
  } catch (err) {
    return { name: feed.name, ok: false, error: err.message, items: [] };
  }
}

async function refreshNews() {
  const results = await Promise.all(FEEDS.map(fetchOneFeed));
  const items = results
    .flatMap((r) => r.items)
    .filter((it) => it.pubDate) // drop items we can't sort reliably
    .sort((a, b) => new Date(b.pubDate) - new Date(a.pubDate))
    .slice(0, 60);

  cache = {
    items,
    updatedAt: new Date().toISOString(),
    feedStatus: results.map((r) => ({ name: r.name, ok: r.ok, count: r.count || 0, error: r.error })),
  };
  return cache;
}

function getCachedNews() {
  return cache;
}

module.exports = { refreshNews, getCachedNews };
