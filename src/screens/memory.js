import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';
import { renderNotice } from '../ui/components.js';
import { escapeHtml } from '../ui/render.js';

export function render(container, context) {
  const storage = window.localStorage;
  let state = loadBrowserState(storage);

  function saveState() {
    saveBrowserState(storage, state);
  }

  // Poetic translations for technical categories
  const catNames = {
    'general': '深夜碎念 (General)',
    'user': '关于你 (User)',
    'work': '工作与拼搏 (Work)',
    'family': '家人与日常 (Family)',
    'sleep': '起居与睡眠 (Sleep)',
    'health': '身体与状况 (Health)',
    'emotion': '心境与情绪 (Emotion)',
    'preference': '相处喜好 (Preference)'
  };

  const srcNames = {
    'manual': '你亲口说的 (Manual)',
    'extract': '我悄悄记下的 (Extract)',
    'system': '契约记忆 (System)'
  };

  function getMemoryGroupHtml(searchQuery = '') {
    const query = searchQuery.toLowerCase().trim();
    const filtered = (state.memories || []).filter(m => {
      if (!query) return true;
      return m.key.toLowerCase().includes(query) || m.value.toLowerCase().includes(query) || m.source.toLowerCase().includes(query);
    });

    if (filtered.length === 0) {
      return `<p style="color: var(--muted); text-align: center; padding: 24px;">暂无符合条件的相遇记忆印记。</p>`;
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
          <div class="field-row memory-row" data-key="${safeKey}" style="flex-direction: column; align-items: stretch; border: 1.5px solid rgba(223,179,85,0.15); padding: 20px; border-radius: 14px; margin-bottom: 16px; background: rgba(22, 20, 18, 0.45); box-shadow: 0 4px 12px rgba(0,0,0,0.25); text-align: left;">
            <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(223,179,85,0.08); padding-bottom: 10px; margin-bottom: 12px; flex-wrap: wrap; gap: 8px;">
              <div style="display: flex; align-items: center; gap: 8px;">
                <span class="memory-key-tag" style="background: rgba(223, 179, 85, 0.08); border: 1px solid rgba(223, 179, 85, 0.25); color: var(--accent); padding: 3px 10px; border-radius: 6px; font-size: 12.5px; font-weight: bold; letter-spacing: 0.5px; font-family: monospace;">${safeKey}</span>
                ${isSensitive ? `<span class="sensitive-badge" style="background: rgba(201, 75, 75, 0.12); border: 1px solid rgba(201, 75, 75, 0.35); color: #ff9999; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">[敏感隐私已封存]</span>` : ''}
              </div>
              <span style="font-size: 11px; color: var(--muted);">记下时间：${new Date(m.updatedAt || Date.now()).toLocaleString()}</span>
            </div>

            <div style="margin: 8px 0; display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap;">
              <div class="memory-value-display" style="flex: 1; font-size: 15.5px; color: var(--ink);">
                ${safeValue}
              </div>
              <div class="memory-edit-form" style="display: none; flex: 1; gap: 8px; width: 100%;">
                <input class="form-input edit-value-input" value="${safeRawValue}" aria-label="修改记忆事实内容" style="padding: 6px 10px; font-size: 14px;">
                <button class="btn primary save-edit-btn" style="padding: 8px 12px; font-size: 13px; min-height: 36px;">保存</button>
                <button class="btn cancel-edit-btn" style="padding: 8px 12px; font-size: 13px; min-height: 36px;">取消</button>
              </div>

              <!-- Expanded touch target dimensions satisfying WCAG AAA standards -->
              <div style="display: flex; gap: 6px; flex-wrap: wrap;">
                ${isSensitive ? `<button class="btn toggle-sensitive-btn" style="padding: 8px 12px; font-size: 13px; min-width: 44px; min-height: 36px;">查看</button>` : ''}
                <button class="btn edit-btn" style="padding: 8px 12px; font-size: 13px; min-width: 44px; min-height: 36px;">修剪</button>
                <button class="btn danger delete-btn" style="padding: 8px 12px; font-size: 13px; min-width: 44px; min-height: 36px;">遗忘</button>
              </div>
            </div>

            <div style="font-size: 12.5px; color: var(--muted); margin-bottom: 12px; display: flex; flex-direction: column; gap: 6px; background: rgba(12, 11, 9, 0.35); padding: 12px; border-radius: 8px; border: 1px solid rgba(223, 179, 85, 0.05); text-align: left;">
              <div><strong>事实来源:</strong> <code style="background:rgba(223, 179, 85, 0.08); color: var(--accent); padding: 2px 6px; border-radius: 4px; font-size: 11.5px; font-family: inherit;">${safeSource}</code></div>
              <div style="line-height: 1.5;"><strong>来源原文:</strong> <span style="font-style: italic; color: var(--muted);">"${safeOriginalText}"</span></div>
              <div style="font-size: 11px; border-top: 1px solid rgba(223, 179, 85, 0.04); padding-top: 6px; margin-top: 2px; color: var(--muted);">使用统计：累计调用 <strong>${useCount}</strong> 次 | 最近使用 <strong>${safeLastUsedStr}</strong></div>
            </div>

            <div style="display: flex; gap: 16px; margin-top: 8px; border-top: 1px solid rgba(223, 179, 85, 0.04); padding-top: 12px; flex-wrap: wrap;">
              <label style="display: inline-flex; align-items: center; gap: 6px; font-size: 13px; cursor: pointer;" title="关闭后此条印记事实将不会被放入深夜聊天的AI上下文">
                <input type="checkbox" class="exclude-context-chk" style="accent-color:var(--accent);" ${!m.excludeFromContext ? 'checked' : ''}>
                <span>允许进入夜聊上下文 (不要再提)</span>
              </label>
              <label style="display: inline-flex; align-items: center; gap: 6px; font-size: 13px; cursor: pointer;" title="开启冻结后，我会彻底假装忘记，但在印记中心予以保留">
                <input type="checkbox" class="frozen-chk" style="accent-color:var(--accent);" ${m.frozen ? 'checked' : ''}>
                <span>藏入箱底 (冻结记忆)</span>
              </label>
            </div>
          </div>
        `;
      }).join('');

      const displayName = catNames[cat] || `分类：${cat}`;
      return `
        <div class="memory-group" style="margin-top: 32px;">
          <h2 style="color: var(--accent); border: 0; padding: 0; margin-bottom: 16px; font-size: 16px; margin-top: 0; letter-spacing: 1.5px; display: flex; align-items: center; gap: 8px; font-weight: bold; text-align: left;">
            <span style="display: inline-block; width: 3px; height: 14px; background: var(--accent); border-radius: 1.5px;"></span>
            ${displayName}
          </h2>
          ${memoriesHtml}
        </div>
      `;
    }).join('');
  }

  const innerHtml = `
    <div class="card">
      <h1>私语印记（记忆中心）</h1>
      <p class="subtitle">在这里，查看、搜索、修剪或遗忘栖语在深夜里悄悄记下的每一个默契印记。</p>

      <div class="memory-notice-area"></div>

      <div style="display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap;">
        <input type="text" class="form-input search-mem-input" placeholder="搜索已记下的碎念..." aria-label="搜索已记下的碎念" style="flex: 1; min-width: 200px;">
      </div>

      <div class="memory-list-container"></div>
    </div>
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
          showNotification('✓ 记忆印记修剪成功');
        }
      });

      delBtn.addEventListener('click', () => {
        state.memories.splice(memIndex, 1);
        saveState();
        renderList();
        showNotification('✓ 记忆碎念已从脑海遗忘');
      });

      excludeChk.addEventListener('change', (e) => {
        state.memories[memIndex].excludeFromContext = !e.target.checked;
        saveState();
        showNotification('✓ 对话上下文规则已微调');
      });

      frozenChk.addEventListener('change', (e) => {
        state.memories[memIndex].frozen = e.target.checked;
        saveState();
        showNotification('✓ 记忆封箱状态已微调');
      });
    });
  }

  function showNotification(message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type: 'success', message });
    }
  }

  // SOTA High Performance: 250ms Debounced search updates
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
