// ---------------------------------------------------------------------------
//  Disk images.
//
//  A Disk is a geometry plus a BlockStore.  The store decides where the bytes
//  actually live, which is what keeps image size and disk size unbounded:
//
//    MemoryStore  a Uint8Array already in hand (small images)
//    SparseStore  chunks allocated on first write (the RAM hard drive)
//    ChunkStore   a source read in pieces on demand (huge files)
//
//  readSync may return null to mean "not resident yet".  The BIOS treats that
//  as "retry": it rewinds the guest past the INT instruction so the same call
//  happens again once the chunk has landed.  That is how an asynchronous source
//  is serviced from inside a synchronous BIOS call.
// ---------------------------------------------------------------------------

/**
 * Returned when a read needs bytes that have not arrived yet.  This has to be
 * distinguishable from "not present": treating a pending chunk as absence is
 * how an image whose boot catalog sits past the first chunk gets reported as
 * unbootable.
 */
export const NEED_DATA = Symbol('need-data');

export const DISK_FLOPPY = 'floppy';
export const DISK_HDD = 'hdd';
export const DISK_CDROM = 'cdrom';

const FLOPPY_GEOMETRY = new Map([
  [360 * 1024,  { c: 40, h: 2, s: 9,  type: 1 }],
  [720 * 1024,  { c: 80, h: 2, s: 9,  type: 3 }],
  [1200 * 1024, { c: 80, h: 2, s: 15, type: 2 }],
  [1440 * 1024, { c: 80, h: 2, s: 18, type: 4 }],
  [2880 * 1024, { c: 80, h: 2, s: 36, type: 5 }],
]);

// ---------------------------------------------------------------------------
//  stores
// ---------------------------------------------------------------------------

export class MemoryStore {
  constructor(data) { this.data = data; this.writable = true; }
  get size() { return this.data.length; }
  readSync(off, len) {
    if (off + len > this.data.length) return undefined;   // past the end
    return this.data.subarray(off, off + len);
  }
  write(off, bytes) {
    if (off + bytes.length > this.data.length) return false;
    this.data.set(bytes, off);
    return true;
  }
  export() { return this.data; }
}

/**
 * A disk made of chunks allocated on first write.  An empty 64 GiB drive costs
 * nothing until the guest starts using it, and unwritten regions read as zero,
 * which is exactly what a freshly manufactured disk looks like.
 */
export class SparseStore {
  constructor(sizeBytes, chunkBits = 20) {          // 1 MiB chunks
    this.sizeBytes = sizeBytes;
    this.chunkBits = chunkBits;
    this.chunkSize = 1 << chunkBits;
    this.chunks = new Map();
    this.writable = true;
    this.zero = new Uint8Array(this.chunkSize);
  }

  get size() { return this.sizeBytes; }

  // Division rather than >>>, which takes its operand modulo 2^32: on a disk
  // past 4 GiB the far sectors aliased the first ones.
  indexOf(off) { return Math.floor(off / this.chunkSize); }

  /** Bytes actually committed so far. */
  get allocated() { return this.chunks.size * this.chunkSize; }

  chunkFor(index, create) {
    let c = this.chunks.get(index);
    if (!c && create) {
      c = new Uint8Array(this.chunkSize);
      this.chunks.set(index, c);
    }
    return c;
  }

  readSync(off, len) {
    if (off + len > this.sizeBytes) return undefined;
    const first = this.indexOf(off);
    const last = this.indexOf(off + len - 1);
    // fast path: entirely inside one allocated chunk
    if (first === last) {
      const c = this.chunks.get(first);
      const start = off - first * this.chunkSize;
      if (!c) return this.zero.subarray(0, len);
      return c.subarray(start, start + len);
    }
    const out = new Uint8Array(len);
    let done = 0;
    while (done < len) {
      const pos = off + done;
      const idx = this.indexOf(pos);
      const start = pos - idx * this.chunkSize;
      const n = Math.min(this.chunkSize - start, len - done);
      const c = this.chunks.get(idx);
      if (c) out.set(c.subarray(start, start + n), done);
      done += n;
    }
    return out;
  }

