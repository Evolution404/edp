#!/usr/bin/env python3
"""gen_vectors.py — 从 nopwd_tool 备份生成 Rust 单测向量 vectors.json

用法: python3 tools/gen_vectors.py --nopwd <nopwd.py路径> --backup <backup目录> \
                                 --out src-tauri/tests/vectors.json

每盘产出 LBA4/6/7/8/9/11/12 的 raw(密文)/dec(明文) 逐字节对 + 全部 key 参数,
Rust crypto/parser 单测吃同一份文件, 与 Python 版逐字节对拍。
vectors.json 已被 .gitignore 忽略(真实盘数据不入库), 由本脚本在本地再生成。
"""
import argparse, glob, json, os, re, struct, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nopwd', required=True, help='nopwd.py 路径')
    ap.add_argument('--read-metadata', required=True, help='read_metadata.py 路径(LBA4 解密)')
    ap.add_argument('--backup', required=True, help='backup 目录')
    ap.add_argument('--out', required=True, help='输出 vectors.json')
    args = ap.parse_args()

    sys.path.insert(0, os.path.dirname(os.path.abspath(args.nopwd)))
    import nopwd
    sys.path.insert(0, os.path.dirname(os.path.abspath(args.read_metadata)))
    import read_metadata as rm

    disks = []
    for f in sorted(glob.glob(os.path.join(args.backup, '*.bin'))):
        name = os.path.basename(f)
        m = re.match(r'disk(\d+)_(\d+)_vid([0-9a-f]{4})_pid([0-9a-f]{4})_(.+?)_lid(\d+)_(\d{8}_\d{6})\.bin', name)
        if not m:
            print(f'跳过(非规则命名): {name}')
            continue
        secs, vid, pid, device_id = int(m.group(2)), m.group(3), m.group(4), m.group(5)
        data = open(f, 'rb').read()
        assert len(data) == 14 * 512, f'{name}: 长度 {len(data)}'
        crc = nopwd.crc32_bare(device_id.encode())
        k0 = (crc & 0xFFFF) ^ (crc >> 16 & 0xFFFF)
        crc_key = struct.pack('<I', crc)
        size_bytes = secs * 512

        def sector(n): return data[n*512:(n+1)*512]
        S = {}
        # LBA4: 自带 serial 解密(read_metadata.lba4_decode 返回 (dec, serial))
        S['4'] = (sector(4), lambda r: rm.lba4_decode(r)[0])
        # LBA6: 固定 K0
        S['6'] = (sector(6), lambda r: nopwd.lba6_decode(r))
        # LBA7: K0(device_id)
        S['7'] = (sector(7), lambda r: nopwd.xor_rolling(r, k0))
        # LBA8: A6B0 前368B + 尾144零(read_metadata 口径)
        S['8'] = (sector(8), lambda r: nopwd.a6b0_full(r[:368], crc_key, 0) + bytes(144))
        # LBA9: A6B0(128) + 零(128) + XOR0x88(32) + 零(224)
        S['9'] = (sector(9), lambda r: nopwd.a6b0_full(r[:128], crc_key, 0) + bytes(128)
                  + bytes(b ^ 0x88 for b in r[256:288]) + bytes(224))
        # LBA11: 双口径
        rand, cipher = sector(11)[:256], sector(11)[256:512]
        chs = (size_bytes // (255*63*512)) * 255*63*512
        l11_key = l11_label = l11_dec = None
        for sz, label in ((size_bytes, 'DiskSize'), (chs, 'CHS')):
            buf = rand + vid.encode().ljust(4, b'\0') + pid.encode().ljust(4, b'\0') + struct.pack('<Q', sz)
            k = struct.pack('<I', nopwd.crc32_bare(buf))
            pt = nopwd.a6b0_full(cipher, k, 0)
            if pt[:4] == b'PDKB':
                l11_key, l11_label = k.hex(), label
                l11_dec = rand + pt
                break
        S['11'] = (sector(11), (lambda r: l11_dec) if l11_dec else None)
        # LBA12: A6B0 前368B + 尾144B raw 原样
        S['12'] = (sector(12), lambda r: nopwd.a6b0_full(r[:368], crc_key, 0) + r[368:512])

        entry = {
            'name': name, 'device_id': device_id,
            'crc32': f'{crc:08X}', 'lba7_k0': f'{k0:04X}',
            'vid': vid, 'pid': pid, 'size_bytes': size_bytes,
            'lba11_key': l11_key, 'lba11_size_label': l11_label,
            'sectors': {},
        }
        for lba, (raw, fn) in S.items():
            entry['sectors'][lba] = {
                'raw_hex': raw.hex(),
                'dec_hex': fn(raw).hex() if fn else None,
            }
        if entry['sectors']['11']['dec_hex'] is None:
            print(f'警告: {name} LBA11 双口径均失败')
        disks.append(entry)
        print(f'✓ {name}: LBA11={l11_label or "失败"}')

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump({'disks': disks}, open(args.out, 'w'))
    print(f'\n{len(disks)} 盘 → {args.out}')

if __name__ == '__main__':
    main()
