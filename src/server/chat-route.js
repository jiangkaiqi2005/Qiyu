import { buildPromptContext } from '../qiyu/prompt-context.js';
import { assertNoForbiddenPhrase } from '../qiyu/persona.js';
import { classifySafety } from '../qiyu/safety.js';
import { createQiyuReply } from '../qiyu/engine.js';
import { rememberFactsFromText } from '../qiyu/memory-extraction.js';
import { recordTurn } from '../qiyu/state.js';
import { buildSystemPrompt } from './system-prompt.js';
import { callChatCompletions } from './llm-client.js';

async function readJsonBody(req, limitBytes = 65536) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (Buffer.byteLength(raw, 'utf8') > limitBytes) {
      throw new Error('Request body too large');
    }
  }
  return JSON.parse(raw || '{}');
}

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function fallbackReply(text, state) {
  const result = createQiyuReply(text, state);
  return { ...result, source: 'local' };
}

export async function handleChatRequest(req, res, { runtimeConfig, productSoul, fetchImpl = fetch }) {
  try {
    const body = await readJsonBody(req);
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    const state = body.state && typeof body.state === 'object' ? body.state : null;

    if (!text || !state) {
      sendJson(res, 400, { error: 'Expected JSON body with text and state' });
      return;
    }

    const safety = classifySafety(text);
    if (safety.kind !== 'normal' || !runtimeConfig.hasLlm) {
      const result = fallbackReply(text, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: result.debug,
        source: 'local'
      });
      return;
    }

    const stateWithMemory = rememberFactsFromText(state, text);
    const systemPrompt = buildSystemPrompt(productSoul);
    const context = buildPromptContext({ state: stateWithMemory, userText: text });
    const recentTurns = (stateWithMemory.turns || []).slice(-8).map((turn) => ({
      role: turn.speaker === 'user' ? 'user' : 'assistant',
      content: turn.text
    }));

    const llmText = await callChatCompletions({
      config: runtimeConfig.llm,
      messages: [
        { role: 'system', content: systemPrompt },
        context,
        ...recentTurns,
        { role: 'user', content: text }
      ],
      fetchImpl
    });

    assertNoForbiddenPhrase(llmText);
    const withUserTurn = recordTurn(stateWithMemory, 'user', text);
    const nextState = recordTurn(withUserTurn, 'qiyu', llmText);

    sendJson(res, 200, {
      messages: llmText.split('\n').filter(Boolean),
      nextState,
      debug: { mode: 'llm' },
      source: 'llm'
    });
  } catch (error) {
    sendJson(res, 500, { error: error.message });
  }
}
