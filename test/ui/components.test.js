import test from 'node:test';
import assert from 'node:assert/strict';
import { renderAppShell, bindNavigation, bindSidebarHoverIntent } from '../../src/ui/layout.js';
import {
  renderButton,
  renderInput,
  renderTextarea,
  renderToggle,
  renderFieldRow,
  renderNotice
} from '../../src/ui/components.js';

test('renderAppShell matches routes and injects developer mode', () => {
  globalThis.window = {
    localStorage: {
      getItem(key) {
        return key === 'qiyu_dev_mode' ? 'true' : null;
      }
    }
  };

  const html = renderAppShell('<div>对话内容</div>', '/chat');
  assert.match(html, /skip-link/);
  assert.match(html, /app-shell-container/);
  assert.match(html, /app-canvas/);
  assert.match(html, /sidebar-sheen/);
  assert.match(html, /sidebar-orbit/);
  assert.doesNotMatch(html, /nav-index/);
  assert.doesNotMatch(html, />0[1-9]</);
  assert.match(html, /sidebar-context/);
  assert.match(html, /关系中枢/);
  assert.doesNotMatch(html, /栖所/);
  assert.doesNotMatch(html, /初遇/);
  assert.doesNotMatch(html, /data-nav-path="\/memory"/);
  assert.doesNotMatch(html, />印记</);
  assert.doesNotMatch(html, /印记与默契/);
  assert.match(html, /幻镜/); // Since dev mode is true

  delete globalThis.window;
});

test('renderButton outputs custom label and variant', () => {
  const normalBtn = renderButton({ label: '点击' });
  assert.match(normalBtn, /class="btn"/);
  assert.match(normalBtn, /点击/);

  const primaryBtn = renderButton({ label: '确定', variant: 'primary' });
  assert.match(primaryBtn, /class="btn primary"/);

  const dangerBtn = renderButton({ label: '删除', variant: 'danger' });
  assert.match(dangerBtn, /class="btn danger"/);

  const customBtn = renderButton({ label: '自定义', className: 'custom-class', attrs: 'data-test="123"' });
  assert.match(customBtn, /class="btn custom-class"/);
  assert.match(customBtn, /data-test="123"/);
});

test('renderInput outputs valid attributes', () => {
  const input = renderInput({ name: 'username', placeholder: '名字', value: '栖语' });
  assert.match(input, /name="username"/);
  assert.match(input, /placeholder="名字"/);
  assert.match(input, /value="栖语"/);
});

test('renderToggle respects checked state', () => {
  const toggleChecked = renderToggle({ name: 'sound', checked: true, label: '声音' });
  assert.match(toggleChecked, /checked/);
  assert.match(toggleChecked, /声音/);

  const toggleUnchecked = renderToggle({ name: 'sound', checked: false });
  assert.doesNotMatch(toggleUnchecked, /checked/);
});

test('renderFieldRow layout elements match hierarchy', () => {
  const row = renderFieldRow({
    label: '深度陪伴',
    controlHtml: '<input type="checkbox">',
    description: '是否开启全天陪伴模式'
  });
  assert.match(row, /field-row/);
  assert.match(row, /深度陪伴/);
  assert.match(row, /是否开启全天陪伴模式/);
});

test('renderNotice injects type classes and role alert', () => {
  const infoNotice = renderNotice({ type: 'info', message: '提示信息' });
  assert.match(infoNotice, /notice notice-info/);
  assert.match(infoNotice, /role="alert"/);
  assert.match(infoNotice, /提示信息/);
  assert.doesNotMatch(infoNotice, /onclick=/);
});

test('bindNavigation dismisses notices from the close button', () => {
  let clickHandler;
  let prevented = false;
  let navigated = false;
  const notice = {
    removed: false,
    remove() {
      this.removed = true;
    }
  };
  const closeBtn = {
    closest(selector) {
      return selector === '.notice' ? notice : null;
    }
  };
  const container = {
    addEventListener(event, fn) {
      if (event === 'click') {
        clickHandler = fn;
      }
    },
    querySelectorAll() {
      return [];
    }
  };

  bindNavigation(container, {
    navigate() {
      navigated = true;
    }
  });

  clickHandler({
    preventDefault() {
      prevented = true;
    },
    target: {
      closest(selector) {
        return selector === '.btn-close-notice' ? closeBtn : null;
      }
    }
  });

  assert.equal(prevented, true);
  assert.equal(notice.removed, true);
  assert.equal(navigated, false);
});

test('bindNavigation can dismiss a wrapper when the notice asks for wrapper scope', () => {
  let clickHandler;
  const wrapper = {
    dataset: { noticeDismissScope: 'wrapper' },
    removed: false,
    remove() {
      this.removed = true;
    }
  };
  const notice = {
    parentElement: wrapper,
    removed: false,
    remove() {
      this.removed = true;
    }
  };
  const closeBtn = {
    closest(selector) {
      return selector === '.notice' ? notice : null;
    }
  };
  const container = {
    addEventListener(event, fn) {
      if (event === 'click') {
        clickHandler = fn;
      }
    },
    querySelectorAll() {
      return [];
    }
  };

  bindNavigation(container, { navigate() {} });
  clickHandler({
    preventDefault() {},
    target: {
      closest(selector) {
        return selector === '.btn-close-notice' ? closeBtn : null;
      }
    }
  });

  assert.equal(wrapper.removed, true);
  assert.equal(notice.removed, false);
});

