// ---------------------------------------------------------------------------
//  ACPI tables.
//
//  Everything from Windows Vista onwards refuses to boot without these: there
//  has been no non-ACPI HAL since XP, so a machine that cannot answer "where is
//  the RSDP" is rejected outright with "the firmware (BIOS) is not ACPI
//  compatible".  TempleOS reads the MADT to count cores.
//
//  The tables are laid out as one blob and copied into the 0xE0000 region,
//  which sits in the option-ROM hole and is already outside the E820 map, so no
//  guest expects to allocate from it.  The RSDP has to live in 0xE0000-0xFFFFF
//  on a 16-byte boundary, which is where the OS scans for it.
//
//  There is no AML interpreter here and none is needed.  The DSDT carries a
//  precompiled AML body and the guest's own interpreter runs it.
//
//  The MADT describes the local APIC and one I/O APIC (src/js/apic.js), with
//  the PC's usual override sending ISA IRQ 0 to pin 2.  The 8259 pair is
//  still there behind them, so PCAT_COMPAT is set.
// ---------------------------------------------------------------------------

import { LAPIC_BASE, IOAPIC_BASE } from './apic.js';

const OEM_ID = 'X64EMU';
const OEM_TABLE = 'X64EMUPC';
const CREATOR = 'X64E';

/** Where the blob is copied, and where the RSDP therefore ends up. */
export const ACPI_BASE = 0xe0000;

/** I/O ports for the fixed hardware described by the FADT. */
export const PM_BASE = 0x600;

const sum = (bytes, from, to) => {
  let s = 0;
  for (let i = from; i < to; i++) s = (s + bytes[i]) & 0xff;
  return s;
};

function ascii(view, off, text, len) {
  for (let i = 0; i < len; i++) view.setUint8(off + i, i < text.length ? text.charCodeAt(i) : 0x20);
}

/** Standard 36-byte description header; the checksum is filled in later. */
function header(buf, signature, revision, tableId = OEM_TABLE) {
  const v = new DataView(buf.buffer, buf.byteOffset);
  ascii(v, 0, signature, 4);
  v.setUint32(4, buf.length, true);          // length
  v.setUint8(8, revision);
  v.setUint8(9, 0);                          // checksum, computed at the end
  ascii(v, 10, OEM_ID, 6);
  ascii(v, 16, tableId, 8);
  v.setUint32(24, 1, true);                  // OEM revision
  ascii(v, 28, CREATOR, 4);
  v.setUint32(32, 1, true);                  // creator revision
  return v;
}

function finish(buf) {
  buf[9] = 0;
  buf[9] = (0x100 - sum(buf, 0, buf.length)) & 0xff;
  return buf;
}

/** Generic address structure, as used by the 64-bit FADT fields. */
function gas(v, off, addr, byteWidth) {
  v.setUint8(off, addr ? 1 : 0);             // 1 = system I/O
  v.setUint8(off + 1, byteWidth * 8);
  v.setUint8(off + 2, 0);                    // bit offset
  v.setUint8(off + 3, byteWidth <= 4 ? byteWidth : 0);
  v.setBigUint64(off + 4, BigInt(addr), true);
}

// ---- DSDT ------------------------------------------------------------------
//  Hand-assembled AML.  Defined here: \_S5_, which is what an OS needs to
//  power the machine off, the PCI root bridge, and the 8042's keyboard and
//  mouse.
//
//      Name (\_S5_, Package (0x04) { 0x05, 0x05, 0x00, 0x00 })
//      Scope (\_SB) {
//          Device (PCI0) {
//              Name (_HID, EisaId ("PNP0A03"))
//              Name (_ADR, Zero)
//              Name (_UID, Zero)
//              Name (_CRS, ResourceTemplate () { ...buses, I/O, memory... })
//              Device (ISA_) {                       // the PIIX3 at 00:01.0
//                  Name (_ADR, 0x00010000)
//                  Device (KBD_) { Name (_HID, EisaId ("PNP0303"))  60h, 64h, IRQ 1 }
//                  Device (MOU_) { Name (_HID, EisaId ("PNP0F13"))  IRQ 12 }
//              }
//          }
//      }
//
//  Once ACPI is in use, Linux scans PCI only below a root bridge the DSDT
//  declares, so without PCI0 the bus is never looked at however it answers.
//  Windows with an ACPI HAL likewise finds legacy devices only here: without
//  KBD_ and MOU_ it never loaded its PS/2 driver, and its desktop came up
//  with no keyboard or mouse.  They have to sit below the ISA bridge, as on
//  real boards: declared directly under \_SB they were started before the
//  PCI root, and ACPI.sys called through an interrupt interface it did not
//  have yet (STOP 0x7E).

