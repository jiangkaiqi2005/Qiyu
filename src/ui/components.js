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
  const icon = type === 'success' ? '✓' : type === 'warning' ? '⚠' : type === 'error' ? '✕' : 'ℹ';
  return `
    <div class="notice notice-${type}" role="alert">
      <span class="notice-icon" aria-hidden="true">${icon}</span>
      <span class="notice-message">${message}</span>
      <button class="btn-close-notice" type="button" aria-label="关闭通知" style="background:transparent; border:0; color:inherit; cursor:pointer; font-size:16px; margin-left:auto; padding:2px 8px;">×</button>
    </div>
  `;
}
