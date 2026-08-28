// EDPOpen 前端 — 原生 JS, 无框架无构建
const $ = (sel) => document.querySelector(sel);
const invoke = window.__TAURI__.core.invoke;

/* ── tooltip 通用(盘地图/字段着色共用) ── */
const tooltip = $('#tooltip');
function showTooltip(html, x, y) {
  tooltip.innerHTML = html;
  tooltip.hidden = false;
  const r = tooltip.getBoundingClientRect();
  tooltip.style.left = Math.min(x + 14, innerWidth - r.width - 8) + 'px';
  tooltip.style.top = Math.min(y + 14, innerHeight - r.height - 8) + 'px';
}
function hideTooltip() { tooltip.hidden = true; }
document.addEventListener('mousemove', (e) => {
  const t = e.target.closest('[data-tip]');
  if (t) showTooltip(t.dataset.tip, e.clientX, e.clientY);
  else hideTooltip();
});

/* ── 页签切换 ── */
$('#tabs').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-page]');
  if (!btn) return;
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('active', b === btn));
  document.querySelectorAll('.page').forEach(p =>
    p.classList.toggle('active', p.id === `page-${btn.dataset.page}`));
});

/* ── 后端连通性 ── */
async function checkBackend() {
  const el = $('#backend-state');
  try {
    const r = await invoke('ping');
    el.textContent = r; el.classList.add('ok');
  } catch (e) {
    el.textContent = '连接失败: ' + e; el.classList.remove('ok');
  }
}
checkBackend();

/* ── 盘枚举(占位: disk.rs 完成后接 list_disks) ── */
$('#btn-refresh').addEventListener('click', refreshDisks);
async function refreshDisks() {
  try {
    const disks = await invoke('list_disks');
    const sel = $('#disk-select');
    sel.innerHTML = disks.length
      ? disks.map(d => `<option value="${d.disk}">disk${d.disk} — ${(d.size_bytes/1e9).toFixed(2)}GB</option>`).join('')
      : '<option value="">— 未检测到 USB 盘 —</option>';
    $('#disk-hint').textContent = disks.length ? `${disks.length} 个 USB 盘` : '';
  } catch (e) {
    $('#disk-hint').textContent = '枚举失败: ' + e;
  }
}
refreshDisks();

/* ── 概览页: 选盘 → analyze_disk → 渲染 ── */
const STATUS_COLOR = { encrypted: 'var(--accent)', nopwd: 'var(--accent-2)', not_cems: 'var(--text-dim)' };
$('#disk-select').addEventListener('change', (e) => {
  const d = e.target.value;
  if (d) analyzeDisk(+d); else location.reload();
});

async function analyzeDisk(disk) {
  const box = $('#overview-content');
  box.innerHTML = '<div class="card placeholder">分析中…</div>';
  try {
    const o = await invoke('analyze_disk', { diskNo: disk });
    const parts = o.partitions.length
      ? `<table class="grid"><tr><th>#</th><th>类型</th><th>起始 LBA</th><th>扇数</th><th>大小</th></tr>` +
        o.partitions.map(p =>
          `<tr><td>${p.index}</td><td>${p.type_name}</td><td>${p.start.toLocaleString()}</td><td>${p.sectors.toLocaleString()}</td><td>${p.size_gb}</td></tr>`).join('') + '</table>'
      : '<div class="dim">无分区表</div>';
    const layout = o.layout.length
      ? o.layout.map(l =>
          `<div class="layout-row"><span class="lname">${l.name}</span>` +
          `<span class="lrange">LBA ${l.start.toLocaleString()} ~ ${l.end.toLocaleString()}</span>` +
          `<span class="lsize">${l.size_gb}</span><span class="dim">${l.note}</span></div>`).join('')
      : '';
    box.innerHTML = `
      <div class="card">
        <div class="kv"><span class="k">盘</span><span class="v">disk${o.disk} · ${o.size_gb} · USB ${o.vid}:${o.pid}</span></div>
        <div class="kv"><span class="k">标识</span><span class="v mono">${o.device_id} <span class="dim">(CRC32 0x${o.crc32} · K0 0x${o.lba7_k0})</span></span></div>
        <div class="kv"><span class="k">状态</span><span class="v badge" style="color:${STATUS_COLOR[o.status] || 'inherit'};border-color:${STATUS_COLOR[o.status] || 'inherit'}">${o.status_label}</span>
          <span class="dim">LBA12 ${o.lba12_entries} 条 entry · LBA9 ${o.lba9_eetu ? '有 EETU' : '无 EETU'}</span></div>
      </div>
      <div class="card"><h3>EDPF 布局(LBA12)</h3>${layout}</div>
      <div class="card"><h3>MBR 分区表</h3>${parts}</div>`;
  } catch (e) {
    box.innerHTML = `<div class="card placeholder" style="color:var(--danger)">${e}</div>`;
  }
}
