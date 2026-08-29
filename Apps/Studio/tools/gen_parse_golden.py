#!/usr/bin/env python3
"""gen_parse_golden.py — 用 read_metadata/nopwd 生成 6 盘解析金标准 parse_golden.json

Rust parser 的 lba4_fields/lba6_fields/EDPF/parse_elabel 输出与此文件比对。
"""
import argparse, glob, json, os, struct, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nopwd', required=True)
    ap.add_argument('--read-metadata', required=True)
    ap.add_argument('--backup', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    sys.path.insert(0, os.path.dirname(os.path.abspath(args.nopwd)))
    import nopwd
    sys.path.insert(0, os.path.dirname(os.path.abspath(args.read_metadata)))
    import read_metadata as rm

    out = []
    for f in sorted(glob.glob(os.path.join(args.backup, '*.bin'))):
        import re
        m = re.match(r'disk\d+_(\d+)_vid([0-9a-f]{4})_pid([0-9a-f]{4})_(.+?)_lid(\d+)_(\d{8}_\d{6})\.bin', os.path.basename(f))
        if not m: continue
        device_id = m.group(4)
        data = open(f, 'rb').read()
        sec = lambda n: data[n*512:(n+1)*512]
        crc = nopwd.crc32_bare(device_id.encode())
        k0 = (crc & 0xFFFF) ^ (crc >> 16 & 0xFFFF)
        crc_key = struct.pack('<I', crc)

        # LBA4
        dec4, serial = rm.lba4_decode(sec(4))
        # LBA6
        dec6 = nopwd.lba6_decode(sec(6))
        g = lambda off, ln: dec6[off:off+ln]
        nz = lambda b: b[:b.find(b'\x00')] if b.find(b'\x00') >= 0 else b
        def gbk(b):
            try: return b.decode('gbk')
            except: return b.decode('gbk', errors='replace')
        crc6 = struct.unpack_from('<I', dec6, 0x100)[0]
        crc6_l1 = struct.unpack_from('<I', dec6, 0x104)[0]
        safe6_at = dec6[0x188:0x1C0].find(b'!SAFE6')
        # LBA8 ELABEL
        dec8 = nopwd.a6b0_full(sec(8)[:368], crc_key, 0) + bytes(144)
        elabel = [{'tag': t, 'kvs': kvs} for t, kvs in rm.show_llgb(dec8)]
        # EDPF
        def entries(dec, stride):
            es = []
            for i in range(3):
                e = dec[i*stride:(i+1)*stride]
                if e[:4] != b'EDPF': break
                es.append({'type': struct.unpack_from('<I', e, 0x0c)[0],
                           'active': struct.unpack_from('<I', e, 0x10)[0],
                           'enc': struct.unpack_from('<I', e, 0x14)[0],
                           'start': struct.unpack_from('<Q', e, 0x18)[0],
                           'size': struct.unpack_from('<Q', e, 0x28)[0],
                           'pwd_crc': f'{struct.unpack_from("<I", e, 0x30)[0]:08X}'})
            return es
        dec7 = nopwd.xor_rolling(sec(7), k0)
        dec12 = nopwd.a6b0_full(sec(12)[:368], crc_key, 0) + sec(12)[368:]

        out.append({
            'name': os.path.basename(f), 'device_id': device_id,
            'lba4': {'serial': serial,
                     'xor8': f'{struct.unpack_from("<I", dec4, 0x18)[0]:08X}',
                     'second': f'{struct.unpack_from("<I", dec4, 0x1C)[0]:08X}',
                     'llgb': dec4[0x39:0x3D] == b'LLGB'},
            'lba6': {'label': gbk(nz(g(0, 64))), 'user': gbk(nz(g(0x50, 32))),
                     'serial_ascii': nz(g(0x70, 16)).decode('ascii', 'replace'),
                     'crc_ok': crc6 == crc, 'crc_l1_ok': crc6_l1 == ((crc << 1) & 0xFFFFFFFF),
                     'safe6': safe6_at >= 0,
                     'glab': nz(g(0x1C0, 8)).decode('ascii', 'replace'),
                     'flag_1f0': dec6[0x1F0],
                     'reg_1ca': struct.unpack_from('<H', dec6, 0x1CA)[0]},
            'lba8_elabel': elabel,
            'lba7_entries': entries(dec7, 0x40),
            'lba12_entries': entries(dec12, 0x60),
        })

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump({'disks': out}, open(args.out, 'w'), ensure_ascii=False, indent=1)
    print(f'{len(out)} 盘 → {args.out}')

if __name__ == '__main__':
    main()