// PkgLength counts its own bytes as well as what follows them.
function pkgLength(n) {
  if (n + 1 < 0x40) return [n + 1];
  if (n + 2 < 0x1000) return [0x40 | ((n + 2) & 0x0f), (n + 2) >> 4];
  return [0x80 | ((n + 3) & 0x0f), ((n + 3) >> 4) & 0xff, (n + 3) >> 12];
}
const aml = {
  seg: (s) => [...s].map((c) => c.charCodeAt(0)),
  name: (s, data) => [0x08, ...aml.seg(s), ...data],
  scope: (path, body) => [0x10, ...pkgLength(path.length + body.length), ...path, ...body],
  device: (seg, body) => [0x5b, 0x82, ...pkgLength(4 + body.length), ...aml.seg(seg), ...body],
  buffer: (bytes) => {
    const size = [0x0b, bytes.length & 0xff, bytes.length >> 8];
    return [0x11, ...pkgLength(size.length + bytes.length), ...size, ...bytes];
  },
};
const le16 = (v) => [v & 0xff, (v >> 8) & 0xff];

// EisaId ("PNP0303"): three letters in five bits each, then the product number
function eisaId(id) {
  const c = (i) => id.charCodeAt(i) - 0x40;
  const vendor = (c(0) << 10) | (c(1) << 5) | c(2);
  const product = parseInt(id.slice(3), 16);
  return [0x0c, vendor >> 8, vendor & 0xff, product >> 8, product & 0xff];
}
const ioPort = (port, len) => [0x47, 0x01, ...le16(port), ...le16(port), 0x01, len];
const irq = (n) => [0x22, ...le16(1 << n)];
const END_TAG = [0x79, 0x00];
const le32 = (v) => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, v >>> 24];

// Address space descriptors the bridge produces: type 2 bus numbers, 1 I/O.
function wordSpace(type, min, max, typeFlags) {
  return [0x88, ...le16(13), type, 0x0c, typeFlags,
          ...le16(0), ...le16(min), ...le16(max), ...le16(0), ...le16(max - min + 1)];
}
function dwordMemory(min, max) {
  return [0x87, ...le16(23), 0x00, 0x0c, 0x01,
          ...le32(0), ...le32(min), ...le32(max), ...le32(0), ...le32(max - min + 1)];
}

function pciRootBridge(framebuffer) {
  const crs = [
    ...wordSpace(2, 0x0000, 0x00ff, 0x00),           // buses 0-255
    0x47, 0x01, ...le16(0xcf8), ...le16(0xcf8), 0x01, 0x08,   // its config ports
    ...wordSpace(1, 0x0000, 0x0cf7, 0x03),           // I/O either side of them
    ...wordSpace(1, 0x0d00, 0xffff, 0x03),
    ...dwordMemory(0x000a0000, 0x000bffff),          // the VGA window
    // The display adapter's framebuffer BAR sits at the top of RAM, where
    // its memory really is; the bridge has to claim that range too, or the
    // guest sees a BAR outside every window and moves it somewhere that is
    // not memory at all.
    ...(framebuffer ? dwordMemory(framebuffer.base, framebuffer.base + framebuffer.size - 1) : []),
    ...dwordMemory(0xc0000000, 0xfebfffff),          // and room for BARs
    ...END_TAG,
  ];
  return aml.device('PCI0', [
    ...aml.name('_HID', eisaId('PNP0A03')),
    ...aml.name('_ADR', [0x00]),
    ...aml.name('_UID', [0x00]),
    ...aml.name('_CRS', aml.buffer(crs)),
    ...aml.device('ISA_', [
      ...aml.name('_ADR', [0x0c, ...le32(0x00010000)]),
      ...ps2Devices(),
    ]),
  ]);
}

