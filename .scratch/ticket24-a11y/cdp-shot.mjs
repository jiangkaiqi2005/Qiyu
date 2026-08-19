// Ticket 24 三档窗口截图工具（零依赖，Node >= 22）。
// 用法: node cdp-shot.mjs <页面URL> <cookie值> <输出png> <宽> <高> [稳定等待毫秒] [reduced-motion]
// reduced-motion 传 1 时通过 CDP 模拟 prefers-reduced-motion: reduce。
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [pageUrl, cookieValue, outPng, widthArg, heightArg, settleArg, reducedMotion] =
  process.argv.slice(2);
if (!pageUrl || !cookieValue || !outPng || !widthArg || !heightArg) {
  console.error('用法: node cdp-shot.mjs <URL> <cookie> <png> <宽> <高> [settleMs] [reducedMotion]');
  process.exit(2);
}
const width = Number(widthArg);
const height = Number(heightArg);
const settleMs = Number(settleArg ?? 10000);
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const debugPort = 9444;
const profileDir = mkdtempSync(join(tmpdir(), 'qiyu-t24-edge-'));

const browser = spawn(
  edge,
  [
    '--headless=new',
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    `--window-size=${width},${height}`,
    '--lang=zh-CN',
    'about:blank',
  ],
  { stdio: 'ignore', detached: true },
);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForDebugger() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) {
        return await response.json();
      }
    } catch {
      // 尚未就绪，继续轮询。
    }
    await sleep(500);
  }
  throw new Error('Edge CDP 调试端口未就绪');
}

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 1;
    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== undefined && pending.has(message.id)) {
        const { resolve: ok, reject: fail } = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) {
          fail(new Error(JSON.stringify(message.error)));
        } else {
          ok(message.result);
        }
      }
    });
    socket.addEventListener('open', () => {
      resolve({
        send(method, params = {}, sessionId) {
          const id = nextId;
          nextId += 1;
          const payload = { id, method, params };
          if (sessionId) {
            payload.sessionId = sessionId;
          }
          return new Promise((ok, fail) => {
            pending.set(id, { resolve: ok, reject: fail });
            socket.send(JSON.stringify(payload));
          });
        },
        close() {
          socket.close();
        },
      });
    });
    socket.addEventListener('error', () => reject(new Error('WebSocket 连接失败')));
  });
}

try {
  const version = await waitForDebugger();
  const cdp = await connect(version.webSocketDebuggerUrl);
  const target = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const attached = await cdp.send('Target.attachToTarget', {
    targetId: target.targetId,
    flatten: true,
  });
  const sessionId = attached.sessionId;
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  }, sessionId);
  if (reducedMotion === '1') {
    await cdp.send('Emulation.setEmulatedMedia', {
      features: [{ name: 'prefers-reduced-motion', value: 'reduce' }],
    }, sessionId);
  }
  await cdp.send(
    'Network.setCookie',
    {
      name: 'qiyu_session',
      value: cookieValue,
      domain: '127.0.0.1',
      path: '/',
      httpOnly: true,
    },
    sessionId,
  );
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Page.navigate', { url: pageUrl }, sessionId);
  // Flutter 初始化 + 会话恢复渲染需要固定的稳定等待。
  await sleep(settleMs);
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
  writeFileSync(outPng, Buffer.from(shot.data, 'base64'));
  console.log(`截图完成: ${outPng} (${width}x${height}${reducedMotion === '1' ? ', reduced-motion' : ''})`);
  cdp.close();
} catch (error) {
  console.error(`截图失败: ${error}`);
  process.exitCode = 1;
} finally {
  try {
    process.kill(-browser.pid);
  } catch {
    browser.kill();
  }
}
