// Ticket 24 键盘流程实测（零依赖，Node >= 22）。
// 用法: node keyboard-flow.mjs <origin> <cookie值> <输出目录>
// 全程只用键盘事件（首页 Tab+Enter 导航 → 聊天 Ctrl+Enter 发送 →
// 历史页 Esc 关闭删除确认），每一步截图并把读到的 URL 写进结果。
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [origin, cookieValue, outDir] = process.argv.slice(2);
if (!origin || !cookieValue || !outDir) {
  console.error('用法: node keyboard-flow.mjs <origin> <cookie> <输出目录>');
  process.exit(2);
}
const width = 1366;
const height = 768;
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const debugPort = 9445;
const profileDir = mkdtempSync(join(tmpdir(), 'qiyu-t24-kb-'));

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

const result = { steps: [] };

async function key(cdp, sessionId, params) {
  await cdp.send('Input.dispatchKeyEvent', params, sessionId);
}

async function tapKey(cdp, sessionId, keyDef) {
  await key(cdp, sessionId, { type: 'rawKeyDown', ...keyDef });
  await key(cdp, sessionId, { type: 'keyUp', ...keyDef });
}

const TAB = { key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 };
const ENTER = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
const ESCAPE = { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 };

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

  async function shot(name) {
    const png = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
    writeFileSync(join(outDir, name), Buffer.from(png.data, 'base64'));
  }

  async function currentUrl() {
    const value = await cdp.send(
      'Runtime.evaluate',
      { expression: 'location.href', returnByValue: true },
      sessionId,
    );
    return value.result.value;
  }

  // 步骤 1：首页加载。
  await cdp.send('Page.navigate', { url: origin }, sessionId);
  await sleep(12000);
  result.homeUrl = await currentUrl();
  await shot('kb-01-home.png');

  // 步骤 2：Tab 移动焦点 + Enter 激活 → 应进入聊天页。
  await tapKey(cdp, sessionId, TAB);
  await sleep(800);
  await shot('kb-02-home-tab-focus.png');
  await tapKey(cdp, sessionId, ENTER);
  await sleep(3000);
  result.afterEnterUrl = await currentUrl();
  result.steps.push('home-tab-enter');
  await shot('kb-03-chat-after-enter.png');

  // 步骤 3：点击输入区聚焦（定位用鼠标，输入与发送用键盘），
  // 输入文本后 Ctrl+Enter 发送。
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mousePressed', x: 683, y: 700, button: 'left', clickCount: 1,
  }, sessionId);
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x: 683, y: 700, button: 'left', clickCount: 1,
  }, sessionId);
  await sleep(500);
  await cdp.send('Input.insertText', { text: '键盘流程实测的一条消息' }, sessionId);
  await sleep(500);
  await shot('kb-04-typed.png');
  await key(cdp, sessionId, {
    type: 'rawKeyDown', key: 'Control', code: 'ControlLeft',
    windowsVirtualKeyCode: 17, nativeVirtualKeyCode: 17, modifiers: 2,
  });
  await key(cdp, sessionId, {
    type: 'rawKeyDown', ...ENTER, modifiers: 2,
  });
  await key(cdp, sessionId, { type: 'keyUp', ...ENTER, modifiers: 2 });
  await key(cdp, sessionId, {
    type: 'keyUp', key: 'Control', code: 'ControlLeft',
    windowsVirtualKeyCode: 17, nativeVirtualKeyCode: 17,
  });
  await sleep(9000);
  result.steps.push('ctrl-enter-send');
  await shot('kb-05-after-send.png');

  // 步骤 4：历史页。Tab 走到会话卡片的删除按钮附近，Enter 打开确认
  // 对话框，Esc 关闭——验证键盘返回行为且不触发删除。
  await cdp.send('Page.navigate', { url: `${origin}/#/history` }, sessionId);
  await sleep(8000);
  result.historyUrl = await currentUrl();
  await shot('kb-06-history.png');
  for (let index = 0; index < 5; index += 1) {
    await tapKey(cdp, sessionId, TAB);
    await sleep(300);
  }
  await shot('kb-07-history-tab5-focus.png');
  await tapKey(cdp, sessionId, ENTER);
  await sleep(1500);
  await shot('kb-08-after-enter.png');
  await tapKey(cdp, sessionId, ESCAPE);
  await sleep(1500);
  result.steps.push('history-enter-escape');
  await shot('kb-09-after-escape.png');

  writeFileSync(join(outDir, 'kb-result.json'), JSON.stringify(result, null, 2));
  console.log(`键盘流程完成: ${JSON.stringify(result)}`);
  cdp.close();
} catch (error) {
  console.error(`键盘流程失败: ${error}`);
  try {
    writeFileSync(join(outDir, 'kb-result.json'), JSON.stringify(result, null, 2));
  } catch {
    // 结果文件写不了就算了。
  }
  process.exitCode = 1;
} finally {
  try {
    process.kill(-browser.pid);
  } catch {
    browser.kill();
  }
}
