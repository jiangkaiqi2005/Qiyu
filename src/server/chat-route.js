import { buildPromptContext } from '../qiyu/prompt-context.js';
import { assertNoForbiddenPhrase } from '../qiyu/persona.js';
import { classifySafety } from '../qiyu/safety.js';
import { createQiyuReply } from '../qiyu/engine.js';
import { rememberFactsFromText } from '../qiyu/memory-extraction.js';
import { recordTurn } from '../qiyu/state.js';
import { buildSystemPrompt } from './system-prompt.js';
import { callChatCompletions } from './llm-client.js';
import { inferRelationshipStage } from '../qiyu/relationship.js';

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
    if (safety.kind !== 'normal') {
      const result = fallbackReply(text, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: result.debug,
        source: 'local',
        fallbackReason: 'safety'
      });
      return;
    }

    if (!runtimeConfig.hasLlm) {
      const result = fallbackReply(text, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: result.debug,
        source: 'local',
        fallbackReason: 'no_llm_config'
      });
      return;
    }

    // 1. Sandbox User Input to prevent jailbreaking / structural tag injection
    const sanitizedText = text.replace(/<\/?[a-zA-Z_]+>/g, '');

    // 2. Process user turn and memory first to solve off-by-one update latency
    const stateWithMemory = rememberFactsFromText(state, sanitizedText);
    const withUserTurn = recordTurn(stateWithMemory, 'user', sanitizedText);

    // 3. Update relationship stage using sticky, non-downgrading weights
    const inferredStage = inferRelationshipStage(withUserTurn);
    const currentStage = state.relationshipStage || '初识';
    const stageWeights = { '初识': 0, '熟悉': 1, '朋友': 2, '深交': 3 };
    const nextStage = stageWeights[currentStage] > stageWeights[inferredStage] ? currentStage : inferredStage;

    const activeState = { ...withUserTurn, relationshipStage: nextStage };

    const systemPrompt = buildSystemPrompt(productSoul);
    
    // 4. includeHistory: false avoids double duplication of history in LLM query
    const context = buildPromptContext({ state: activeState, userText: sanitizedText, includeHistory: false });
    const recentTurns = (stateWithMemory.turns || []).slice(-8).map((turn) => ({
      role: turn.speaker === 'user' ? 'user' : 'assistant',
      content: turn.text
    }));

    const start = Date.now();
    let llmText;
    try {
      llmText = await callChatCompletions({
        config: runtimeConfig.llm,
        messages: [
          { role: 'system', content: systemPrompt },
          context,
          ...recentTurns,
          { role: 'user', content: sanitizedText }
        ],
        fetchImpl
      });
      assertNoForbiddenPhrase(llmText);
      const latencyMs = Date.now() - start;

      const nextState = recordTurn(activeState, 'qiyu', llmText);

      sendJson(res, 200, {
        messages: llmText.split('\n').filter(Boolean),
        nextState,
        debug: { mode: 'llm', relationshipStage: nextStage },
        source: 'llm',
        latencyMs
      });
    } catch (error) {
      const latencyMs = Date.now() - start;
      const fallbackReason = error.message.includes('Forbidden qiyu phrase')
        ? 'forbidden_phrases'
        : 'llm_error';
      const providerError = error.message;

      // 5. Graceful fallback on forbidden phrases or API failures to prevent 500 DoS crashes
      const result = fallbackReply(sanitizedText, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: { ...result.debug, error: error.message },
        source: 'local',
        fallbackReason,
        providerError,
        latencyMs
      });
    }
  } catch (error) {
    // Sanitize stack traces to avoid absolute server path exposures
    sendJson(res, 500, { error: 'Internal Server Error' });
  }
}
