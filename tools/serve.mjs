// Development server that refuses to let anything be cached.
//
// The emulator is a graph of ES modules plus a wasm core.  A browser caching
// some of those and revalidating others leaves a mixture of old and new code,
// which presents as a pile of unrelated breakage.  python -m http.server does
// not send cache headers, so this does.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..');
const port = Number(process.argv[2] || 8000);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
};

createServer(async (req, res) => {
  try {
    const rel = normalize(decodeURIComponent(req.url.split('?')[0]))
      .replace(/^(\.\.[/\\])+/, '');
    let path = join(root, rel === '/' ? 'index.html' : rel);
    if ((await stat(path)).isDirectory()) path = join(path, 'index.html');
    const body = await readFile(path);
    res.writeHead(200, {
      'Content-Type': TYPES[extname(path)] ?? 'application/octet-stream',
      'Content-Length': body.length,
      'Cache-Control': 'no-store, must-revalidate',
      'Pragma': 'no-cache',
    });
    res.end(body);
  } catch {
    res.writeHead(404, { 'Cache-Control': 'no-store' });
    res.end('not found');
  }
}).listen(port, () => {
  console.log(`x64emu dev server on http://localhost:${port}  (caching disabled)`);
});
