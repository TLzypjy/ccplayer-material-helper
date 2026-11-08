#!/usr/bin/env python3
"""Post-build patcher for CCMaterialGrid.dylib (run on CI before ldid signing):
1. arm64e slice cpusubtype 0x2 -> 0x80000002
2. arm64e __objc_data: convert isa/superclass entries to authenticated (objc ABI constants)
Then the workflow re-signs with ldid so code signature stays valid.
"""
import struct, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else '.theos/obj/CCMaterialGrid.dylib'
ISA_DIV = 0x6AE1
SC_DIV = 0xB5AB
KEY = 2
ADDR_DIV = 1

d = bytearray(open(PATH, 'rb').read())
assert d[:4] == b'\xca\xfe\xba\xbe', 'expect fat'
nfat = struct.unpack_from('>I', d, 4)[0]
patched = 0
for idx in range(nfat):
    cpu, sub, foff, fsize, align = struct.unpack_from('>IIIII', d, 8 + idx * 20)
    if (sub & 0xff) != 0x2:
        continue
    cur = struct.unpack_from('<I', d, foff + 8)[0]
    if cur != 0x80000002:
        struct.pack_into('<I', d, foff + 8, 0x80000002)
        struct.pack_into('>I', d, 8 + idx * 20 + 4, 0x80000002)
        print('slice %d: cpusubtype 0x%x -> 0x80000002' % (idx, cur))

    ncmds = struct.unpack_from('<I', d, foff + 16)[0]
    p = foff + 32
    data_va = data_size = None
    for k in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, p)
        if cmd == 0x19:
            nsects = struct.unpack_from('<I', d, p + 64)[0]
            so = p + 72
            for j in range(nsects):
                sname = bytes(d[so:so+16]).rstrip(b'\x00').decode()
                saddr, ssize = struct.unpack_from('<QQ', d, so + 32)
                if sname == '__objc_data':
                    data_va, data_size = saddr, ssize
                so += 80
        p += size
    assert data_va and data_size, 'no __objc_data'

    for i in range(data_size // 8):
        pair_off = (i * 8) % 0x50
        va = data_va + i * 8
        off = foff + va
        raw = struct.unpack_from('<Q', d, off)[0]
        if raw == 0:
            continue
        auth = (raw >> 63) & 1
        bind = (raw >> 62) & 1
        next_bits = (raw >> 51) & 0x7FF
        if auth == 1:
            continue
        if pair_off == 0x00 and bind == 0:
            target = raw & 0xFFFFFFFF
            new = target | (ISA_DIV << 32) | (ADDR_DIV << 48) | (KEY << 49) | (next_bits << 51) | (1 << 63)
            kind = 'isa'
        elif pair_off in (0x08, 0x28, 0x30) and bind == 1:
            ordinal = raw & 0xFFFF
            div = ISA_DIV if pair_off == 0x28 else SC_DIV
            new = ordinal | (div << 32) | (ADDR_DIV << 48) | (KEY << 49) | (next_bits << 51) | (1 << 62) | (1 << 63)
            kind = 'super'
        else:
            continue
        struct.pack_into('<Q', d, off, new)
        patched += 1
        print('  slot[%2d] %-6s patched' % (i, kind))

print('auth entries patched:', patched)
assert patched == 12, 'expected 12 auth entries'
open(PATH, 'wb').write(bytes(d))
print('patched file written:', PATH)
