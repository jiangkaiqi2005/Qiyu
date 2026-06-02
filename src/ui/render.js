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
  const prefix = message.speaker === 'user' ? '我说：' : '栖语说：';
  const safeText = escapeHtml(message.text).replaceAll('\n', '<br>');
  return `<p class="${className}" role="article"><span class="sr-only">${prefix}</span>${safeText}</p>`;
}
