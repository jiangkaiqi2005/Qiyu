import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const [pageUrl, cookieValue, outTxt] = process.argv.slice(2);
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const debugPort = 9334;
const profileDir = mkdtempSync(join(tmpdir(), 'qiyu-edge-dump-'));
const browser = spawn(edge, ['--headless=new', `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profileDir}`, '--no-first-run', '--window-size=1280,900', '--lang=zh-CN', 'about:blank'], { stdio: 'ignore', detached: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitForDebugger() {
  for (let i = 0; i < 60; i += 1) {
    try { const res = await fetch(`http://127.0.0.1:${debugPort}/json/version`); if (res.ok) return await res.json(); } catch {}
    await sleep(500);
  }
  throw new Error('cdp not ready');
}
let resolver; const loaded = new Promise((r) => { resolver = r; });
try {
  const version = await waitForDebugger();
  const socket = await new Promise((resolve, reject) => {
    const ws = new WebSocket(version.webSocketDebuggerUrl);
    const pending = new Map(); let nextId = 1; const handlers = new Map();
    ws.addEventListener('message', (e) => {
      const m = JSON.parse(e.data);
      if (m.id !== undefined && pending.has(m.id)) { const h = pending.get(m.id); pending.delete(m.id); h(m); }
      else if (m.method) { for (const fn of handlers.get(m.method) ?? []) fn(m); }
    });
    ws.addEventListener('open', () => resolve({
      send(method, params = {}, sessionId) { const id = nextId; nextId += 1; const p = { id, method, params }; if (sessionId) p.sessionId = sessionId; return new Promise((ok) => { pending.set(id, ok); ws.send(JSON.stringify(p)); }); },
      on(method, fn) { const l = handlers.get(method) ?? []; l.push(fn); handlers.set(method, l); },
    }));
    ws.addEventListener('error', () => reject(new Error('ws fail')));
  });
  const target = await socket.send('Target.createTarget', { url: 'about:blank' });
  const attached = await socket.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const sid = attached.sessionId;
  socket.on('Page.loadEventFired', () => resolver());
  await socket.send('Network.enable', {}, sid);
  await socket.send('Network.setCookie', { name: 'qiyu_session', value: cookieValue, domain: '127.0.0.1', path: '/' }, sid);
  await socket.send('Page.enable', {}, sid);
  await socket.send('Runtime.enable', {}, sid);
  await socket.send('Page.navigate', { url: pageUrl }, sid);
  await Promise.race([loaded, sleep(20000)]);
  await sleep(15000);
  const evalRes = await socket.send('Runtime.evaluate', { expression: 'document.body.innerText', returnByValue: true }, sid);
  const value = evalRes.result?.result?.value ?? JSON.stringify(evalRes);
  writeFileSync(outTxt, value, 'utf8');
  console.log('dump-ok');
  socket && socket.close && socket.close();
} catch (err) { console.error('dump-fail', err); process.exitCode = 1; }
finally { try { process.kill(-browser.pid); } catch { browser.kill(); } }