// A minimal WebAssembly binary encoder.
//
// The JIT has to produce modules while the guest is running, and wat2wasm is a
// build-time tool, so the bytes are assembled here by hand.  Only the subset the
// block compiler emits is implemented: there is no validation beyond what the
// engine itself does at compile time, and an unsupported construct is an
// outright throw rather than a silently wrong encoding.
//
// Everything is little-endian LEB128, which is the one part of the format worth
// stating explicitly: a signed and an unsigned LEB of the same small value are
// identical, so mixing them up stays invisible until a value crosses 0x40.

export const I32 = 0x7f;
export const I64 = 0x7e;

export function uleb(n) {
  if (typeof n === 'bigint') return ulebBig(n);
  const out = [];
  n >>>= 0;
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n !== 0) b |= 0x80;
    out.push(b);
  } while (n !== 0);
  return out;
}

function ulebBig(n) {
  const out = [];
  do {
    let b = Number(n & 0x7fn);
    n >>= 7n;
    if (n !== 0n) b |= 0x80;
    out.push(b);
  } while (n !== 0n);
  return out;
}

export function sleb(n) {
  const big = typeof n === 'bigint' ? n : BigInt(n);
  const out = [];
  let v = big;
  for (;;) {
    const b = Number(v & 0x7fn);
    v >>= 7n;                       // arithmetic shift: sign propagates
    // The terminating byte is the one whose sign bit already matches what the
    // remaining value would supply, which is what makes the encoding canonical.
    const done = (v === 0n && (b & 0x40) === 0) || (v === -1n && (b & 0x40) !== 0);
    out.push(done ? b : b | 0x80);
    if (done) return out;
  }
}

const vec = (items) => [...uleb(items.length), ...items.flat()];
const str = (s) => [...uleb(s.length), ...[...s].map((c) => c.charCodeAt(0))];

/** One function body under construction: a growable array of opcode bytes. */
export class Func {
  constructor(params = [], results = [], locals = []) {
    this.params = params;
    this.results = results;
    this.locals = locals;          // extra locals, beyond the parameters
    this.code = [];
    // Open structured blocks, so a branch can be aimed at a label by name
    // rather than by a depth worked out by hand at every site.
    this.depth = 0;
  }

  get localBase() { return this.params.length; }

  emit(...bytes) {
    const c = this.code;
    for (let i = 0; i < bytes.length; i++) c.push(bytes[i]);
    return this;
  }

  /** Add a local of the given type; returns its index. */
  addLocal(type) {
    this.locals.push(type);
    return this.params.length + this.locals.length - 1;
  }

  /** The current nesting depth, to be passed to brTo() later as a label. */
  label() { return this.depth; }
  /** Branch to a block opened when label() returned `l`. */
  brTo(l) { return this.br(this.depth - l - 1); }
  brIfTo(l) { return this.brIf(this.depth - l - 1); }

  // ---- constants and locals ---------------------------------------------
  // Constants are normalised into the signed range of their width first.
  // A guest value like 0xffffffffffffff88 arrives as a positive BigInt, and
  // encoding that as a signed LEB needs an eleventh byte the format does not
  // allow -- the engine rejects it as "extra bits in varint".  As a two's
  // complement negative it is two bytes.
  i32const(n) { return this.emit(0x41, ...sleb(BigInt.asIntN(32, BigInt(n)))); }
  i64const(n) { return this.emit(0x42, ...sleb(BigInt.asIntN(64, BigInt(n)))); }
  localGet(i) { return this.emit(0x20, ...uleb(i)); }
  localSet(i) { return this.emit(0x21, ...uleb(i)); }
  localTee(i) { return this.emit(0x22, ...uleb(i)); }

  // ---- calls -------------------------------------------------------------
  call(i) { return this.emit(0x10, ...uleb(i)); }

