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

/* ── 扇区页: read_sector + hexdump(字段着色) ── */
const META_LBAS = [0, 4, 6, 7, 8, 9, 11, 12];
let sectorView = null;

$('#sector-jumps').innerHTML = META_LBAS.map(l => `<span class="jump-btn" data-lba="${l}">${l}</span>`).join(' ');
document.querySelectorAll('.jump-btn').forEach(b =>
  b.addEventListener('click', () => { $('#sector-lba').value = b.dataset.lba; loadSector(+b.dataset.lba); }));
$('#btn-sector-load').addEventListener('click', () => loadSector(+$('#sector-lba').value || 0));
$('#sector-prev').addEventListener('click', () => { const i = +$('#sector-lba').value || 0; $('#sector-lba').value = Math.max(0, i - 1); loadSector(i - 1); });
$('#sector-next').addEventListener('click', () => { const i = +$('#sector-lba').value || 0; $('#sector-lba').value = i + 1; loadSector(i + 1); });
document.querySelectorAll('input[name=sector-view]').forEach(r => r.addEventListener('change', () => renderHexdump()));

async function loadSector(lba) {
  if (!currentDisk || lba < 0) return;
  const el = $('#hexdump');
  el.textContent = `读取 disk${currentDisk} LBA${lba}…`;
  try {
    sectorView = await invoke('read_sector', { diskNo: currentDisk, lba });
    renderHexdump();
  } catch (e) {
    sectorView = null;
    el.textContent = '错误: ' + e;
  }
}

function renderHexdump() {
  if (!sectorView) return;
  const view = document.querySelector('input[name=sector-view]:checked').value;
  const useDec = view === 'dec' && sectorView.dec_hex;
  const hexStr = useDec ? sectorView.dec_hex : sectorView.raw_hex;
  $('#sector-method').textContent =
    (sectorView.dec_method ? `[${view === 'dec' && !useDec ? '不可解密, 显示原始' : sectorView.dec_method}]` : '[无解密]');
  const bytes = hexStr.match(/../g) || [];
  // 字段着色映射: 字节偏移 → FieldRow
  const fmap = new Map();
  if (useDec) for (const f of sectorView.fields)
    for (let i = 0; i < f.len && f.off + i < 512; i++)
      if (!fmap.has(f.off + i)) fmap.set(f.off + i, f);

  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  let out = '';
  for (let row = 0; row < 32; row++) {
    let hexPart = '', asciiPart = '';
    for (let c = 0; c < 16; c++) {
      const idx = row * 16 + c;
      const f = fmap.get(idx);
      const b = bytes[idx] || '00';
      const ch = parseInt(b, 16);
      const asc = ch >= 32 && ch < 127 ? esc(String.fromCharCode(ch)) : '.';
      if (f) {
        const tip = esc(`${f.name} · ${f.desc}` + (f.value ? `\n= ${f.value}` : ''));
        hexPart += `<span class="b c-${f.color}" data-tip="${tip}">${b}</span> `;
        asciiPart += `<span class="b c-${f.color}" data-tip="${tip}">${asc}</span>`;
      } else {
        hexPart += `<span class="b">${b}</span> `;
        asciiPart += `<span class="b dim2">${asc}</span>`;
      }
    }
    out += `<span class="off">${(row * 16).toString(16).padStart(3, '0')}</span>${hexPart}<span class="ascii">${asciiPart}</span>\n`;
  }
  $('#hexdump').innerHTML = out;
}
const STATUS_COLOR = { encrypted: 'var(--accent)', nopwd: 'var(--accent-2)', not_cems: 'var(--text-dim)' };
$('#disk-select').addEventListener('change', (e) => {
  const d = e.target.value;
  if (d) {
    currentDisk = +d;
    analyzeDisk(+d);
    loadDiskMap(+d);
    loadSector(+($('#sector-lba').value || 0));
  } else location.reload();
});

/* ── 盘地图页 ── */
const REGION_LEGEND = [
    ['meta', '#8b949e', '元数据区'], ['data', '#1f6feb', 'Share 数据区'], ['boot', '#58a6ff', 'Boot 区'],
    ['encrypt', '#bc8cff', 'Encrypt 加密区'], ['free', '#21262d', '空档'], ['tail', '#d29922', '尾部区域'],
];

function jumpToSector(lba) {
  document.querySelector('.tabs button[data-page="sector"]').click();
  $('#sector-lba').value = lba;
  loadSector(lba);
}

const escTip = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/\n/g, '&#10;');

async function loadDiskMap(disk) {
  try {
    const m = await invoke('disk_map', { diskNo: disk });
    // LBA0-13 方格
    $('#map-meta').innerHTML = m.meta.map(c =>
      `<div class="meta-cell mc-${c.color}" data-lba="${c.lba}" ` +
      `data-tip="<span class='tt-title'>LBA${c.lba} · ${c.name}</span>&#10;${escTip(c.desc)}">` +
      `<span class="lba-no">${c.lba}</span><span class="lba-name">${c.name}</span></div>`).join('');
    document.querySelectorAll('#map-meta .meta-cell').forEach(el =>
      el.addEventListener('click', () => jumpToSector(+el.dataset.lba)));

    // 全盘比例条(按扇区占比, 小区域保底可见)
    const total = m.total_sectors;
    $('#map-total').textContent = `共 ${total.toLocaleString()} 扇 · ${m.size_gb}`;
    const rows = m.regions.map(r => ({ ...r, span: r.end_lba - r.start_lba + 1 }));
    $('#map-strip').innerHTML = rows.map(r => {
      const pct = Math.max(r.span / total * 100, 0.6);
      const label = pct > 7 ? r.name : '';
      return `<div class="map-region map-c-${r.color}" style="flex:${pct} 1 0" ` +
        `data-lba="${r.start_lba}" data-tip="<span class='tt-title'>${r.name}</span>&#10;` +
        `LBA ${r.start_lba.toLocaleString()} ~ ${r.end_lba.toLocaleString()} · ${r.size_gb}&#10;${escTip(r.desc)}">${label}</div>`;
    }).join('');
    document.querySelectorAll('#map-strip .map-region').forEach(el =>
      el.addEventListener('click', () => jumpToSector(+el.dataset.lba)));
    $('#map-legend').innerHTML = REGION_LEGEND.map(([k, c, n]) =>
      `<span><i style="background:${c}"></i>${n}</span>`).join('');

    // 尾部放大条(等宽)
    $('#map-tail').innerHTML = m.tail.map(r =>
      `<div class="map-region map-c-${r.color}" style="flex:1" data-lba="${r.start_lba}" ` +
      `data-tip="<span class='tt-title'>${r.name}</span>&#10;LBA ${r.start_lba.toLocaleString()} ~ ${r.end_lba.toLocaleString()} · ${r.size_gb}&#10;${escTip(r.desc)}">${r.name}</div>`).join('');
    document.querySelectorAll('#map-tail .map-region').forEach(el =>
      el.addEventListener('click', () => jumpToSector(+el.dataset.lba)));
  } catch (e) {
    $('#map-meta').innerHTML = `<div class="placeholder" style="color:var(--danger)">${e}</div>`;
  }
}

let currentDisk = null;

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
