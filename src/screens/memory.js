import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';
import { renderButton, renderInput, renderNotice } from '../ui/components.js';

export function render(container, context) {
  const storage = window.localStorage;
  let state = loadBrowserState(storage);

  function saveState() {
    saveBrowserState(storage, state);
  }

  function getMemoryGroupHtml(searchQuery = '') {
    const query = searchQuery.toLowerCase().trim();
    const filtered = (state.memories || []).filter(m => {
      if (!query) return true;
      return m.key.toLowerCase().includes(query) || m.value.toLowerCase().includes(query) || m.source.toLowerCase().includes(query);
    });

    if (filtered.length === 0) {
      return `<p style="color: var(--muted); text-align: center; padding: 24px;">暂无符合条件的对话事实记忆。</p>`;
    }

    const groups = {};
    filtered.forEach(m => {
      const parts = m.key.split('.');
      const cat = parts.length > 1 ? parts[0] : 'general';
      if (!groups[cat]) groups[cat] = [];
      groups[cat].push(m);
    });

    return Object.keys(groups).map(cat => {
      const memoriesHtml = groups[cat].map((m, idx) => {
        const isSensitive = m.key.includes('secret') || m.key.includes('pass') || m.isSensitive;
        const valueDisplay = isSensitive ? '••••••••' : m.value;

        return `
          <div class="field-row memory-row" data-key="${m.key}" style="flex-direction: column; align-items: stretch; border: 1px solid var(--line); padding: 16px; border-radius: 8px; margin-bottom: 12px; background: rgba(16,15,13,0.3);">
            <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(216,169,75,0.08); padding-bottom: 8px; margin-bottom: 8px;">
              <span class="memory-key-tag" style="background: rgba(216,169,75,0.12); color: var(--accent); padding: 2px 8px; border-radius: 4px; font-size: 13px; font-weight: bold;">${m.key}</span>
              <span style="font-size: 11px; color: var(--muted);">修改时间：${new Date(m.updatedAt || Date.now()).toLocaleString()}</span>
            </div>

            <div style="margin: 8px 0; display: flex; justify-content: space-between; align-items: center; gap: 12px;">
              <div class="memory-value-display" style="flex: 1; font-size: 15px; color: var(--ink);">
                ${valueDisplay}
              </div>
              <div class="memory-edit-form" style="display: none; flex: 1; gap: 8px;">
                <input class="form-input edit-value-input" value="${m.value}" style="padding: 6px 10px; font-size: 14px;">
                <button class="btn primary save-edit-btn" style="padding: 6px 12px; font-size: 13px;">保存</button>
                <button class="btn cancel-edit-btn" style="padding: 6px 12px; font-size: 13px;">取消</button>
              </div>

              <div style="display: flex; gap: 8px;">
                ${isSensitive ? `<button class="btn toggle-sensitive-btn" style="padding: 4px 8px; font-size: 12px;">查看</button>` : ''}
                <button class="btn edit-btn" style="padding: 4px 8px; font-size: 12px;">编辑</button>
                <button class="btn danger delete-btn" style="padding: 4px 8px; font-size: 12px;">删除</button>
              </div>
            </div>

            <div style="font-size: 12px; color: var(--muted); margin-bottom: 8px;">事实来源：${m.source}</div>

            <div style="display: flex; gap: 16px; margin-top: 8px; border-top: 1px solid rgba(216,169,75,0.04); padding-top: 8px;">
              <label style="display: inline-flex; align-items: center; gap: 6px; font-size: 13px; cursor: pointer;">
                <input type="checkbox" class="exclude-context-chk" ${!m.excludeFromContext ? 'checked' : ''}>
                <span>允许进入 AI 上下文</span>
              </label>
              <label style="display: inline-flex; align-items: center; gap: 6px; font-size: 13px; cursor: pointer;">
                <input type="checkbox" class="frozen-chk" ${m.frozen ? 'checked' : ''}>
                <span>冻结记忆 (绝不提起)</span>
              </label>
            </div>
          </div>
        `;
      }).join('');

      return `
        <div class="memory-group" style="margin-top: 20px;">
          <h3 style="color: var(--accent); border-left: 3px solid var(--accent); padding-left: 8px; margin-bottom: 12px; font-size: 16px; text-transform: uppercase;">分类：${cat}</h3>
          ${memoriesHtml}
        </div>
      `;
    }).join('');
  }

  const innerHtml = `
    <div class="card">
      <h1>记忆中心</h1>
      <p class="subtitle">在这里你可以直观地查看、搜索、冻结或删除栖语对你的了解。</p>

      <div class="memory-notice-area"></div>

      <div style="display: flex; gap: 12px; margin-bottom: 20px;">
        <input type="text" class="form-input search-mem-input" placeholder="输入关键字搜索记忆..." style="flex: 1;">
        ${renderButton({ label: '手动添加事实', variant: 'primary', attrs: 'class="add-memory-btn"' })}
      </div>

      <div class="add-memory-box notice notice-info" style="display: none; flex-direction: column; gap: 12px; margin-bottom: 20px; border-color: var(--accent);">
        <h4 style="margin: 0; color: var(--accent);">添加自定义对话记忆事实</h4>
        <div style="display: flex; gap: 8px; flex-wrap: wrap;">
          <input class="form-input add-key-input" placeholder="记忆键名 (如 user.pet)" style="flex: 1; min-width: 150px;">
          <input class="form-input add-val-input" placeholder="事实内容 (如 猫咪叫咪咪)" style="flex: 2; min-width: 250px;">
        </div>
        <div style="display: flex; gap: 8px; justify-content: flex-end;">
          <button class="btn confirm-add-btn primary" style="padding: 6px 12px; font-size: 13px;">确认添加</button>
          <button class="btn cancel-add-btn" style="padding: 6px 12px; font-size: 13px;">取消</button>
        </div>
      </div>

      <div class="memory-list-container"></div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/memory');
  bindNavigation(container, context.router);

  const listContainer = container.querySelector('.memory-list-container');
  const searchInput = container.querySelector('.search-mem-input');
  const addBtn = container.querySelector('.add-memory-btn');
  const addBox = container.querySelector('.add-memory-box');
  const confirmAddBtn = container.querySelector('.confirm-add-btn');
  const cancelAddBtn = container.querySelector('.cancel-add-btn');
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
          showNotification('✓ 记忆已更新');
        }
      });

      delBtn.addEventListener('click', () => {
        state.memories.splice(memIndex, 1);
        saveState();
        renderList();
        showNotification('✓ 记忆事实已删除');
      });

      excludeChk.addEventListener('change', (e) => {
        state.memories[memIndex].excludeFromContext = !e.target.checked;
        saveState();
        showNotification('✓ 记忆上下文规则已更新');
      });

      frozenChk.addEventListener('change', (e) => {
        state.memories[memIndex].frozen = e.target.checked;
        saveState();
        showNotification('✓ 记忆冻结规则已更新');
      });
    });
  }

  function showNotification(message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type: 'success', message });
      setTimeout(() => {
        noticeArea.innerHTML = '';
      }, 4000);
    }
  }

  if (searchInput) {
    searchInput.addEventListener('input', () => {
      renderList();
    });
  }

  if (addBtn) {
    addBtn.addEventListener('click', () => {
      addBox.style.display = 'flex';
    });
  }

  if (cancelAddBtn) {
    cancelAddBtn.addEventListener('click', () => {
      addBox.style.display = 'none';
      container.querySelector('.add-key-input').value = '';
      container.querySelector('.add-val-input').value = '';
    });
  }

  if (confirmAddBtn) {
    confirmAddBtn.addEventListener('click', () => {
      const keyInput = container.querySelector('.add-key-input');
      const valInput = container.querySelector('.add-val-input');
      const newKey = keyInput.value.trim().toLowerCase();
      const newVal = valInput.value.trim();

      if (!newKey || !newVal) {
        alert('请填入完整的记忆键名和内容');
        return;
      }

      const nextMemory = {
        key: newKey,
        value: newVal,
        source: 'manual',
        updatedAt: new Date().toISOString(),
        excludeFromContext: false,
        frozen: false
      };

      const existingIndex = state.memories.findIndex(m => m.key === newKey);
      if (existingIndex !== -1) {
        state.memories[existingIndex] = nextMemory;
      } else {
        state.memories.push(nextMemory);
      }

      saveState();
      
      keyInput.value = '';
      valInput.value = '';
      addBox.style.display = 'none';
      
      renderList();
      showNotification('✓ 自定义记忆已保存');
    });
  }

  renderList();
}
