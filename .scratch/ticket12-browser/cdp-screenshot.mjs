// Ticket 12 浏览器真实测试截图工具（零依赖，Node >= 22）。
// 用法: node cdp-screenshot.mjs <页面URL> <qiyu_session cookie 值> <输出png> [稳定等待毫秒]
// 流程: 启动无头 Edge（CDP 远程调试）→ 注入会话 cookie → 打开页面 →
// 等待 Flutter 初始化与会话恢复渲染 → 截图 → 关闭浏览器。
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [pageUrl, cookieValue, outPng, settleArg, scrollMode] = process.argv.slice(2);
if (!pageUrl || !cookieValue || !outPng) {
  console.error('用法: node cdp-screenshot.mjs <页面URL> <cookie值> <输出png> [稳定等待毫秒]');
  process.exit(2);
}
const settleMs = Number(settleArg ?? 12000);
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const debugPort = 9333;
const profileDir = mkdtempSync(join(tmpdir(), 'qiyu-edge-'));

const browser = spawn(
  edge,
  [
    '--headless=new',
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1280,900',
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
    const handlers = new Map();
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
      } else if (message.method) {
        const list = handlers.get(message.method) ?? [];
        for (const handler of list) {
          handler(message.params, message.sessionId);
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
        on(method, handler) {
          const list = handlers.get(method) ?? [];
          list.push(handler);
          handlers.set(method, list);
        },
        close() {
          socket.close();
        },
      });
    });
    socket.addEventListener('error', () => reject(new Error('WebSocket 连接失败')));
  });
}

let loadedResolver;
const loaded = new Promise((resolve) => {
  loadedResolver = resolve;
});

try {
  const version = await waitForDebugger();
  const cdp = await connect(version.webSocketDebuggerUrl);
  const target = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const attached = await cdp.send('Target.attachToTarget', {
    targetId: target.targetId,
    flatten: true,
  });
  const sessionId = attached.sessionId;
  cdp.on('Page.loadEventFired', () => loadedResolver());
  await cdp.send('Network.enable', {}, sessionId);
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
  await Promise.race([loaded, sleep(20000)]);
  // Flutter 初始化 + /api/chat/session 会话恢复渲染需要额外时间。
  await sleep(settleMs);
  // 聊天列表滚动验证：默认用合成手势滚到底；'noscroll' 跳过手势，
  // 用于验证应用自身的自动滚到底行为。
  if (scrollMode === 'noscroll') {
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
    writeFileSync(outPng, Buffer.from(shot.data, 'base64'));
    console.log(`截图完成: ${outPng}`);
    cdp.close();
    process.exit(0);
  }
  for (let i = 0; i < 4; i += 1) {
    await cdp.send(
      'Input.synthesizeScrollGesture',
      {
        x: 640,
        y: 450,
        xDistance: 0,
        yDistance: -2400,
        speed: 2400,
        preventFling: true,
      },
      sessionId,
    );
    await sleep(700);
  }
  const shot = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
  writeFileSync(outPng, Buffer.from(shot.data, 'base64'));
  console.log(`截图完成: ${outPng}`);
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
