import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';
import { showNotice } from '../ui/components.js';
import { escapeHtml } from '../ui/render.js';

export function render(container, context) {
  const storage = window.localStorage;
  let state = loadBrowserState(storage);

  function saveState() {
    saveBrowserState(storage, state);
  }

  const catNames = {
    'general': '深夜碎念',
    'user': '关于你',
    'work': '工作与拼搏',
    'family': '家人与日常',
    'sleep': '起居与睡眠',
    'health': '身体与状况',
    'emotion': '心境与情绪',
    'preference': '相处喜好'
  };

  const srcNames = {
    'manual': '你主动留下的',
    'extract': '本地整理出的',
    'system': '系统规则'
  };

  function getMemoryGroupHtml(searchQuery = '') {
    const query = searchQuery.toLowerCase().trim();
    const filtered = (state.memories || []).filter(m => {
      if (!query) return true;
      return m.key.toLowerCase().includes(query) || m.value.toLowerCase().includes(query) || m.source.toLowerCase().includes(query);
    });

    if (filtered.length === 0) {
      return `
        <div class="memory-empty-state">
          <span>暂无上下文</span>
          <p>暂无符合条件的本地上下文。</p>
        </div>
      `;
    }

    const groups = {};
    filtered.forEach(m => {
      const parts = m.key.split('.');
      const cat = m.category || (parts.length > 1 ? parts[0] : 'general');
      if (!groups[cat]) groups[cat] = [];
      groups[cat].push(m);
    });

    return Object.keys(groups).map(cat => {
      const memoriesHtml = groups[cat].map((m) => {
        const isSensitive = m.sensitiveLevel > 0 || m.key.includes('secret') || m.key.includes('pass');
        const valueDisplay = isSensitive ? '••••••••' : m.value;
        const displaySource = srcNames[m.source] || m.source;
        const displayOriginalText = m.originalText || m.source;
        const useCount = m.useCount || 0;
        const lastUsedStr = m.lastUsedAt ? new Date(m.lastUsedAt).toLocaleString() : '从未使用';
        const safeKey = escapeHtml(m.key);
        const safeValue = escapeHtml(valueDisplay);
        const safeRawValue = escapeHtml(m.value);
        const safeSource = escapeHtml(displaySource);
        const safeOriginalText = escapeHtml(displayOriginalText);
        const safeLastUsedStr = escapeHtml(lastUsedStr);

        return `
          <article class="memory-row" data-key="${safeKey}">
            <div class="memory-row-head">
              <div class="memory-row-tags">
                <span class="memory-key-tag">${safeKey}</span>
                ${isSensitive ? '<span class="sensitive-badge">敏感内容已隐藏</span>' : ''}
              </div>
              <span class="memory-updated-at">更新时间：${new Date(m.updatedAt || Date.now()).toLocaleString()}</span>
            </div>

            <div class="memory-row-main">
              <div class="memory-value-display">
                ${safeValue}
              </div>
              <div class="memory-edit-form">
                <input class="form-input edit-value-input memory-inline-input" value="${safeRawValue}" aria-label="修改本地上下文内容">
                <button class="btn primary save-edit-btn memory-small-btn">保存</button>
                <button class="btn cancel-edit-btn memory-small-btn">取消</button>
              </div>

              <div class="memory-row-actions">
                ${isSensitive ? '<button class="btn toggle-sensitive-btn memory-small-btn">查看</button>' : ''}
                <button class="btn edit-btn memory-small-btn">调整</button>
                <button class="btn danger delete-btn memory-small-btn">删除</button>
              </div>
            </div>

            <div class="memory-meta-panel">
              <div><strong>来源:</strong> <code>${safeSource}</code></div>
              <div><strong>原文:</strong> <span>${safeOriginalText}</span></div>
              <div class="memory-usage-line">累计调用 <strong>${useCount}</strong> 次，最近使用 <strong>${safeLastUsedStr}</strong></div>
            </div>

            <div class="memory-policy-row">
              <label title="关闭后此条本地上下文不会被放入深夜聊天的 AI 上下文">
                <input type="checkbox" class="exclude-context-chk" ${!m.excludeFromContext ? 'checked' : ''}>
                <span>允许进入夜聊上下文</span>
              </label>
              <label title="开启后，此条本地上下文会保留但不参与对话上下文">
                <input type="checkbox" class="frozen-chk" ${m.frozen ? 'checked' : ''}>
                <span>暂时不参与对话</span>
              </label>
            </div>
          </article>
        `;
      }).join('');

      const displayName = catNames[cat] || `分类：${cat}`;
      return `
        <section class="memory-group">
          <h2>${displayName}</h2>
          ${memoriesHtml}
        </section>
      `;
    }).join('');
  }

  const innerHtml = `
    <section class="memory-workbench" aria-labelledby="memory-title">
      <div class="archive-hero memory-hero">
        <div>
          <span class="archive-kicker">本地上下文</span>
          <h1 id="memory-title">本地上下文</h1>
          <p>只查看和整理保存在这台设备里的偏好与事实。它们不是任务系统，也不是人格资产，只是为了少让你重复解释。</p>
        </div>
        <div class="archive-stamp" aria-hidden="true">
          <span>${(state.memories || []).length}</span>
          <strong>仅在本机</strong>
        </div>
      </div>

      <div class="memory-notice-area"></div>

      <div class="memory-toolbar">
        <input type="text" class="form-input search-mem-input" placeholder="搜索本地上下文" aria-label="搜索本地上下文">
      </div>

      <div class="memory-list-container"></div>
    </section>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/memory');
  bindNavigation(container, context.router);

  const listContainer = container.querySelector('.memory-list-container');
  const searchInput = container.querySelector('.search-mem-input');
  const noticeArea = container.querySelector('.memory-notice-area');

  function renderList() {
    listContainer.innerHTML = getMemoryGroupHtml(searchInput.value);
    bindListEvents();
  }

  function bindListEvents() {
    const rows = listContainer.querySelectorAll('.memory-row');
    rows.forEach(row => {
      const key = row.dataset.key;
      const memIndex = state.memories.findIndex(m => m.key === key);
      if (memIndex === -1) return;

      const memory = state.memories[memIndex];

      const valDisplay = row.querySelector('.memory-value-display');
      const editForm = row.querySelector('.memory-edit-form');
      const editValInput = row.querySelector('.edit-value-input');
      
      const editBtn = row.querySelector('.edit-btn');
      const delBtn = row.querySelector('.delete-btn');
      const saveBtn = row.querySelector('.save-edit-btn');
      const cancelBtn = row.querySelector('.cancel-edit-btn');
      
      const excludeChk = row.querySelector('.exclude-context-chk');
      const frozenChk = row.querySelector('.frozen-chk');
      
      const toggleSensitive = row.querySelector('.toggle-sensitive-btn');

      if (toggleSensitive) {
        toggleSensitive.addEventListener('click', () => {
          if (valDisplay.innerText === '••••••••') {
            valDisplay.innerText = memory.value;
            toggleSensitive.innerText = '隐藏';
          } else {
            valDisplay.innerText = '••••••••';
            toggleSensitive.innerText = '查看';
          }
        });
      }

      editBtn.addEventListener('click', () => {
        valDisplay.style.display = 'none';
        editForm.style.display = 'flex';
        editValInput.focus();
      });

      cancelBtn.addEventListener('click', () => {
        valDisplay.style.display = 'block';
        editForm.style.display = 'none';
        editValInput.value = memory.value;
      });

      saveBtn.addEventListener('click', () => {
        const newValue = editValInput.value.trim();
        if (newValue) {
          state.memories[memIndex].value = newValue;
          state.memories[memIndex].updatedAt = new Date().toISOString();
          saveState();
          renderList();
          showNotification('本地上下文已更新。');
        }
      });

      delBtn.addEventListener('click', () => {
        state.memories.splice(memIndex, 1);
        saveState();
        renderList();
        showNotification('这条本地上下文已删除。');
      });

      excludeChk.addEventListener('change', (e) => {
        state.memories[memIndex].excludeFromContext = !e.target.checked;
        saveState();
        showNotification('对话上下文范围已更新。');
      });

      frozenChk.addEventListener('change', (e) => {
        state.memories[memIndex].frozen = e.target.checked;
        saveState();
        showNotification('本地上下文状态已更新。');
      });
    });
  }

  function showNotification(message) {
    showNotice(noticeArea, 'success', message);
  }

  // Debounce search updates so filtering does not re-render on every keystroke.
  function debounce(fn, delay) {
    let timer = null;
    return function (...args) {
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => {
        fn.apply(this, args);
      }, delay);
    };
  }

  if (searchInput) {
    searchInput.addEventListener('input', debounce(() => {
      renderList();
    }, 250));
  }

  renderList();
}