  // ---- memory ------------------------------------------------------------
  // Only memory 0 (the 32-bit state block) is addressed directly; guest RAM is
  // reached through core helpers so that segmentation and paging stay in one
  // place.  align is the log2 of the guaranteed alignment.
  load(op, align, offset) { return this.emit(op, ...uleb(align), ...uleb(offset)); }
  i32load(off, align = 2) { return this.load(0x28, align, off); }
  i64load(off, align = 3) { return this.load(0x29, align, off); }
  i32load8u(off) { return this.load(0x2d, 0, off); }
  i32load16u(off) { return this.load(0x2f, 1, off); }
  i32store(off, align = 2) { return this.load(0x36, align, off); }
  i64store(off, align = 3) { return this.load(0x37, align, off); }
  i32store8(off) { return this.load(0x3a, 0, off); }
  i32store16(off) { return this.load(0x3b, 1, off); }

  // ---- globals -----------------------------------------------------------
  // Imported mutable globals are how a compiled block reaches RIP and the
  // fault flag: a global.set is one instruction where a helper call would be a
  // function call on every single instruction boundary.
  globalGet(i) { return this.emit(0x23, ...uleb(i)); }
  globalSet(i) { return this.emit(0x24, ...uleb(i)); }

  // ---- arithmetic and comparison ----------------------------------------
  i32eqz() { return this.emit(0x45); }
  i32eq() { return this.emit(0x46); }
  i32ne() { return this.emit(0x47); }
  i32ltS() { return this.emit(0x48); }
  i32ltU() { return this.emit(0x49); }
  i32gtS() { return this.emit(0x4a); }
  i32gtU() { return this.emit(0x4b); }
  i32leU() { return this.emit(0x4d); }
  i32geU() { return this.emit(0x4f); }
  i32add() { return this.emit(0x6a); }
  i32sub() { return this.emit(0x6b); }
  i32and() { return this.emit(0x71); }
  i32or() { return this.emit(0x72); }
  i32xor() { return this.emit(0x73); }
  i32shl() { return this.emit(0x74); }
  i32shrU() { return this.emit(0x76); }
  i64eqz() { return this.emit(0x50); }
  i64eq() { return this.emit(0x51); }
  i64ne() { return this.emit(0x52); }
  i64ltS() { return this.emit(0x53); }
  i64ltU() { return this.emit(0x54); }
  i64gtS() { return this.emit(0x55); }
  i64gtU() { return this.emit(0x56); }
  i64leS() { return this.emit(0x57); }
  i64leU() { return this.emit(0x58); }
  i64geS() { return this.emit(0x59); }
  i64geU() { return this.emit(0x5a); }
  i64add() { return this.emit(0x7c); }
  i64sub() { return this.emit(0x7d); }
  i64mul() { return this.emit(0x7e); }
  i64and() { return this.emit(0x83); }
  i64or() { return this.emit(0x84); }
  i64xor() { return this.emit(0x85); }
  i64shl() { return this.emit(0x86); }
  i64shrS() { return this.emit(0x87); }
  i64shrU() { return this.emit(0x88); }
  i64extendI32u() { return this.emit(0xad); }
  i64extendI32s() { return this.emit(0xac); }
  i64extend8s() { return this.emit(0xc2); }
  i64extend16s() { return this.emit(0xc3); }
  i64extend32s() { return this.emit(0xc4); }
  i32wrapI64() { return this.emit(0xa7); }

  // ---- guest RAM ----------------------------------------------------------
  // Memory 1 is guest RAM, 64-bit indexed: the address operand is an i64, and
  // the memory index travels in the memarg, flagged by bit 6 of the alignment.
  ram(op, align, offset = 0) { return this.emit(op, align | 0x40, 1, ...uleb(offset)); }
  ramLoad(size) {                     // zero-extended to i64
    const op = { 1: 0x31, 2: 0x33, 4: 0x35, 8: 0x29 }[size];
    return this.ram(op, 0);
  }
  ramStore(size) {                    // stack: addr i64, value i64
    const op = { 1: 0x3c, 2: 0x3d, 4: 0x3e, 8: 0x37 }[size];
    return this.ram(op, 0);
  }
  i64load8u(off) { return this.load(0x31, 0, off); }
  i64load16u(off) { return this.load(0x33, 1, off); }
  i64load32u(off) { return this.load(0x35, 2, off); }
  i64store8(off) { return this.load(0x3c, 0, off); }
  i64store16(off) { return this.load(0x3d, 1, off); }
  i64store32(off) { return this.load(0x3e, 2, off); }