  write(off, bytes) {
    if (off + bytes.length > this.sizeBytes) return false;
    let done = 0;
    while (done < bytes.length) {
      const pos = off + done;
      const idx = this.indexOf(pos);
      const start = pos - idx * this.chunkSize;
      const n = Math.min(this.chunkSize - start, bytes.length - done);
      this.chunkFor(idx, true).set(bytes.subarray(done, done + n), start);
      done += n;
    }
    return true;
  }

  /** Flatten to a single image.  Only sensible for modest disks. */
  export() {
    const out = new Uint8Array(this.sizeBytes);
    for (const [idx, c] of this.chunks) out.set(c, idx * this.chunkSize);
    return out;
  }
}

/**
 * A store fed in pieces by a source, for images too large to hold in memory.
 *
 * `fetch(offset, length)` either returns bytes synchronously (Node's readSync)
 * or a promise (a browser File slice).  Promised chunks are cached and the
 * caller is told to retry.
 */
export class ChunkStore {
  constructor(size, fetch, { chunkBits = 20, cacheChunks = 256, writable = false } = {}) {
    this.sizeBytes = size;
    this.fetch = fetch;
    this.chunkBits = chunkBits;
    this.chunkSize = 1 << chunkBits;
    this.cacheLimit = cacheChunks;
    this.cache = new Map();          // index -> Uint8Array
    this.inflight = new Map();       // index -> Promise, fetches in progress
    this.overlay = new Map();        // index -> Uint8Array, written chunks
    this.writable = writable;
    this.misses = 0;
    this.readahead = 2;              // chunks to pull in behind a miss
  }

  get size() { return this.sizeBytes; }

  indexOf(off) { return Math.floor(off / this.chunkSize); }   // see SparseStore

  /**
   * A promise for every fetch currently in progress, or null when nothing is
   * outstanding.  The host awaits this instead of spinning the guest.
   */
  whenReady() {
    if (!this.inflight.size) return null;
    return Promise.all([...this.inflight.values()]);
  }

  /** Resolve once the bytes at [off, off+len) are resident. */
  ensure(off, len) {
    const first = this.indexOf(off);
    const last = this.indexOf(off + len - 1);
    for (let i = first; i <= last; i++) this.prefetch(i);
    return this.whenReady() ?? Promise.resolve();
  }

  /** Start a fetch without waiting for it; used for readahead. */
  prefetch(index) {
    const off = index * this.chunkSize;
    if (off >= this.sizeBytes) return;
    if (this.cache.has(index) || this.overlay.has(index) ||
        this.inflight.has(index)) return;
    this.start(index);
  }

  start(index) {
    const off = index * this.chunkSize;
    const len = Math.min(this.chunkSize, this.sizeBytes - off);
    const r = this.fetch(off, len);
    if (r && typeof r.then === 'function') {
      this.misses++;
      const p = r.then((bytes) => {
        this.inflight.delete(index);
        this.store(index, bytes);
      }, () => this.inflight.delete(index));
      this.inflight.set(index, p);
      return null;
    }
    this.store(index, r);
    return r;
  }

  chunk(index) {
    if (this.overlay.has(index)) return this.overlay.get(index);
    const hit = this.cache.get(index);
    if (hit) {
      // refresh LRU position
      this.cache.delete(index);
      this.cache.set(index, hit);
      return hit;
    }
    if (this.inflight.has(index)) return null;

    const r = this.start(index);
    // Boot loaders read forward, so pull the next chunks in behind this one;
    // otherwise every sequential read costs a fresh round trip.
    for (let i = 1; i <= this.readahead; i++) this.prefetch(index + i);
    return r;
  }

  store(index, bytes) {
    this.cache.set(index, bytes);
    while (this.cache.size > this.cacheLimit) {
      const oldest = this.cache.keys().next().value;
      this.cache.delete(oldest);
    }
  }

