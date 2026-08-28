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