  // ---- control -----------------------------------------------------------
  // blocktype 0x40 is "no result"; a value type byte is used when the block
  // yields one.
  if_(blocktype = 0x40) { this.depth++; return this.emit(0x04, blocktype); }
  else_() { return this.emit(0x05); }
  end() { this.depth--; return this.emit(0x0b); }
  block(blocktype = 0x40) { this.depth++; return this.emit(0x02, blocktype); }
  loop(blocktype = 0x40) { this.depth++; return this.emit(0x03, blocktype); }
  select() { return this.emit(0x1b); }
  br(d) { return this.emit(0x0c, ...uleb(d)); }
  brIf(d) { return this.emit(0x0d, ...uleb(d)); }
  return_() { return this.emit(0x0f); }
  drop() { return this.emit(0x1a); }

  /** Encoded body: local declarations followed by the expression. */
  body() {
    // Runs of the same type are grouped, which is how the format wants them and
    // also keeps the body a few bytes smaller.
    const groups = [];
    for (const t of this.locals) {
      const last = groups[groups.length - 1];
      if (last && last[1] === t) last[0]++;
      else groups.push([1, t]);
    }
    const decl = vec(groups.map(([n, t]) => [...uleb(n), t]));
    const bytes = [...decl, ...this.code, 0x0b];
    return [...uleb(bytes.length), ...bytes];
  }
}

/**
 * Assemble a module.
 *
 * imports: [{ module, name, params, results }] for functions, in the order the
 * compiled code refers to them -- an imported function's index is its position
 * in this list, and defined functions are numbered after all of them.
 * memories: [{ module, name, min }] imported 32-bit memories.
 * funcs:   [{ name, fn }] exported functions.
 */
export function buildModule({ imports = [], memories = [], globals = [], funcs = [] }) {
  // The type section is deduplicated: every distinct signature appears once and
  // both imports and definitions index into it.
  const types = [];
  const typeIndex = (params, results) => {
    const key = `${params.join(',')}|${results.join(',')}`;
    let i = types.findIndex((t) => t.key === key);
    if (i < 0) { i = types.length; types.push({ key, params, results }); }
    return i;
  };
  const importTypes = imports.map((im) => typeIndex(im.params, im.results));
  const funcTypes = funcs.map((f) => typeIndex(f.fn.params, f.fn.results));

  const section = (id, payload) =>
    payload.length ? [id, ...uleb(payload.length), ...payload] : [];

  const typeSec = vec(types.map((t) => [0x60, ...vec(t.params.map((p) => [p])),
                                        ...vec(t.results.map((r) => [r]))]));

  // Each import kind has its own index space, numbered by the order its
  // entries appear among the imports -- so grouping them by kind here is what
  // makes "global 0" and "function 0" mean what the caller expects.
  // A 64-bit memory says so in its limits flags (0x04).
  const importSec = vec([
    ...memories.map((m) => [...str(m.module), ...str(m.name), 0x02,
                            m.index64 ? 0x04 : 0x00, ...uleb(m.min)]),
    ...globals.map((g) =>
      [...str(g.module), ...str(g.name), 0x03, g.type, g.mutable ? 0x01 : 0x00]),
    ...imports.map((im, i) => [...str(im.module), ...str(im.name), 0x00, ...uleb(importTypes[i])]),
  ]);

  const funcSec = vec(funcTypes.map((t) => uleb(t)));
  const exportSec = vec(funcs.map((f, i) =>
    [...str(f.name), 0x00, ...uleb(imports.length + i)]));
  const codeSec = vec(funcs.map((f) => f.fn.body()));

  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,   // magic, version 1
    ...section(1, typeSec),
    ...section(2, importSec),
    ...section(3, funcSec),
    ...section(7, exportSec),
    ...section(10, codeSec),
  ]);
}
