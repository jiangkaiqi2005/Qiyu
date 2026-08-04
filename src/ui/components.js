export function renderButton({ label, variant = 'normal', className = '', attrs = '' }) {
  let baseClass = variant === 'primary' ? 'btn primary' : variant === 'danger' ? 'btn danger' : 'btn';
  
  if (className) {
    baseClass += ' ' + className;
  }

  return `<button class="${baseClass}" ${attrs}>${label}</button>`;
}

export function renderInput({ name, id = `input-${name}`, type = 'text', placeholder = '', value = '', attrs = '' }) {
  return `<input id="${id}" name="${name}" type="${type}" class="form-input" placeholder="${placeholder}" value="${value}" ${attrs}>`;
}

export function renderTextarea({ name, id = `input-${name}`, placeholder = '', value = '', attrs = '' }) {
  return `<textarea id="${id}" name="${name}" class="form-textarea" placeholder="${placeholder}" ${attrs}>${value}</textarea>`;
}

export function renderToggle({ name, id = `input-${name}`, checked = false, label = '', attrs = '' }) {
  return `
    <label class="toggle-container">
      <input type="checkbox" id="${id}" name="${name}" class="toggle-input" ${checked ? 'checked' : ''} ${attrs}>
      <span class="toggle-track"></span>
      ${label ? `<span class="toggle-label">${label}</span>` : ''}
    </label>
  `;
}

export function renderFieldRow({ name, id = `input-${name}`, label, controlHtml, description = '' }) {
  const descId = description ? `desc-${name}` : '';
  return `
    <div class="field-row">
      <div class="field-info">
        <label for="${id}" class="field-label">${label}</label>
        ${description ? `<p id="${descId}" class="field-desc">${description}</p>` : ''}
      </div>
      <div class="field-control">
        ${controlHtml}
      </div>
    </div>
  `;
}

export function renderNotice({ type = 'info', message }) {
  const icon = type === 'success' ? '成功' : type === 'warning' ? '注意' : type === 'error' ? '错误' : '提示';
  return `
    <div class="notice notice-${type}" role="alert">
      <span class="notice-icon" aria-hidden="true">${icon}</span>
      <span class="notice-message">${message}</span>
      <button class="btn-close-notice" type="button" aria-label="关闭通知">关闭</button>
    </div>
  `;
}

export function showNotice(area, type, message) {
  if (area) {
    area.innerHTML = renderNotice({ type, message });
  }
}

export function downloadBlob(content, filename, mimeType) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
}
