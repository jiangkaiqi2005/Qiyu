import { buildPromptContext } from '../qiyu/prompt-context.js';
import {
  assertNoForbiddenPhrase,
  assertNoPersonaBoundary,
  ForbiddenPhraseError,
  PersonaBoundaryError
} from '../qiyu/persona.js';
import { classifySafety } from '../qiyu/safety.js';
import { createQiyuReply } from '../qiyu/engine.js';
import { rememberFactsFromText } from '../qiyu/memory-extraction.js';
import { recordTurn } from '../qiyu/state.js';
import { buildSystemPrompt } from './system-prompt.js';
import { callChatCompletions } from './llm-client.js';
import { inferRelationshipStage } from '../qiyu/relationship.js';
import { ModelResponseValidationError, normalizeModelReply } from '../qiyu/reply-delivery.js';
import { readJsonBody, sendJson, validateCsrfAndOrigin } from './http-utils.js';

function fallbackReply(text, state) {
  const result = createQiyuReply(text, state);
  return { ...result, source: 'local' };
}

export async function handleChatRequest(req, res, { runtimeConfig, productSoul, csrfToken, fetchImpl = fetch }) {
  try {
    if (req.method !== 'POST') {
      res.writeHead(405, { Allow: 'POST' });
      res.end('Method Not Allowed');
      return;
    }

    // Cross-site pages must not be able to spend the locally configured LLM quota
    if (!validateCsrfAndOrigin(req, res, csrfToken)) {
      return;
    }

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
        ...result,
        fallbackReason: safety.kind !== 'normal' ? 'safety' : 'no_llm_config'
      });
      return;
    }

    // 1. Sandbox User Input to prevent jailbreaking / structural tag injection
    const sanitizedText = text.replace(/<\/?[a-zA-Z_]+>/g, '');

    // 2. Process user turn and memory first to solve off-by-one update latency
    const stateWithMemory = rememberFactsFromText(state, sanitizedText);
    const withUserTurn = recordTurn(stateWithMemory, 'user', sanitizedText);

    // 3. Update relationship stage (inferRelationshipStage applies the sticky, non-downgrading max)
    const nextStage = inferRelationshipStage(withUserTurn);
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
      const latencyMs = Date.now() - start;

      const messages = normalizeModelReply(llmText);
      const visibleText = messages.join('\n');
      assertNoForbiddenPhrase(visibleText);
      assertNoPersonaBoundary(visibleText);
      const nextState = recordTurn(activeState, 'qiyu', visibleText);

      sendJson(res, 200, {
        messages,
        nextState,
        debug: { mode: 'llm', relationshipStage: nextStage },
        source: 'llm',
        latencyMs
      });
    } catch (error) {
      const latencyMs = Date.now() - start;
      const fallbackReason = error instanceof ForbiddenPhraseError
        ? 'forbidden_phrases'
        : error instanceof PersonaBoundaryError
          ? 'persona_boundary'
        : error instanceof ModelResponseValidationError
            ? error.fallbackReason
            : 'llm_error';
      const diagnosticCode = fallbackReason === 'llm_error'
        ? 'provider_request_failed'
        : fallbackReason;

      // 5. Graceful fallback on forbidden phrases or API failures to prevent 500 DoS crashes
      const result = fallbackReply(sanitizedText, state);
      sendJson(res, 200, {
        messages: result.messages,
        nextState: result.nextState,
        debug: { ...result.debug, error: diagnosticCode },
        source: 'local',
        fallbackReason,
        providerError: '模型服务暂时不可用',
        latencyMs
      });
    }
  } catch (error) {
    // Sanitize stack traces to avoid absolute server path exposures
    sendJson(res, 500, { error: 'Internal Server Error' });
  }
}
