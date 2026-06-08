import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';
import { escapeHtml, renderBubble } from '../ui/render.js';
import { renderNotice } from '../ui/components.js';

export function render(container, context) {
  const storage = window.localStorage;
  let state = loadBrowserState(storage);

  // Default selection to the most recent conversation date
  const sortedConversations = [...(state.dailyConversations || [])].sort((a, b) => b.date.localeCompare(a.date));
  let selectedDate = sortedConversations.length > 0 ? sortedConversations[0].date : '';

  const noticeHtml = `<div class="history-notice-area"></div>`;

  const innerHtml = `
    <div class="card" style="max-width: 960px; padding: 24px 32px; width: 100%;">
      <div style="border-bottom: 1px solid rgba(223, 179, 85, 0.15); padding-bottom: 12px; margin-bottom: 16px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px;">
        <div>
          <h1 style="border: 0; padding: 0; margin: 0; font-size: 20px; color: var(--accent);">私语归档 (夜话记录)</h1>
          <p style="font-size: 13px; color: var(--muted); margin: 4px 0 0 0;">重温我们曾在深夜里轻声说过的那些话。</p>
        </div>
      </div>

      ${noticeHtml}

      <div class="history-layout-container">
        <!-- Main Layout rendered dynamically -->
      </div>
    </div>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/history');
  bindNavigation(container, context.router);

  const noticeArea = container.querySelector('.history-notice-area');
  const layoutContainer = container.querySelector('.history-layout-container');

  function showNotification(type, message) {
    if (noticeArea) {
      noticeArea.innerHTML = renderNotice({ type, message });
    }
  }

  function renderMainLayout() {
    if (!state.dailyConversations || state.dailyConversations.length === 0) {
      layoutContainer.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 48px; text-align: center; color: var(--muted);">
          <span style="font-size: 48px; margin-bottom: 16px;">📁</span>
          <p style="font-size: 15px; margin: 0 0 12px 0;">这里还没有深夜里的夜话记录呢。</p>
          <button data-nav-path="/chat" class="btn primary" style="min-height: 40px; font-size: 13px;">开启今晚对话</button>
        </div>
      `;
      bindNavigation(layoutContainer, context.router);
      return;
    }

    layoutContainer.innerHTML = `
      <div class="history-layout">
        <aside class="history-sidebar"></aside>
        <section class="history-detail-panel"></section>
      </div>
    `;

    renderSidebar();
    renderDetailPanel();
  }

  function renderSidebar() {
    const sidebar = container.querySelector('.history-sidebar');
    if (!sidebar) return;

    const conversations = [...(state.dailyConversations || [])].sort((a, b) => b.date.localeCompare(a.date));
    
    sidebar.innerHTML = conversations.map(c => {
      const isActive = c.date === selectedDate;
      const lastTurn = c.turns && c.turns.length > 0 ? c.turns[c.turns.length - 1] : null;
      const lastTurnText = lastTurn ? `${lastTurn.speaker === 'user' ? '我: ' : '栖语: '}${lastTurn.text}` : '没有对话记录';
      const safeDate = escapeHtml(c.date);
      const safeTitle = escapeHtml(c.title);
      const safeLastTurnText = escapeHtml(lastTurnText);
      
      let formattedTime = '';
      try {
        formattedTime = new Date(c.updatedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      } catch {
        formattedTime = '-';
      }

      return `
        <div class="history-item-card ${isActive ? 'active' : ''}" data-date="${safeDate}" style="padding: 16px; border-radius: 12px; cursor: pointer; display: flex; flex-direction: column; gap: 8px; position: relative; text-align: left;">
          <div style="display: flex; justify-content: space-between; align-items: center; width: 100%;">
            <strong style="color: ${isActive ? 'var(--accent)' : 'var(--ink)'}; font-size: 14.5px; letter-spacing: 0.5px;">${safeTitle}</strong>
            <button class="delete-day-btn" data-delete-date="${safeDate}" aria-label="删除此日记录" style="background: none; border: none; color: var(--muted); font-size: 16px; cursor: pointer; padding: 2px 6px; border-radius: 4px; opacity: 0.6; transition: opacity 0.2s;">×</button>
          </div>
          <div style="font-size: 11px; color: var(--muted); display: flex; justify-content: space-between; width: 100%;">
            <span>${c.turns.length} 轮对话</span>
            <span>${formattedTime}</span>
          </div>
          <p style="font-size: 12px; color: var(--muted); margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 220px;">
            ${safeLastTurnText}
          </p>
        </div>
      `;
    }).join('');
  }

  function renderDetailPanel() {
    const detailPanel = container.querySelector('.history-detail-panel');
    if (!detailPanel) return;

    if (!selectedDate) {
      detailPanel.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: var(--muted); min-height: 200px;">
          <span style="font-size: 24px; margin-bottom: 8px;">📜</span>
          <span>在左侧选择一天，静静重温那一晚的低语。</span>
        </div>
      `;
      return;
    }

    const c = state.dailyConversations.find(conv => conv.date === selectedDate);
    if (!c) {
      detailPanel.innerHTML = '';
      return;
    }

    const bubblesHtml = c.turns.map(turn => renderBubble({
      speaker: turn.speaker === 'user' ? 'user' : 'qiyu',
      text: turn.text
    })).join('');

    detailPanel.innerHTML = `
      <div style="border-bottom: 1px solid rgba(223, 179, 85, 0.1); padding-bottom: 14px; margin-bottom: 20px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; width: 100%; text-align: left;">
        <h2 style="font-size: 17px; color: var(--accent); margin: 0; font-weight: bold; border: 0; padding: 0;">${escapeHtml(c.title)}</h2>
        <span style="font-size: 12px; color: var(--muted);">共计 ${c.turns.length} 轮对话 | 开启时间：${new Date(c.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
      </div>
      <div class="message-container" style="flex: 1; display: flex; flex-direction: column; gap: 16px; width: 100%;">
        ${bubblesHtml}
      </div>
    `;
  }

  renderMainLayout();

  // Event Delegation for clicking sidebar item cards
  container.addEventListener('click', (e) => {
    const itemCard = e.target.closest('.history-item-card');
    if (itemCard && !e.target.closest('.delete-day-btn')) {
      selectedDate = itemCard.dataset.date;
      renderSidebar();
      renderDetailPanel();
    }
  });

  // Event Delegation for clicking delete button
  container.addEventListener('click', (e) => {
    const deleteBtn = e.target.closest('.delete-day-btn');
    if (deleteBtn) {
      e.stopPropagation();
      const dateToDelete = deleteBtn.dataset.deleteDate;
      if (confirm(`确定要彻底抹去 ${dateToDelete} 这一天的所有对话记忆吗？此操作无法撤销。`)) {
        state.dailyConversations = state.dailyConversations.filter(c => c.date !== dateToDelete);
        
        if (state.activeConversationDate === dateToDelete) {
          state.activeConversationDate = '';
        }
        
        saveBrowserState(storage, state);
        
        if (selectedDate === dateToDelete) {
          const sorted = [...state.dailyConversations].sort((a, b) => b.date.localeCompare(a.date));
          selectedDate = sorted.length > 0 ? sorted[0].date : '';
        }
        
        renderMainLayout();
        showNotification('success', `✓ ${dateToDelete} 的对话记录已被永久遗忘。`);
      }
    }
  });
}
