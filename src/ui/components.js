export function renderButton({ label, variant = 'normal', attrs = '' }) {
  const className = variant === 'primary' ? 'btn primary' : variant === 'danger' ? 'btn danger' : 'btn';
  return `<button class="${className}" ${attrs}>${label}</button>`;
}

export function renderInput({ name, type = 'text', placeholder = '', value = '', attrs = '' }) {
  return `<input name="${name}" type="${type}" class="form-input" placeholder="${placeholder}" value="${value}" ${attrs}>`;
}

export function renderTextarea({ name, placeholder = '', value = '', attrs = '' }) {
  return `<textarea name="${name}" class="form-textarea" placeholder="${placeholder}" ${attrs}>${value}</textarea>`;
}

export function renderToggle({ name, checked = false, label = '', attrs = '' }) {
  return `
    <label class="toggle-container">
      <input type="checkbox" name="${name}" class="toggle-input" ${checked ? 'checked' : ''} ${attrs}>
      <span class="toggle-track"></span>
      ${label ? `<span class="toggle-label">${label}</span>` : ''}
    </label>
  `;
}

export function renderFieldRow({ label, controlHtml, description = '' }) {
  return `
    <div class="field-row">
      <div class="field-info">
        <span class="field-label">${label}</span>
        ${description ? `<p class="field-desc">${description}</p>` : ''}
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
    </div>
  `;
}
