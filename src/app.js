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
  if (btn.dataset.page === 'backup') loadBackups();
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
const EDIT_WRITABLE_LBAS = new Set([0, 4, 6, 7, 8, 9, 11, 12, 13]);
let sectorView = null;
let sectorEdit = null;

$('#sector-jumps').innerHTML = META_LBAS.map(l => `<span class="jump-btn" data-lba="${l}">${l}</span>`).join(' ');
document.querySelectorAll('.jump-btn').forEach(b =>
  b.addEventListener('click', () => { $('#sector-lba').value = b.dataset.lba; loadSector(+b.dataset.lba); }));
$('#btn-sector-load').addEventListener('click', () => loadSector(+$('#sector-lba').value || 0));
$('#sector-prev').addEventListener('click', () => { const i = +$('#sector-lba').value || 0; $('#sector-lba').value = Math.max(0, i - 1); loadSector(i - 1); });
$('#sector-next').addEventListener('click', () => { const i = +$('#sector-lba').value || 0; $('#sector-lba').value = i + 1; loadSector(i + 1); });
document.querySelectorAll('input[name=sector-view]').forEach(r => r.addEventListener('change', () => renderHexdump()));

async function loadSector(lba) {
  if (!currentDisk || lba < 0) return;
  if (sectorEdit) exitSectorEdit(false);
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
  const selectedView = document.querySelector('input[name=sector-view]:checked').value;
  const view = sectorEdit ? sectorEdit.view : selectedView;
  const useDec = view === 'dec' && sectorView.dec_hex;
  const hexStr = sectorEdit ? sectorEdit.bytes.join('') : (useDec ? sectorView.dec_hex : sectorView.raw_hex);
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
      const changed = sectorEdit && sectorEdit.baseBytes[idx] !== sectorEdit.bytes[idx];
      const selected = sectorEdit && sectorEdit.selected === idx;
      const editCls = `${changed ? ' edit-changed' : ''}${selected ? ' edit-selected' : ''}`;
      const dataIdx = sectorEdit ? ` data-byte-index="${idx}"` : '';
      if (f) {
        const tip = esc(`${f.name} · ${f.desc}` + (f.value ? `\n= ${f.value}` : ''));
        hexPart += `<span class="b c-${f.color}${editCls}"${dataIdx} data-tip="${tip}">${b}</span> `;
        asciiPart += `<span class="b c-${f.color}${editCls}"${dataIdx} data-tip="${tip}">${asc}</span>`;
      } else {
        hexPart += `<span class="b${editCls}"${dataIdx}>${b}</span> `;
        asciiPart += `<span class="b dim2${editCls}"${dataIdx}>${asc}</span>`;
      }
    }
    out += `<span class="off">${(row * 16).toString(16).padStart(3, '0')}</span>${hexPart}<span class="ascii">${asciiPart}</span>\n`;
  }
  $('#hexdump').innerHTML = out;
  if (sectorEdit) {
    document.querySelectorAll('#hexdump [data-byte-index]').forEach(el =>
      el.addEventListener('click', () => selectEditByte(+el.dataset.byteIndex)));
  }
}

function beginSectorEdit() {
  if (!sectorView) return;
  const useDec = !!sectorView.dec_hex;
  const baseHex = useDec ? sectorView.dec_hex : sectorView.raw_hex;
  const bytes = baseHex.match(/../g) || [];
  if (bytes.length !== 512) return;
  sectorEdit = {
    view: useDec ? 'dec' : 'raw',
    baseBytes: bytes.slice(),
    bytes: bytes.slice(),
    selected: null,
    preview: null,
  };
  if (useDec) document.querySelector('input[name=sector-view][value=dec]').checked = true;
  document.querySelectorAll('input[name=sector-view]').forEach(r => r.disabled = true);
  $('#sector-editor').hidden = false;
  $('#edit-offset').textContent = '—';
  $('#edit-byte').value = '';
  $('#edit-byte').disabled = true;
  $('#btn-edit-set').disabled = true;
  $('#btn-edit-export').disabled = true;
  $('#btn-edit-save').disabled = true;
  $('#edit-status').textContent = EDIT_WRITABLE_LBAS.has(sectorView.lba)
    ? '点击下方任意字节开始编辑；黄色为已修改字节。'
    : '当前 LBA 可编辑预览，但安全写入器不允许保存到真实 U 盘。';
  $('#edit-warnings').innerHTML = '';
  renderHexdump();
}

