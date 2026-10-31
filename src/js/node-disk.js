// ---------------------------------------------------------------------------
//  Node-only disk sources.  Kept out of disk.js so that module stays loadable
//  in a browser.
// ---------------------------------------------------------------------------

import { openSync, fstatSync, readSync, closeSync } from 'node:fs';
import { basename } from 'node:path';
import { ChunkStore, Disk } from './disk.js';

/**
 * A store that reads straight from a file on demand.  Nothing is held in
 * memory beyond the chunk cache, so image size is bounded by the filesystem
 * rather than by the heap.
 */
export function nodeFileStore(path, opts = {}) {
  const fd = openSync(path, 'r');
  const size = Number(fstatSync(fd).size);
  const store = new ChunkStore(size, (off, len) => {
    const buf = Buffer.allocUnsafe(len);
    let done = 0;
    while (done < len) {
      const n = readSync(fd, buf, done, len - done, off + done);
      if (n <= 0) break;
      done += n;
    }
    return new Uint8Array(buf.buffer, buf.byteOffset, done);
  }, { writable: true, ...opts });
  store.close = () => closeSync(fd);
  return store;
}

/** Open an image file as a Disk without reading it into memory. */
export function openDisk(path, kind = 'auto') {
  return new Disk(nodeFileStore(path), kind, basename(path));
}
