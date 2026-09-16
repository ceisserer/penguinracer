// Minimal static server for the Godot web export.
//
// Serves with COOP/COEP so a threads-enabled build would work too, and with the
// right MIME types for .wasm and .pck — get either wrong and the export fails
// with an opaque error in the console rather than anything actionable.
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = process.argv[2] || '.';
const port = parseInt(process.argv[3] || '8060', 10);

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream', '.png': 'image/png', '.json': 'application/json',
};

http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(root, url === '/' ? '/index.html' : url);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, {
      'Content-Type': types[path.extname(file)] || 'application/octet-stream',
      // Without this Node answers chunked, HTTPRequest.get_body_size() is -1,
      // and the loading screen's progress bar has no total to divide by — so
      // the harness would only ever exercise the no-Content-Length fallback,
      // which is not what a static host serving the real build does.
      'Content-Length': data.length,
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}).listen(port, () => console.log(`serving ${root} on http://127.0.0.1:${port}`));
