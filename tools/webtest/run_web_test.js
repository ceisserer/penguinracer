// Drive a Godot web export in a real browser and report what it printed.
//
// This is the automated half of spike S1 (godot-port-plan.md §7): the whole snow
// design rests on ping-pong SubViewport render targets plus vertex texture fetch
// working in a WebGL2 export, and the plan flagged that as inferred from the
// feature matrix rather than observed. The spike scene verifies itself and
// prints a marker; this harness only has to load it and read the console.
const puppeteer = require('puppeteer');

const url = process.argv[2] || 'http://127.0.0.1:8061/index.html';
const out = process.argv[3] || '/tmp/web.png';
const marker = process.argv[4] || 'S1_DONE';
const timeoutMs = parseInt(process.argv[5] || '300000', 10);

(async () => {
  const useFirefox = process.env.BROWSER === 'firefox';
  const browser = await puppeteer.launch({
    browser: useFirefox ? 'firefox' : 'chrome',
    extraPrefsFirefox: useFirefox ? {
      // There is no GPU in this container, so Firefox has to be told to accept
      // its software WebGL path instead of refusing the context outright.
      'webgl.force-enabled': true,
      'webgl.disabled': false,
      'webgl.disable-fail-if-major-performance-caveat': true,
      'gfx.webrender.all': true,
      'gfx.webrender.software': true,
      'layers.acceleration.force-enabled': true,
      'security.sandbox.content.level': 0,
    } : undefined,
    headless: useFirefox ? true : 'shell',
    protocolTimeout: timeoutMs,
    args: [
      '--no-sandbox', '--disable-dev-shm-usage',
      // Software GL. There is no GPU in this container, but SwiftShader is a
      // conformant WebGL2 implementation reached through the same browser path
      // a real user's driver would be.
      ...(useFirefox ? [] : ['--use-gl=angle', '--use-angle=swiftshader',
        '--enable-unsafe-swiftshader']),
      '--window-size=1280,720',
    ],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 720 });

  const logs = [];
  let done = null;
  page.on('console', m => {
    const text = m.text();
    logs.push(text);
    if (text.includes(marker)) done = text;
  });
  page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));

  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs });

  const started = Date.now();
  while (!done && Date.now() - started < timeoutMs) {
    await new Promise(r => setTimeout(r, 1000));
  }

  const info = await page.evaluate(() => {
    const c = document.querySelector('canvas');
    if (!c) return { canvas: false };
    const gl = c.getContext('webgl2');
    return {
      canvas: true, width: c.width, height: c.height, webgl2: !!gl,
      renderer: gl ? gl.getParameter(gl.RENDERER) : null,
      vertexTextureUnits: gl ? gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) : null,
      colorBufferFloat: gl ? !!gl.getExtension('EXT_color_buffer_float') : null,
    };
  }).catch(() => ({ canvas: false }));

  await page.screenshot({ path: out });
  console.log('--- browser ---');
  console.log(JSON.stringify(info, null, 2));
  console.log('--- godot console ---');
  console.log(logs.join('\n'));
  console.log('--- result ---');
  console.log(done ? done : `${marker} not seen within ${timeoutMs} ms`);
  await browser.close();
  process.exit(done && done.includes('PASS') ? 0 : 1);
})();
