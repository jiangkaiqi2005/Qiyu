export async function callChatCompletions({ config, messages, fetchImpl = fetch }) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs);

  try {
    const response = await fetchImpl(config.apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.apiKey}`
      },
      body: JSON.stringify({
        model: config.model,
        messages,
        temperature: config.temperature
      }),
      signal: controller.signal
    });

    if (!response.ok) {
      let bodyText = '';
      try {
        bodyText = await response.text();
      } catch {}

      let errorMessage = '';
      try {
        const parsed = JSON.parse(bodyText);
        if (parsed?.error?.message) {
          errorMessage = parsed.error.message;
        }
      } catch {}

      if (!errorMessage) {
        errorMessage = `LLM request failed: ${response.status} ${bodyText || response.statusText || ''}`;
      }
      throw new Error(errorMessage);
    }

    const payload = await response.json();
    let content = payload?.choices?.[0]?.message?.content;
    
    if (Array.isArray(content)) {
      content = content
        .filter(item => item && (item.type === 'text' || typeof item.text === 'string'))
        .map(item => item.text || '')
        .join('');
    }

    if (typeof content !== 'string' || !content.trim()) {
      throw new Error('LLM response missing message content');
    }

    return content.trim();
  } catch (err) {
    let msg = err.message || String(err);
    if (err.name === 'AbortError' || msg.includes('aborted')) {
      msg = `LLM request timeout after ${config.timeoutMs}ms`;
    }
    if (config.apiKey && config.apiKey.length > 3) {
      msg = msg.split(config.apiKey).join('[redacted]');
    }
    throw new Error(msg);
  } finally {
    clearTimeout(timeout);
  }
}
