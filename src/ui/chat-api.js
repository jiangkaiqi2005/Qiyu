// Fetch and cache the CSRF token required by POST API routes.
// Uses globalThis so it interoperates with window.qiyuCsrfToken set by other screens.
export async function ensureCsrfToken(fetchImpl = fetch) {
  if (globalThis.qiyuCsrfToken) {
    return globalThis.qiyuCsrfToken;
  }
  try {
    const response = await fetchImpl('/api/settings');
    if (response.ok) {
      const data = await response.json();
      if (data && data.csrfToken) {
        globalThis.qiyuCsrfToken = data.csrfToken;
        return data.csrfToken;
      }
    }
  } catch {}
  return '';
}

export async function sendChatMessage({ text, state, fetchImpl = fetch }) {
  const csrfToken = await ensureCsrfToken(fetchImpl);
  const response = await fetchImpl('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
    body: JSON.stringify({ text, state })
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Chat API failed: ${response.status} ${body}`);
  }

  return response.json();
}

// CSRF-protected JSON POST shared by the settings-family routes
export function postJson(url, body, csrfToken, fetchImpl = fetch) {
  return fetchImpl(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': csrfToken || ''
    },
    body: JSON.stringify(body)
  });
}
