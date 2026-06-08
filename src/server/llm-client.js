function stripReasoningTags(text) {
  return text.replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
}

function isAnthropicMessagesApi(apiUrl) {
  try {
    const url = new URL(apiUrl);
    return url.hostname === 'api.anthropic.com' && /\/messages\/?$/i.test(url.pathname);
  } catch {
    return false;
  }
}

function buildAnthropicRequestBody({ config, messages }) {
  const system = messages
    .filter((message) => message && message.role === 'system')
    .map((message) => message.content)
    .filter((content) => typeof content === 'string' && content.trim())
    .join('\n\n');

  const anthropicMessages = messages
    .filter((message) => message && message.role !== 'system')
    .map((message) => ({
      role: message.role === 'assistant' ? 'assistant' : 'user',
      content: typeof message.content === 'string' ? message.content : String(message.content || '')
    }));

  const maxTokens = Number(config.maxTokens);
  const requestBody = {
    model: config.model,
    messages: anthropicMessages,
    max_tokens: Number.isFinite(maxTokens) && maxTokens > 0 ? maxTokens : 1024
  };

  if (system) {
    requestBody.system = system;
  }

  if (Number.isFinite(config.temperature)) {
    requestBody.temperature = config.temperature;
  }

  return requestBody;
}

function extractAnthropicText(payload) {
  const content = payload?.content;
  if (Array.isArray(content)) {
    return content
      .filter((item) => item && item.type === 'text' && typeof item.text === 'string')
      .map((item) => item.text)
      .join('');
  }

  if (typeof content === 'string') {
    return content;
  }

  return '';
}

export async function callChatCompletions({ config, messages, fetchImpl = fetch }) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs);

  try {
    const useAnthropicMessagesApi = isAnthropicMessagesApi(config.apiUrl);
    const requestBody = useAnthropicMessagesApi
      ? buildAnthropicRequestBody({ config, messages })
      : {
          model: config.model,
          messages,
          temperature: config.temperature
        };

    if (!useAnthropicMessagesApi && Number.isFinite(config.maxTokens) && config.maxTokens > 0) {
      requestBody.max_tokens = config.maxTokens;
    }

    const headers = {
      'Content-Type': 'application/json'
    };

    if (useAnthropicMessagesApi) {
      headers['x-api-key'] = config.apiKey;
      headers['anthropic-version'] = '2023-06-01';
    } else {
      headers.Authorization = `Bearer ${config.apiKey}`;
    }

    const response = await fetchImpl(config.apiUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(requestBody),
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
    let content = useAnthropicMessagesApi
      ? extractAnthropicText(payload)
      : payload?.choices?.[0]?.message?.content;
    
    if (Array.isArray(content)) {
      content = content
        .filter(item => item && (item.type === 'text' || typeof item.text === 'string'))
        .map(item => item.text || '')
        .join('');
    }

    if (typeof content === 'string') {
      content = stripReasoningTags(content);
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
