import React from 'react';

const NAV_ITEMS = [
  { key: 'overview', label: 'ภาพรวม', icon: '◈' },
  { key: 'performance', label: 'ผลการเทรด', icon: '◫' },
  { key: 'trades', label: 'รายการไม้', icon: '≡' },
  { key: 'news', label: 'ข่าว', icon: '◎' },
  { key: 'settings', label: 'ตั้งค่า', icon: '⚙' },
];

export default function Sidebar({ active, onSelect, collapsed, onToggleCollapse }) {
  return (
    <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
      <div className="sidebar-brand">
        <div className="brand-mark">G</div>
        {!collapsed && (
          <div className="brand-text">
            <div className="brand-name">GoldTrendEA</div>
            <div className="brand-sub">Trading Dashboard</div>
          </div>
        )}
      </div>

      <nav className="sidebar-nav">
        {NAV_ITEMS.map((item) => (
          <button
            key={item.key}
            className={`nav-item ${active === item.key ? 'active' : ''}`}
            onClick={() => onSelect(item.key)}
            title={item.label}
          >
            <span className="nav-icon">{item.icon}</span>
            {!collapsed && <span className="nav-label">{item.label}</span>}
          </button>
        ))}
      </nav>

      <button className="sidebar-collapse-btn" onClick={onToggleCollapse}>
        {collapsed ? '»' : '« ย่อเมนู'}
      </button>
    </aside>
  );
}
