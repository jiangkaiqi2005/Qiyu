export async function readJsonBody(req, limitBytes = 65536) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (Buffer.byteLength(raw, 'utf8') > limitBytes) {
      throw new Error('Request body too large');
    }
  }
  return JSON.parse(raw || '{}');
}

export function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

export function redactSecret(message, secret) {
  if (!secret) return message;
  return message.split(secret).join('[redacted]');
}

/**
 * Validate CSRF token and Origin/Referer headers.
 * Returns true if the request passes all checks.
 * Sends a 4xx error response and returns false on failure.
 */
export function validateCsrfAndOrigin(req, res, csrfToken) {
  const headers = req.headers || {};
  const host = headers.host;
  const origin = headers.origin;
  const referer = headers.referer;

  if (origin && host) {
    try {
      const originUrl = new URL(origin);
      if (originUrl.host !== host) {
        sendJson(res, 403, { error: 'Forbidden cross-origin request' });
        return false;
      }
    } catch {
      sendJson(res, 400, { error: 'Invalid Origin header' });
      return false;
    }
  } else if (referer && host) {
    try {
      const refererUrl = new URL(referer);
      if (refererUrl.host !== host) {
        sendJson(res, 403, { error: 'Forbidden cross-origin request' });
        return false;
      }
    } catch {
      // Skip malformed referers
    }
  }

  if (req.method === 'POST') {
    const csrfHeader = headers['x-csrf-token'];
    if (!csrfHeader || csrfHeader !== csrfToken) {
      sendJson(res, 403, { error: 'Forbidden: CSRF token mismatch' });
      return false;
    }
  }

  return true;
}
