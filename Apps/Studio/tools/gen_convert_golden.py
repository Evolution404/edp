#!/usr/bin/env python3
"""gen_convert_golden.py — 用 nopwd.py 生成 6 盘免密改造产物金标准 convert_golden.json

Rust convert 的 5 扇输出与此文件逐字节比对(等价于 nopwd.py --dir --out 产物)。
"""
import argparse, glob, json, os, re, sys, tempfile

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nopwd', required=True)
    ap.add_argument('--backup', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    sys.path.insert(0, os.path.dirname(os.path.abspath(args.nopwd)))
    import nopwd

    disks = []
    for f in sorted(glob.glob(os.path.join(args.backup, '*.bin'))):
        name = os.path.basename(f)
        m = re.match(r'disk\d+_(\d+)_vid([0-9a-f]{4})_pid([0-9a-f]{4})_(.+?)_lid(\d+)_(\d{8}_\d{6})\.bin', name)
        if not m:
            continue
        device_id = m.group(4)
        data = open(f, 'rb').read()
        # 拆成快照目录喂给 nopwd.convert (与 --dir 等价, 免 CLI)
        snap = tempfile.mkdtemp(prefix='snap_')
        for lba in range(14):
            open(os.path.join(snap, f'LBA{lba:02d}.bin'), 'wb').write(data[lba*512:(lba+1)*512])
        read_fn = lambda lba, _s=snap: open(os.path.join(_s, f'LBA{lba:02d}.bin'), 'rb').read()
        try:
            r = nopwd.convert(read_fn, device_id, None, verbose=False)
            disks.append({
                'name': name, 'device_id': device_id,
                'raw0': read_fn(0).hex(),
                'crc32': f'{r["crc"]:08X}', 'k0': f'{r["k0"]:04X}',
                'share': r['share'], 'enc_start': r['enc_start'], 'enc_size': r['enc_size'],
                'lba0': r['lba0'].hex(), 'lba6': r['lba6'].hex(), 'lba7': r['lba7'].hex(),
                'lba12': r['lba12'].hex(),
                'lba9': r['lba9'].hex() if r['lba9'] else None,
            })
            print(f'✓ {name}')
        except SystemExit as e:
            print(f'✗ {name}: {e} (跳过)')
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump({'disks': disks}, open(args.out, 'w'))
    print(f'{len(disks)} 盘 → {args.out}')

if __name__ == '__main__':
    main()
