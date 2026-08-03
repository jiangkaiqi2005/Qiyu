import { escapeHtml } from './render.js';

let activeClose = null;

export function confirmAction({
  title = '确认操作',
  message = '',
  confirmLabel = '确认',
  cancelLabel = '取消',
  tone = 'danger'
} = {}) {
  if (typeof document === 'undefined' || !document.body) {
    return Promise.resolve(false);
  }

  if (activeClose) {
    activeClose(false);
  }

  return new Promise((resolve) => {
    const layer = document.createElement('div');
    const isDanger = tone === 'danger';
    layer.className = `confirm-dialog-layer ${isDanger ? 'confirm-dialog-layer-danger' : ''}`;
    layer.setAttribute('role', 'presentation');
    layer.innerHTML = `
      <section class="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="confirm-dialog-title" aria-describedby="confirm-dialog-message">
        <div class="confirm-dialog-mark" aria-hidden="true"></div>
        <div class="confirm-dialog-copy">
          <h2 id="confirm-dialog-title">${escapeHtml(title)}</h2>
          <p id="confirm-dialog-message">${escapeHtml(message)}</p>
        </div>
        <div class="confirm-dialog-actions">
          <button type="button" class="btn confirm-dialog-cancel" data-confirm-cancel>${escapeHtml(cancelLabel)}</button>
          <button type="button" class="btn ${isDanger ? 'danger' : 'primary'} confirm-dialog-accept" data-confirm-accept>${escapeHtml(confirmLabel)}</button>
        </div>
      </section>
    `;

    const cancelBtn = layer.querySelector('[data-confirm-cancel]');
    const acceptBtn = layer.querySelector('[data-confirm-accept]');
    let settled = false;

    const cleanup = () => {
      document.removeEventListener('keydown', onKeyDown);
      if (activeClose === close) {
        activeClose = null;
      }
      if (typeof layer.remove === 'function') {
        layer.remove();
      } else if (layer.parentNode) {
        layer.parentNode.removeChild(layer);
      }
    };

    const finish = (result) => {
      if (settled) return;
      settled = true;
      layer.dataset.state = 'closing';
      globalThis.setTimeout(cleanup, 140);
      resolve(result);
    };

    function close(result) {
      finish(result);
    }

    function onKeyDown(event) {
      if (event.key === 'Escape') {
        event.preventDefault();
        close(false);
      }
    }

    layer.addEventListener('click', (event) => {
      if (event.target === layer) {
        close(false);
      }
    });
    cancelBtn.addEventListener('click', () => close(false));
    acceptBtn.addEventListener('click', () => close(true));
    document.addEventListener('keydown', onKeyDown);

    document.body.appendChild(layer);
    activeClose = close;
    const open = () => {
      layer.dataset.state = 'open';
      cancelBtn.focus({ preventScroll: true });
    };
    if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
      window.requestAnimationFrame(open);
    } else {
      open();
    }
  });
}
