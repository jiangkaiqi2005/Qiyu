import { renderAppShell, bindNavigation } from '../ui/layout.js';
import { loadBrowserState, saveBrowserState } from '../qiyu/state.js';
import { escapeHtml, renderBubble } from '../ui/render.js';
import { showNotice } from '../ui/components.js';
import { confirmAction } from '../ui/confirm-dialog.js';

export function render(container, context) {
  const storage = window.localStorage;
  let state = loadBrowserState(storage);

  // Default selection to the most recent conversation date
  const sortedConversations = [...(state.dailyConversations || [])].sort((a, b) => b.date.localeCompare(a.date));
  let selectedDate = sortedConversations.length > 0 ? sortedConversations[0].date : '';

  const innerHtml = `
    <section class="history-workbench" aria-labelledby="history-title">
      <div class="archive-hero history-hero">
        <div>
          <span class="archive-kicker">深夜归档</span>
          <h1 id="history-title">夜话归档</h1>
          <p>按日期保留每晚的对话。它是回看，不是打扰；需要时打开，不需要时安静收起。</p>
        </div>
        <div class="archive-stamp" aria-hidden="true">
          <span>${sortedConversations.length}</span>
          <strong>晚已留存</strong>
        </div>
      </div>

      <div class="history-notice-area"></div>

      <div class="history-layout-container">
      </div>
    </section>
  `;

  container.innerHTML = renderAppShell(innerHtml, '/history');
  bindNavigation(container, context.router);

  const noticeArea = container.querySelector('.history-notice-area');
  const layoutContainer = container.querySelector('.history-layout-container');

  function showNotification(type, message) {
    showNotice(noticeArea, type, message);
  }

  function renderMainLayout() {
    if (!state.dailyConversations || state.dailyConversations.length === 0) {
      layoutContainer.innerHTML = `
        <div class="history-empty-state">
          <span>暂无归档</span>
          <p>这里还没有深夜里的夜话记录呢。</p>
          <button data-nav-path="/chat" class="btn primary history-start-btn">开启今晚对话</button>
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
        <article class="history-item-card ${isActive ? 'active' : ''}" data-date="${safeDate}">
          <div class="history-item-head">
            <strong>${safeTitle}</strong>
            <button class="delete-day-btn" data-delete-date="${safeDate}" aria-label="删除此日记录">删除</button>
          </div>
          <div class="history-item-meta">
            <span>${c.turns.length} 轮对话</span>
            <span>${formattedTime}</span>
          </div>
          <p>
            ${safeLastTurnText}
          </p>
        </article>
      `;
    }).join('');
  }

  function renderDetailPanel() {
    const detailPanel = container.querySelector('.history-detail-panel');
    if (!detailPanel) return;

    if (!selectedDate) {
      detailPanel.innerHTML = `
        <div class="history-detail-empty">
          <span>选择一晚</span>
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
      <div class="history-detail-head">
        <h2>${escapeHtml(c.title)}</h2>
        <span>共计 ${c.turns.length} 轮对话，开启时间 ${new Date(c.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
      </div>
      <div class="message-container history-message-stack">
        ${bubblesHtml}
      </div>
    `;
  }

  renderMainLayout();

  // Event Delegation for clicking sidebar item cards.
  // Bound to layoutContainer (recreated per navigation) so stale handlers do
  // not accumulate on the persistent #app container.
  layoutContainer.addEventListener('click', (e) => {
    const itemCard = e.target.closest('.history-item-card');
    if (itemCard && !e.target.closest('.delete-day-btn')) {
      selectedDate = itemCard.dataset.date;
      container.querySelector('.history-item-card.active')?.classList.remove('active');
      itemCard.classList.add('active');
      renderDetailPanel();
    }
  });

  // Event Delegation for clicking delete button
  layoutContainer.addEventListener('click', async (e) => {
    const deleteBtn = e.target.closest('.delete-day-btn');
    if (deleteBtn) {
      e.stopPropagation();
      const dateToDelete = deleteBtn.dataset.deleteDate;
      const confirmed = await confirmAction({
        title: '抹去这一天',
        message: `确定要彻底抹去 ${dateToDelete} 这一天的所有对话记录吗？此操作无法撤销。`,
        confirmLabel: '抹去'
      });
      if (confirmed) {
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
        showNotification('success', `${dateToDelete} 的对话记录已删除。`);
      }
    }
  });
}