function exitSectorEdit(render = true) {
  sectorEdit = null;
  document.querySelectorAll('input[name=sector-view]').forEach(r => r.disabled = false);
  $('#sector-editor').hidden = true;
  if (render && sectorView) renderHexdump();
}

function selectEditByte(idx) {
  if (!sectorEdit || idx < 0 || idx >= 512) return;
  sectorEdit.selected = idx;
  $('#edit-offset').textContent = `0x${idx.toString(16).padStart(3, '0')} (${idx})`;
  $('#edit-byte').value = sectorEdit.bytes[idx].toUpperCase();
  $('#edit-byte').disabled = false;
  $('#btn-edit-set').disabled = false;
  $('#edit-byte').focus();
  $('#edit-byte').select();
  renderHexdump();
}

function invalidateEditPreview() {
  if (!sectorEdit) return;
  sectorEdit.preview = null;
  $('#btn-edit-export').disabled = true;
  $('#btn-edit-save').disabled = true;
  $('#edit-warnings').innerHTML = '';
}

function setSelectedEditByte() {
  if (!sectorEdit || sectorEdit.selected == null) return;
  const value = $('#edit-byte').value.trim();
  if (!/^[0-9a-fA-F]{2}$/.test(value)) {
    $('#edit-status').textContent = '字节值必须是两位十六进制，例如 00、7F、A5。';
    return;
  }
  sectorEdit.bytes[sectorEdit.selected] = value.toLowerCase();
  invalidateEditPreview();
  const changed = sectorEdit.bytes.filter((b, i) => b !== sectorEdit.baseBytes[i]).length;
  $('#edit-status').textContent = `已修改 ${changed} 个视图字节；请先执行“重加密预览”。`;
  renderHexdump();
}

async function previewSectorEdit() {
  if (!sectorEdit || !sectorView || !currentDisk) return;
  const editedHex = sectorEdit.bytes.join('');
  try {
    const p = await invoke('preview_sector_edit', {
      diskNo: currentDisk,
      lba: sectorView.lba,
      editedHex,
    });
    sectorEdit.preview = p;
    $('#edit-status').textContent = p.save_blocked_reason
      ? `重加密预览完成，但禁止保存：${p.save_blocked_reason}`
      : `重加密预览完成：raw 将变化 ${p.changed_raw_offsets.length} 个字节。`;
    const messages = [...p.warnings];
    if (p.save_blocked_reason) messages.push(p.save_blocked_reason);
    $('#edit-warnings').innerHTML = messages.length
      ? messages.map(w => `<div>⚠ ${escTip(w)}</div>`).join('')
      : '<div class="backup-ok">未触发额外敏感区警告。</div>';
    $('#btn-edit-export').disabled = false;
    $('#btn-edit-save').disabled = !!p.save_blocked_reason || !EDIT_WRITABLE_LBAS.has(sectorView.lba) || p.changed_raw_offsets.length === 0;
  } catch (e) {
    sectorEdit.preview = null;
    $('#btn-edit-export').disabled = true;
    $('#btn-edit-save').disabled = true;
    $('#edit-status').textContent = '预览失败: ' + e;
  }
}