function ps2Devices() {
  return [
    ...aml.device('KBD_', [
      ...aml.name('_HID', eisaId('PNP0303')),
      ...aml.name('_CRS', aml.buffer([...ioPort(0x60, 1), ...ioPort(0x64, 1), ...irq(1), ...END_TAG])),
    ]),
    ...aml.device('MOU_', [
      ...aml.name('_HID', eisaId('PNP0F13')),
      ...aml.name('_CRS', aml.buffer([...irq(12), ...END_TAG])),
    ]),
  ];
}

function dsdtBody(framebuffer) {
  return Uint8Array.from([
    0x08,                                    // NameOp
    0x5c, 0x5f, 0x53, 0x35, 0x5f,            // \_S5_
    0x12,                                    // PackageOp
    0x08,                                    // PkgLength: 8 bytes follow
    0x04,                                    // 4 elements
    0x0a, 0x05,                              // PM1a SLP_TYP = 5
    0x0a, 0x05,                              // PM1b SLP_TYP = 5
    0x00, 0x00,                              // reserved
    ...aml.scope([0x5c, ...aml.seg('_SB_')], pciRootBridge(framebuffer)),
  ]);
}

// ---- table builders --------------------------------------------------------

function buildDsdt(framebuffer) {
  const body = dsdtBody(framebuffer);
  const buf = new Uint8Array(36 + body.length);
  header(buf, 'DSDT', 2, 'X64EMUDS');
  buf.set(body, 36);
  return finish(buf);
}

function buildFacs() {
  const buf = new Uint8Array(64);
  const v = new DataView(buf.buffer);
  ascii(v, 0, 'FACS', 4);
  v.setUint32(4, 64, true);                  // length; FACS carries no checksum
  return buf;
}

function buildFadt(facsAddr, dsdtAddr) {
  const buf = new Uint8Array(244);           // revision 3
  const v = header(buf, 'FACP', 3);
  v.setUint32(36, facsAddr, true);           // FIRMWARE_CTRL
  v.setUint32(40, dsdtAddr, true);           // DSDT
  v.setUint8(45, 0);                         // preferred PM profile: unspecified
  v.setUint16(46, 9, true);                  // SCI interrupt
  v.setUint32(48, 0, true);                  // SMI_CMD: no SMM, ACPI always on
  v.setUint8(52, 0);                         // ACPI_ENABLE
  v.setUint8(53, 0);                         // ACPI_DISABLE
  v.setUint32(56, PM_BASE, true);            // PM1a_EVT_BLK
  v.setUint32(64, PM_BASE + 4, true);        // PM1a_CNT_BLK
  v.setUint32(76, PM_BASE + 8, true);        // PM_TMR_BLK
  v.setUint8(88, 4);                         // PM1_EVT_LEN
  v.setUint8(89, 2);                         // PM1_CNT_LEN
  v.setUint8(91, 4);                         // PM_TMR_LEN
  v.setUint16(96, 0x0fff, true);             // P_LVL2_LAT: C2 not supported
  v.setUint16(98, 0x0fff, true);             // P_LVL3_LAT: C3 not supported
  v.setUint8(108, 0x32);                     // RTC century register in CMOS
  // legacy devices present, and an 8042 is present
  v.setUint16(109, 0x0003, true);            // IAPC_BOOT_ARCH
  // WBINVD is usable, C1 is supported, and the power and sleep buttons are
  // control-method devices rather than fixed hardware (there are none).
  v.setUint32(112, (1 << 0) | (1 << 2) | (1 << 4) | (1 << 5), true);
  v.setBigUint64(132, BigInt(facsAddr), true);   // X_FIRMWARE_CTRL
  v.setBigUint64(140, BigInt(dsdtAddr), true);   // X_DSDT
  gas(v, 148, PM_BASE, 4);                       // X_PM1a_EVT_BLK
  gas(v, 172, PM_BASE + 4, 2);                   // X_PM1a_CNT_BLK
  gas(v, 208, PM_BASE + 8, 4);                   // X_PM_TMR_BLK
  return finish(buf);
}

