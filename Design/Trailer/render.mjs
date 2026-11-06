// Rendert trailer.html Bild für Bild zu einem MP4 (1920×1080, 30 fps).
// Aufruf: node render.mjs [ausgabe.mp4] [--stills 1,3.5,6]
// Braucht playwright-core (PLAYWRIGHT_CORE=/pfad/zu/node_modules/playwright-core) und ffmpeg.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readdirSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const stillsIdx = args.indexOf('--stills');
const stills = stillsIdx >= 0 ? args[stillsIdx + 1].split(',').map(Number) : null;
const out = resolve(args.find(a => a.endsWith('.mp4')) || join(here, 'air-traffic-trailer.mp4'));
const FPS = 30;

// Chromium aus dem Playwright-Cache, falls kein eigener Pfad gesetzt ist
function findChromium() {
  if (process.env.CHROMIUM) return process.env.CHROMIUM;
  const cache = join(homedir(), 'Library/Caches/ms-playwright');
  const dir = readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().pop();
  return join(cache, dir, 'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
}

const browser = await chromium.launch({ executablePath: findChromium() });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(join(here, 'trailer.html')).href + '?render=1');
await page.evaluate(() => Promise.all([...document.images].map(i => i.decode())));
const duration = await page.evaluate(() => window.DURATION);

if (stills) {
  for (const t of stills) {
    await page.evaluate(t => window.seek(t), t);
    await page.screenshot({ path: join(dirname(out), `still-${t.toFixed(2)}.png`) });
  }
} else {
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out],
    { stdio: ['pipe', 'inherit', 'inherit'] });
  const frames = Math.round(duration * FPS);
  for (let f = 0; f < frames; f++) {
    await page.evaluate(t => window.seek(t), f / FPS);
    const buf = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end();
  await new Promise((r, j) => ff.on('close', c => (c === 0 ? r() : j(new Error('ffmpeg ' + c)))));
  console.log(`${frames} Bilder → ${out}`);
}
await browser.close();
