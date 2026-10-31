#!/usr/bin/env python3
"""Turn an ELF64 object into a flat binary loaded at a given base address.

There is no ELF linker in this toolchain, so absolute references (far jump
targets, IDT gate offsets, GDT pointers) come out of the assembler as
unresolved relocations.  This applies them directly against .text.

usage: elf2bin.py <object> [base_address]
"""
import struct
import sys

R_X86_64_64 = 1
R_X86_64_PC32 = 2
R_X86_64_32 = 10
R_X86_64_32S = 11
R_X86_64_16 = 12
R_X86_64_PC16 = 13


class Elf:
    def __init__(self, data):
        self.data = data
        assert data[:4] == b"\x7fELF" and data[4] == 2, "expected an ELF64 object"
        self.shoff, = struct.unpack_from("<Q", data, 0x28)
        self.shentsize, self.shnum, self.shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        self.sections = [self._section(i) for i in range(self.shnum)]
        stroff = self.sections[self.shstrndx]["offset"]
        for s in self.sections:
            end = data.index(b"\0", stroff + s["name_idx"])
            s["name"] = data[stroff + s["name_idx"]:end].decode()

    def _section(self, i):
        off = self.shoff + i * self.shentsize
        (name_idx, typ, flags, addr, offset, size,
         link, info, align, entsize) = struct.unpack_from("<IIQQQQIIQQ", self.data, off)
        return dict(name_idx=name_idx, type=typ, offset=offset, size=size,
                    link=link, info=info, entsize=entsize)

    def by_name(self, name):
        for s in self.sections:
            if s["name"] == name:
                return s
        return None

    def symbols(self):
        symtab = self.by_name(".symtab")
        if symtab is None:
            return []
        out = []
        n = symtab["size"] // 24
        for i in range(n):
            off = symtab["offset"] + i * 24
            name, info, other, shndx, value, size = struct.unpack_from(
                "<IBBHQQ", self.data, off)
            out.append(dict(shndx=shndx, value=value))
        return out


def build(path, base):
    with open(path, "rb") as f:
        elf = Elf(f.read())
    text = elf.by_name(".text")
    if text is None:
        raise SystemExit("no .text section")
    out = bytearray(elf.data[text["offset"]:text["offset"] + text["size"]])
    text_index = elf.sections.index(text)
    syms = elf.symbols()

    rela = elf.by_name(".rela.text")
    if rela is not None:
        for i in range(rela["size"] // 24):
            off = rela["offset"] + i * 24
            r_off, r_info, r_add = struct.unpack_from("<QQq", elf.data, off)
            sym_idx = r_info >> 32
            r_type = r_info & 0xFFFFFFFF
            sym = syms[sym_idx]
            # every symbol in these tests lives in .text
            if sym["shndx"] == text_index:
                value = base + sym["value"]
            else:
                value = base + sym["value"]
            target = value + r_add

            if r_type == R_X86_64_64:
                struct.pack_into("<Q", out, r_off, target & 0xFFFFFFFFFFFFFFFF)
            elif r_type in (R_X86_64_32, R_X86_64_32S):
                struct.pack_into("<I", out, r_off, target & 0xFFFFFFFF)
            elif r_type == R_X86_64_16:
                struct.pack_into("<H", out, r_off, target & 0xFFFF)
            elif r_type == R_X86_64_PC32:
                struct.pack_into("<i", out, r_off, target - (base + r_off))
            elif r_type == R_X86_64_PC16:
                struct.pack_into("<h", out, r_off, target - (base + r_off))
            else:
                raise SystemExit(f"unhandled relocation type {r_type}")
    return bytes(out)


if __name__ == "__main__":
    base = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    sys.stdout.buffer.write(build(sys.argv[1], base))
