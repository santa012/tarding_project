const BASE = import.meta.env.VITE_API_BASE || '/api';

async function get(path) {
  const res = await fetch(`${BASE}${path}`);
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return res.json();
}

// Builds a query string from { ea, account, limit } - omitting empty values.
function qs(filters = {}) {
  const params = new URLSearchParams();
  if (filters.ea) params.set('ea', filters.ea);
  if (filters.account) params.set('account', filters.account);
  if (filters.limit) params.set('limit', filters.limit);
  const s = params.toString();
  return s ? `?${s}` : '';
}

export const api = {
  health: () => get('/health'),
  eas: () => get('/eas'),
  accounts: () => get('/accounts'),
  summary: (filters) => get(`/summary${qs(filters)}`),
  equityCurve: (filters) => get(`/equity-curve${qs(filters)}`),
  trades: (filters) => get(`/trades${qs({ ...filters, limit: filters?.limit || 50 })}`),
  hourly: (filters) => get(`/hourly${qs(filters)}`),
  capitalStats: (filters) => get(`/capital-stats${qs(filters)}`),
  news: () => get('/news'),
  setCapital: async (value) => {
    const res = await fetch(`${BASE}/settings/capital`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ value }),
    });
    if (!res.ok) throw new Error(`setCapital -> ${res.status}`);
    return res.json();
  },
  upload: async (file) => {
    const form = new FormData();
    form.append('file', file);
    const res = await fetch(`${BASE}/upload`, { method: 'POST', body: form });
    if (!res.ok) throw new Error(`upload -> ${res.status}`);
    return res.json();
  },
};
