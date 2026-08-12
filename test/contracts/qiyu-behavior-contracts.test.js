import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Readable, Writable } from 'node:stream';
import { handleChatRequest } from '../../src/server/chat-route.js';
import { createInitialState } from '../../src/qiyu/state.js';

const fixtureUrl = new URL('../../contracts/qiyu_behavior_contracts.json', import.meta.url);

function requestWithJson(body) {
  const request = Readable.from([JSON.stringify(body)]);
  request.method = 'POST';
  request.url = '/api/chat';
  return request;
}

function captureResponse() {
  const chunks = [];
  const response = new Writable({
    write(chunk, encoding, callback) {
      chunks.push(Buffer.from(chunk));
      callback();
    }
  });
  response.statusCode = 200;
  response.headers = {};
  response.writeHead = (status, headers = {}) => {
    response.statusCode = status;
    response.headers = headers;
  };
  response.body = () => JSON.parse(Buffer.concat(chunks).toString('utf8'));
  return response;
}

function runtimeConfig(provider) {
  return {
    hasLlm: provider.configured,
    llm: {
      apiUrl: 'https://llm.example.test/v1/chat/completions',
      apiKey: 'fixture-key',
      model: 'fixture-model',
      temperature: 0.8,
      timeoutMs: 30_000
    }
  };
}

async function runFixture(fixture) {
  let providerCalls = 0;
  const request = requestWithJson({
    text: fixture.request.text,
    state: createInitialState('fixture-user')
  });
  const response = captureResponse();

  await handleChatRequest(request, response, {
    runtimeConfig: runtimeConfig(fixture.provider),
    productSoul: '# 栖语',
    fetchImpl: async () => {
      providerCalls += 1;
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            choices: [{ message: { content: fixture.provider.candidateReply } }]
          };
        }
      };
    }
  });

  return { body: response.body(), providerCalls };
}

const fixtures = JSON.parse(await readFile(fixtureUrl, 'utf8'));

for (const fixture of fixtures.cases) {
  test(`JavaScript behavior matches shared fixture: ${fixture.id}`, async () => {
    const { body, providerCalls } = await runFixture(fixture);

    assert.deepEqual(body.messages, fixture.expected.messages);
    assert.equal(body.source, fixture.expected.source);
    if (Object.hasOwn(fixture.expected, 'fallbackReason')) {
      assert.equal(body.fallbackReason, fixture.expected.fallbackReason);
    } else {
      assert.equal(body.fallbackReason, undefined);
    }
    assert.equal(body.debug.mode, fixture.expected.mode);
    assert.equal(body.debug.safety, fixture.expected.safety);
    assert.equal(body.nextState.relationshipStage, fixture.expected.relationshipStage);
    assert.deepEqual(
      body.nextState.turns.map(({ speaker, text }) => ({ speaker, text })),
      fixture.expected.turns
    );

    if (Object.hasOwn(fixture.expected, 'providerCalls')) {
      assert.equal(providerCalls, fixture.expected.providerCalls);
    } else if (fixture.id === 'crisis-bypasses-provider') {
      assert.equal(providerCalls, 0);
    }
  });
}