  readSync(off, len) {
    if (off + len > this.sizeBytes) return undefined;
    // An empty read at offset zero once made `last` -1 >>> 20, ie. 4095:
    // every chunk of the image was fetched, more than the cache holds, so the
    // read could never complete and the guest retried it forever.
    if (len <= 0) return new Uint8Array(0);
    const first = this.indexOf(off);
    const last = this.indexOf(off + len - 1);
    // Touch every chunk first so one retry brings in all of them.
    let ready = true;
    for (let i = first; i <= last; i++) if (!this.chunk(i)) ready = false;
    if (!ready) return null;

    if (first === last) {
      const c = this.chunk(first);
      const start = off - first * this.chunkSize;
      return c.subarray(start, start + len);
    }
    const out = new Uint8Array(len);
    let done = 0;
    while (done < len) {
      const pos = off + done;
      const idx = this.indexOf(pos);
      const start = pos - idx * this.chunkSize;
      const n = Math.min(this.chunkSize - start, len - done);
      out.set(this.chunk(idx).subarray(start, start + n), done);
      done += n;
    }
    return out;
  }

  // Writes land in an overlay so the backing file is never modified.  A chunk
  // not yet resident has to be fetched before it can be copied into the
  // overlay; then the write reports NEED_DATA, having changed nothing, and the
  // caller tries again once the chunk has arrived.
  write(off, bytes) {
    if (!this.writable) return false;
    if (off + bytes.length > this.sizeBytes) return false;
    if (!bytes.length) return true;
    let ready = true;
    for (let i = this.indexOf(off); i <= this.indexOf(off + bytes.length - 1); i++) {
      if (!this.overlay.has(i) && !this.chunk(i)) ready = false;
    }
    if (!ready) return NEED_DATA;
    let done = 0;
    while (done < bytes.length) {
      const pos = off + done;
      const idx = this.indexOf(pos);
      const start = pos - idx * this.chunkSize;
      const n = Math.min(this.chunkSize - start, bytes.length - done);
      let c = this.overlay.get(idx);
      if (!c) {
        const base = this.chunk(idx);
        c = new Uint8Array(this.chunkSize);
        c.set(base);
        this.overlay.set(idx, c);
      }
      c.set(bytes.subarray(done, done + n), start);
      done += n;
    }
    return true;
  }
}

/**
 * Back a store with a browser File.  Slices are read asynchronously and cached,
 * so a 40 GB image costs only the cache.  The BIOS retry path covers the gap
 * between a miss and the bytes arriving.
 */
export function fileStore(file, opts = {}) {
  return new ChunkStore(
    file.size,
    (off, len) => file.slice(off, off + len).arrayBuffer()
                      .then((b) => new Uint8Array(b)),
    { writable: true, ...opts });
}

// ---------------------------------------------------------------------------
//  Disk
// ---------------------------------------------------------------------------

export class Disk {
  /**
   * @param {object} store  a BlockStore
   * @param {string} kind   DISK_* or 'auto'
   * @param {string} name
   */
  constructor(store, kind = 'auto', name = 'disk') {
    this.store = store;
    this.name = name;
    this.kind = kind === 'auto' ? Disk.detect(store) : kind;
    this.sectorSize = this.kind === DISK_CDROM ? 2048 : 512;
    this.geometry = this.computeGeometry();
    this.driveNumber = 0;
    // Read accounting, so the host can say whether a guest is still pulling
    // data off this drive.  A boot that has gone quiet and one that is slowly
    // working through an install image look identical from the outside
    // otherwise.
    this.reads = 0;          // read calls that returned data
    this.bytesRead = 0;
    this.pendingReads = 0;   // calls that had to be retried, ie. not resident
    this.lastLba = -1;       // where the guest last looked, which shows progress
  }

  static fromBytes(data, kind = 'auto', name = 'disk') {
    return new Disk(new MemoryStore(data), kind, name);
  }

  /** A blank writable drive of the requested size, costing nothing until used. */
  static ramDisk(sizeBytes, name = 'ramdisk') {
    return new Disk(new SparseStore(sizeBytes), DISK_HDD, name);
  }

  static detect(store) {
    // An ISO 9660 image carries "CD001" at the start of sector 16 of 2048 bytes.
    const head = store.readSync(16 * 2048 + 1, 5);
    if (head && head.length === 5) {
      const tag = String.fromCharCode(...head);
      if (tag === 'CD001') return DISK_CDROM;
    }
    if (FLOPPY_GEOMETRY.has(store.size)) return DISK_FLOPPY;
    return DISK_HDD;
  }

