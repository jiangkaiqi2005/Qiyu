export function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

export function renderBubble(message) {
  const className = message.speaker === 'user' ? 'user' : 'qiyu';
  const safeText = escapeHtml(message.text).replaceAll('\n', '<br>');
  return `<p class="${className}">${safeText}</p>`;
}

export function renderThread(messages) {
  return messages.map(renderBubble).join('');
}