function buildMadt(cpuCount) {
  const entries = [];
  for (let i = 0; i < cpuCount; i++) {
    entries.push([0, 8, i, i, 1, 0, 0, 0]);  // processor local APIC: enabled
  }
  // the I/O APIC, its interrupt inputs starting at 0
  entries.push([1, 12, 1, 0, ...le32(IOAPIC_BASE), ...le32(0)]);
  // ISA IRQ 0 arrives on pin 2, as on every PC chipset
  entries.push([2, 10, 0, 0, ...le32(2), 0, 0]);
  // the SCI is level triggered, active high
  entries.push([2, 10, 0, 9, ...le32(9), 0x0d, 0]);
  // LINT1 of every processor is NMI
  entries.push([4, 6, 0xff, 0, 0, 1]);
  const body = entries.flat();
  const buf = new Uint8Array(44 + body.length);
  const v = header(buf, 'APIC', 3);
  v.setUint32(36, LAPIC_BASE, true);
  v.setUint32(40, 1, true);                  // PCAT_COMPAT: 8259 pair present
  buf.set(body, 44);
  return finish(buf);
}

function buildRsdt(addrs) {
  const buf = new Uint8Array(36 + addrs.length * 4);
  const v = header(buf, 'RSDT', 1);
  addrs.forEach((a, i) => v.setUint32(36 + i * 4, a, true));
  return finish(buf);
}

function buildXsdt(addrs) {
  const buf = new Uint8Array(36 + addrs.length * 8);
  const v = header(buf, 'XSDT', 1);
  addrs.forEach((a, i) => v.setBigUint64(36 + i * 8, BigInt(a), true));
  return finish(buf);
}

function buildRsdp(rsdtAddr, xsdtAddr) {
  const buf = new Uint8Array(36);
  const v = new DataView(buf.buffer);
  ascii(v, 0, 'RSD PTR ', 8);
  ascii(v, 9, OEM_ID, 6);
  v.setUint8(15, 2);                         // revision 2: XSDT is present
  v.setUint32(16, rsdtAddr, true);
  v.setUint32(20, 36, true);                 // length
  v.setBigUint64(24, BigInt(xsdtAddr), true);
  buf[8] = (0x100 - sum(buf, 0, 20)) & 0xff;         // ACPI 1.0 checksum
  buf[32] = (0x100 - sum(buf, 0, 36)) & 0xff;        // extended checksum
  return buf;
}

/**
 * Assemble every table into one blob meant to be copied to `base`.
 *
 * @returns {{bytes: Uint8Array, base: number, rsdp: number}}
 */
export function buildAcpiTables({ base = ACPI_BASE, cpuCount = 1, madt = true,
                                  framebuffer = null } = {}) {
  const parts = [];
  let off = 0;
  const place = (bytes, align = 16) => {
    off = (off + align - 1) & ~(align - 1);
    const at = off;
    parts.push({ at, bytes });
    off = at + bytes.length;
    return base + at;
  };

  // The RSDP goes first so it lands on the 16-byte boundary at `base`.
  const rsdpSlot = place(new Uint8Array(36));
  const facsAddr = place(buildFacs(), 64);   // the FACS wants 64-byte alignment
  const dsdtAddr = place(buildDsdt(framebuffer));
  const fadtAddr = place(buildFadt(facsAddr, dsdtAddr));
  const tables = [fadtAddr];
  if (madt) tables.push(place(buildMadt(cpuCount)));
  const rsdtAddr = place(buildRsdt(tables));
  const xsdtAddr = place(buildXsdt(tables));

  parts[0].bytes = buildRsdp(rsdtAddr, xsdtAddr);

  const bytes = new Uint8Array(off);
  for (const p of parts) bytes.set(p.bytes, p.at);
  return { bytes, base, rsdp: rsdpSlot };
}