function exportSectorEditRaw() {
  if (!sectorEdit?.preview || !sectorView || !currentDisk) return;
  const pairs = sectorEdit.preview.raw_hex.match(/../g) || [];
  const bytes = new Uint8Array(pairs.map(x => parseInt(x, 16)));
  const blob = new Blob([bytes], { type: 'application/octet-stream' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `edpopen_disk${currentDisk}_lba${sectorView.lba}_raw.bin`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
  $('#edit-status').textContent = `已导出重加密 raw：${a.download}`;
}

async function saveSectorEdit() {
  if (!sectorEdit || !sectorEdit.preview || !sectorView || !currentDisk) return;
  const warnings = sectorEdit.preview.warnings || [];
  const detail = warnings.length ? `\n\n警告:\n- ${warnings.join('\n- ')}` : '';
  if (!confirm(
    `确认保存 disk${currentDisk} LBA${sectorView.lba} 的编辑?\n` +
    `raw 将变化 ${sectorEdit.preview.changed_raw_offsets.length} 个字节。\n` +
    '保存前会自动备份 LBA0-13，并再次核验目标盘身份。' + detail
  )) return;
  $('#btn-edit-save').disabled = true;
  $('#edit-status').textContent = '重新核验扇区与目标盘身份，等待系统授权…';
  try {
    const r = await invoke('apply_sector_edit', {
      diskNo: currentDisk,
      lba: sectorView.lba,
      editedHex: sectorEdit.bytes.join(''),
      expectedRawHex: sectorView.raw_hex,
    });
    $('#edit-status').textContent = r.ok
      ? `✓ LBA${sectorView.lba} 已保存并回读验证 · 备份: ${r.backup_path}`
      : '✗ ' + (r.error || '未知错误');
    await loadSector(sectorView.lba);
    await loadBackups();
    await analyzeDisk(currentDisk);
  } catch (e) {
    $('#edit-status').textContent = '✗ ' + e;
    $('#btn-edit-save').disabled = false;
  }
}

$('#btn-sector-edit').addEventListener('click', beginSectorEdit);
$('#btn-edit-exit').addEventListener('click', () => exitSectorEdit());
$('#btn-edit-set').addEventListener('click', setSelectedEditByte);
$('#edit-byte').addEventListener('keydown', e => { if (e.key === 'Enter') setSelectedEditByte(); });
$('#btn-edit-undo').addEventListener('click', () => {
  if (!sectorEdit) return;
  sectorEdit.bytes = sectorEdit.baseBytes.slice();
  sectorEdit.selected = null;
  invalidateEditPreview();
  $('#edit-offset').textContent = '—';
  $('#edit-byte').value = '';
  $('#edit-byte').disabled = true;
  $('#btn-edit-set').disabled = true;
  $('#edit-status').textContent = '已撤销全部修改。';
  renderHexdump();
});
$('#btn-edit-preview').addEventListener('click', previewSectorEdit);
$('#btn-edit-export').addEventListener('click', exportSectorEditRaw);
$('#btn-edit-save').addEventListener('click', saveSectorEdit);

const STATUS_COLOR = { encrypted: 'var(--accent)', nopwd: 'var(--accent-2)', not_cems: 'var(--text-dim)' };
$('#disk-select').addEventListener('change', (e) => {
  const d = e.target.value;
  if (d) {
    currentDisk = +d;
    analyzeDisk(+d);
    loadDiskMap(+d);
    loadConvertPreview();
    loadSector(+($('#sector-lba').value || 0));
    loadBackups();
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

/* ── 改造页: 预览 → 授权写入 ── */
$('#btn-convert-load').addEventListener('click', loadConvertPreview);
$('#btn-convert-apply').addEventListener('click', async () => {
  if (!currentDisk) return;
  if (!confirm(`确认改造 disk${currentDisk}? 将先自动备份 LBA0-13, 再写入免密布局(需管理员授权)。`)) return;
  $('#convert-status').textContent = '等待管理员授权…';
  $('#btn-convert-apply').disabled = true;
  try {
    const r = await invoke('apply_convert', { diskNo: currentDisk, sizeGb: readSizeGb() });
    $('#convert-status').textContent = r.ok
      ? `✓ 已写入并回读校验 ${r.verified.map(x => 'LBA' + x).join(' ')} · 备份: ${r.backup_path}`
      : '✗ ' + (r.error || '未知错误');
  } catch (e) {
    $('#convert-status').textContent = '✗ ' + e;
  }
  $('#btn-convert-apply').disabled = false;
});

function readSizeGb() {
  const v = parseFloat($('#convert-size').value);
  return isNaN(v) ? null : v;
}

/* ── 备份管理: 列表 + 匹配校验 + 安全还原 ── */
$('#btn-backup-refresh').addEventListener('click', loadBackups);

async function loadBackups() {
  const body = $('#backup-list');
  const status = $('#backup-status');
  if (!currentDisk) {
    body.innerHTML = '<tr><td colspan="6" class="dim">请先选择 U 盘</td></tr>';
    status.textContent = '选择 U 盘后加载备份…';
    return;
  }
  status.textContent = `读取 disk${currentDisk} 的可用备份…`;
  try {
    const rows = await invoke('list_backups', { diskNo: currentDisk });
    body.innerHTML = '';
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="6" class="dim">尚无 EDPOpen 备份</td></tr>';
      status.textContent = '0 个备份';
      return;
    }
    for (const b of rows) {
      const tr = document.createElement('tr');
      const name = document.createElement('td');
      name.textContent = b.file_name;
      name.title = b.path;
      const size = document.createElement('td');
      size.textContent = `${b.size_bytes} B`;
      const md5 = document.createElement('td');
      md5.textContent = b.md5_ok ? '通过' : '失败';
      md5.className = b.md5_ok ? 'backup-ok' : 'backup-bad';
      const lid = document.createElement('td');
      lid.textContent = b.lid == null ? '—' : String(b.lid);
      const match = document.createElement('td');
      match.textContent = b.current_match ? '匹配' : '不匹配';
      match.className = b.current_match ? 'backup-ok' : 'backup-bad';
      const action = document.createElement('td');
      const btn = document.createElement('button');
      btn.textContent = '还原';
      btn.disabled = !b.current_match;
      btn.title = b.current_match ? '还原该备份' : 'MD5 或 LBA4 唯一 ID 不匹配，禁止还原';
      btn.addEventListener('click', () => restoreBackupRecord(b, btn));
      action.appendChild(btn);
      tr.append(name, size, md5, lid, match, action);
      body.appendChild(tr);
    }
    const matched = rows.filter(x => x.current_match).length;
    status.textContent = `${rows.length} 个备份 · ${matched} 个匹配当前盘`;
  } catch (e) {
    body.innerHTML = '<tr><td colspan="6" class="backup-bad">加载失败</td></tr>';
    status.textContent = '错误: ' + e;
  }
}

async function restoreBackupRecord(b, button) {
  if (!currentDisk || !b.current_match) return;
  const ok = confirm(
    `确认把 ${b.file_name} 还原到 disk${currentDisk}?\n\n` +
    'EDPOpen 会先再次备份当前 LBA0-13，再申请读写授权并还原 5 个改造相关扇区。'
  );
  if (!ok) return;
  const status = $('#backup-status');
  button.disabled = true;
  status.textContent = '复核备份和当前盘身份，等待系统授权…';
  try {
    const r = await invoke('restore_backup', { diskNo: currentDisk, backupPath: b.path });
    status.textContent = r.ok
      ? `✓ 还原并回读通过 ${r.verified.map(x => 'LBA' + x).join(' ')} · 还原前安全备份: ${r.backup_path}`
      : '✗ ' + (r.error || '未知错误');
    await analyzeDisk(currentDisk);
    await loadDiskMap(currentDisk);
    await loadConvertPreview();
    await loadSector(+($('#sector-lba').value || 0));
    await loadBackups();
  } catch (e) {
    status.textContent = '✗ ' + e;
    button.disabled = false;
  }
}

async function loadConvertPreview() {
  if (!currentDisk) return;
  const box = $('#convert-preview');
  box.innerHTML = '<div class="dim">生成预览…</div>';
  try {
    const p = await invoke('convert_preview', { diskNo: currentDisk, sizeGb: readSizeGb() });
    const ok = p.convertible;
    box.innerHTML = `
      <div class="kv"><span class="k">状态</span><span class="v ${ok ? '' : 'dim'}">${p.status_label}${ok ? '' : ' — ' + p.reason}</span></div>
      ${ok ? `
      <div class="kv"><span class="k">布局</span><span class="v">Share @LBA63 × ${p.share.toLocaleString()} 扇 (${p.share_gb}) · Encrypt @LBA${p.enc_start.toLocaleString()} (${p.enc_size_gb}) 原样保留</span></div>
      <div class="kv"><span class="k">写入</span><span class="v">${p.sectors.map(x => 'LBA' + x).join(' · ')}${p.lba9_write ? ' (含 LBA9 清零)' : ' (LBA9 已零, 不写)'}</span></div>
      <div class="kv"><span class="k">备份</span><span class="v">写入前自动备份 LBA0-13 到 ~/Library/Application Support/EDPOpen/backups</span></div>` : ''}`;
    $('#btn-convert-apply').disabled = !ok;
  } catch (e) {
    box.innerHTML = `<div style="color:var(--danger)">${e}</div>`;
    $('#btn-convert-apply').disabled = true;
  }
}

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