  get writable() { return this.store.writable === true; }

  computeGeometry() {
    if (this.kind === DISK_CDROM) return { c: 0, h: 0, s: 0, type: 0 };
    const known = FLOPPY_GEOMETRY.get(this.store.size);
    if (known && this.kind === DISK_FLOPPY) return known;
    const total = Math.floor(this.store.size / 512);
    const h = 255, s = 63;
    return { c: Math.max(1, Math.min(1024, Math.floor(total / (h * s)))), h, s, type: 3 };
  }

  get sectorCount() { return Math.floor(this.store.size / this.sectorSize); }

  chsToLba(c, h, s) {
    const g = this.geometry;
    return (c * g.h + h) * g.s + (s - 1);
  }

  /**
   * @returns {Uint8Array}  the sectors
   * @returns {null}        not resident yet, retry
   * @returns {undefined}   past the end of the disk
   */
  read(lba, count) {
    const got = this.store.readSync(lba * this.sectorSize, count * this.sectorSize);
    if (got == null) this.pendingReads++;
    else if (got !== undefined) {
      this.reads++;
      this.bytesRead += got.length;
      this.lastLba = lba;
    }
    return got;
  }

  write(lba, bytes) {
    if (!this.writable) return false;
    return this.store.write(lba * this.sectorSize, bytes);
  }

  /** Bytes committed, for disks that allocate lazily. */
  get allocated() {
    return this.store.allocated ?? this.store.size;
  }
}

/**
 * A read-only window onto part of another store.
 *
 * An El Torito boot image lives inside the CD, but the guest addresses it as a
 * disk of its own starting at sector zero, so the offset has to be hidden.
 */
export class SliceStore {
  constructor(base, offset, size) {
    this.base = base;
    this.offset = offset;
    this.sizeBytes = size;
    this.writable = false;
  }

  get size() { return this.sizeBytes; }
  get allocated() { return this.sizeBytes; }

  // null (not resident yet) is passed straight through so the caller retries
  readSync(off, len) {
    if (off + len > this.sizeBytes) return undefined;
    return this.base.readSync(this.offset + off, len);
  }

  write() { return false; }
}

// ---------------------------------------------------------------------------
//  El Torito
// ---------------------------------------------------------------------------
export function parseElTorito(disk) {
  if (disk.kind !== DISK_CDROM) return null;
  const brvd = disk.store.readSync(17 * 2048, 2048);
  if (brvd === null) return NEED_DATA;
  if (!brvd || brvd.length < 2048) return null;
  if (brvd[0] !== 0) return null;
  const id = String.fromCharCode(...brvd.subarray(1, 6));
  const spec = String.fromCharCode(...brvd.subarray(7, 30)).replace(/\0+$/, '');
  if (id !== 'CD001' || !spec.startsWith('EL TORITO SPECIFICATION')) return null;

  const dv0 = new DataView(brvd.buffer, brvd.byteOffset, brvd.byteLength);
  const catalogLba = dv0.getUint32(0x47, true);

  // The catalog can live anywhere on the disc, so this is the read that most
  // often lands outside whatever has been fetched so far.
  const cat = disk.store.readSync(catalogLba * 2048, 2048);
  if (cat === null) return NEED_DATA;
  if (!cat || cat[0] !== 0x01) return null;
  const dv = new DataView(cat.buffer, cat.byteOffset, cat.byteLength);

  const e = 32;                               // default (initial) entry
  if (cat[e] !== 0x88) return null;           // 0x88 = bootable
  return {
    mediaType: cat[e + 1] & 0x0f,
    loadSegment: dv.getUint16(e + 2, true) || 0x07c0,
    sectorCount: dv.getUint16(e + 6, true),   // in 512-byte virtual sectors
    imageLba: dv.getUint32(e + 8, true),
    catalogLba,
  };
}

export const ELTORITO_MEDIA = {
  0: 'no-emulation',
  1: '1.2M floppy',
  2: '1.44M floppy',
  3: '2.88M floppy',
  4: 'hard disk',
};