test('bindNavigation carries a stable expanded sidebar state across sidebar route clicks', () => {
  globalThis.window = {
    localStorage: {
      getItem() {
        return null;
      }
    }
  };

  let navClickHandler;
  let navigatedPath = null;
  const sidebar = {
    dataset: { expanded: 'true' },
    addEventListener() {},
    matches(selector) {
      return selector === ':hover';
    }
  };
  const navButton = {
    dataset: { navPath: '/history' },
    addEventListener(type, handler) {
      if (type === 'click') {
        navClickHandler = handler;
      }
    },
    closest(selector) {
      return selector === '.app-sidebar' ? sidebar : null;
    }
  };
  const container = {
    addEventListener() {},
    querySelector(selector) {
      return selector === '.app-sidebar' ? sidebar : null;
    },
    querySelectorAll(selector) {
      return selector === '[data-nav-path]' ? [navButton] : [];
    }
  };

  bindNavigation(container, {
    navigate(path) {
      navigatedPath = path;
    }
  });

  navClickHandler({ preventDefault() {} });
  const nextHtml = renderAppShell('<div>记录</div>', '/history');

  assert.equal(navigatedPath, '/history');
  assert.match(nextHtml, /class="app-sidebar"[^>]*data-expanded="true"/);
  assert.match(nextHtml, /class="app-sidebar"[^>]*data-restored="true"/);

  delete globalThis.window;
});

test('bindSidebarHoverIntent waits before expanding the sidebar', () => {
  let nextTimerId = 1;
  const pendingTimers = new Map();
  const timers = {
    setTimeout(fn, delay) {
      const id = nextTimerId;
      nextTimerId += 1;
      pendingTimers.set(id, { fn, delay });
      return id;
    },
    clearTimeout(id) {
      pendingTimers.delete(id);
    }
  };
  const listeners = new Map();
  const sidebar = {
    dataset: {},
    addEventListener(type, fn) {
      listeners.set(type, fn);
    },
    getBoundingClientRect() {
      return { left: 0 };
    },
    matches() {
      return false;
    }
  };
  const container = {
    querySelector(selector) {
      return selector === '.app-sidebar' ? sidebar : null;
    }
  };
  const runNextTimer = () => {
    const [[id, timer]] = pendingTimers;
    pendingTimers.delete(id);
    timer.fn();
    return timer.delay;
  };

  bindSidebarHoverIntent(container, timers);
  listeners.get('pointerenter')({ pointerType: 'mouse', clientX: 42 });
  listeners.get('pointerleave')({ pointerType: 'mouse' });
  runNextTimer();

  assert.equal(sidebar.dataset.expanded, undefined);

  listeners.get('pointerenter')({ pointerType: 'mouse', clientX: 42 });
  assert.equal(runNextTimer(), 1040);
  assert.equal(sidebar.dataset.expanded, 'true');

  listeners.get('pointerleave')({ pointerType: 'mouse' });
  assert.equal(runNextTimer(), 220);
  assert.equal(sidebar.dataset.expanded, undefined);
});

test('bindSidebarHoverIntent expands when the pointer rests inside the collapsed sidebar', () => {
  let scheduledTimer = null;
  const timers = {
    setTimeout(fn, delay) {
      scheduledTimer = { fn, delay };
      return 1;
    },
    clearTimeout() {}
  };
  const listeners = new Map();
  const sidebar = {
    dataset: {},
    addEventListener(type, fn) {
      listeners.set(type, fn);
    },
    getBoundingClientRect() {
      return { left: 0 };
    },
    matches() {
      return false;
    }
  };
  const container = {
    querySelector(selector) {
      return selector === '.app-sidebar' ? sidebar : null;
    }
  };

  bindSidebarHoverIntent(container, timers);
  listeners.get('pointerenter')({ pointerType: 'mouse', clientX: 86 });

  assert.equal(scheduledTimer.delay, 1040);
  scheduledTimer.fn();
  assert.equal(sidebar.dataset.expanded, 'true');
});

test('bindSidebarHoverIntent cancels expansion when the pointer only passes through', () => {
  let scheduledTimer = null;
  const timers = {
    setTimeout(fn, delay) {
      scheduledTimer = { fn, delay };
      return 1;
    },
    clearTimeout() {
      scheduledTimer = null;
    }
  };
  const listeners = new Map();
  const sidebar = {
    dataset: {},
    addEventListener(type, fn) {
      listeners.set(type, fn);
    },
    getBoundingClientRect() {
      return { left: 0 };
    },
    matches() {
      return false;
    }
  };
  const container = {
    querySelector(selector) {
      return selector === '.app-sidebar' ? sidebar : null;
    }
  };

  bindSidebarHoverIntent(container, timers);
  listeners.get('pointerenter')({ pointerType: 'mouse', clientX: 86 });
  listeners.get('pointerleave')({ pointerType: 'mouse' });

  assert.equal(scheduledTimer.delay, 220);
  scheduledTimer.fn();
  assert.equal(sidebar.dataset.expanded, undefined);
});
