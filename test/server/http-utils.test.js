import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable, Writable } from 'node:stream';
import { readJsonBody, sendJson, validateCsrfAndOrigin } from '../../src/server/http-utils.js';

function reqWithBody(bodyStr) {
  const req = Readable.from([bodyStr]);
  req.method = 'POST';
  return req;
}

function captureRes() {
  const chunks = [];
  const res = new Writable({
    write(chunk, encoding, callback) {
      chunks.push(Buffer.from(chunk));
      callback();
    }
  });
  res.statusCode = 200;
  res.headers = {};
  res.writeHead = (status, headers = {}) => {
    res.statusCode = status;
    res.headers = headers;
  };
  res.body = () => Buffer.concat(chunks).toString('utf8');
  return res;
}

// ── readJsonBody ──────────────────────────────────────────────

test('readJsonBody parses a valid JSON body', async () => {
  const req = reqWithBody('{"text":"hello"}');
  const result = await readJsonBody(req);
  assert.deepEqual(result, { text: 'hello' });
});

test('readJsonBody throws on oversized body', async () => {
  const req = reqWithBody('{"x":"' + 'a'.repeat(70000) + '"}');
  await assert.rejects(
    () => readJsonBody(req, 65536),
    { message: 'Request body too large' }
  );
});

test('readJsonBody returns {} for empty body', async () => {
  const req = reqWithBody('');
  const result = await readJsonBody(req);
  assert.deepEqual(result, {});
});

test('readJsonBody throws on malformed JSON', async () => {
  const req = reqWithBody('not json{{');
  await assert.rejects(
    () => readJsonBody(req),
    /Unexpected token/
  );
});

test('readJsonBody respects custom limitBytes', async () => {
  const req = reqWithBody('{"x":"' + 'a'.repeat(200) + '"}');
  const result = await readJsonBody(req, 500);
  assert.equal(result.x.length, 200);
});

// ── sendJson ──────────────────────────────────────────────────

test('sendJson sets Content-Type header and writes JSON body', () => {
  const res = captureRes();
  sendJson(res, 201, { ok: true });

  assert.equal(res.statusCode, 201);
  assert.equal(res.headers['Content-Type'], 'application/json; charset=utf-8');
  assert.equal(res.body(), '{"ok":true}');
});

// ── validateCsrfAndOrigin ─────────────────────────────────────

test('validateCsrfAndOrigin returns true for matching origin and POST with valid CSRF', () => {
  const req = Readable.from([]);
  req.method = 'POST';
  req.headers = {
    host: 'localhost:3000',
    origin: 'http://localhost:3000',
    'x-csrf-token': 'token-abc'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, true);
});

test('validateCsrfAndOrigin returns false + 403 for cross-origin Origin', () => {
  const req = Readable.from([]);
  req.method = 'POST';
  req.headers = {
    host: 'localhost:3000',
    origin: 'http://evil.com'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, false);
  assert.equal(res.statusCode, 403);
  assert.match(res.body(), /Forbidden cross-origin/);
});

test('validateCsrfAndOrigin returns false + 400 for invalid Origin URL', () => {
  const req = Readable.from([]);
  req.method = 'GET';
  req.headers = {
    host: 'localhost:3000',
    origin: 'not-a-valid-url-!!!'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, false);
  assert.equal(res.statusCode, 400);
  assert.match(res.body(), /Invalid Origin header/);
});

test('validateCsrfAndOrigin returns false + 403 for missing CSRF on POST', () => {
  const req = Readable.from([]);
  req.method = 'POST';
  req.headers = {
    host: 'localhost:3000',
    origin: 'http://localhost:3000'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, false);
  assert.equal(res.statusCode, 403);
  assert.match(res.body(), /CSRF token mismatch/);
});

test('validateCsrfAndOrigin returns false + 403 for incorrect CSRF on POST', () => {
  const req = Readable.from([]);
  req.method = 'POST';
  req.headers = {
    host: 'localhost:3000',
    origin: 'http://localhost:3000',
    'x-csrf-token': 'wrong-token'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, false);
  assert.equal(res.statusCode, 403);
  assert.match(res.body(), /CSRF token mismatch/);
});

test('validateCsrfAndOrigin skips CSRF check for GET requests', () => {
  const req = Readable.from([]);
  req.method = 'GET';
  req.headers = {
    host: 'localhost:3000',
    origin: 'http://localhost:3000'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, true);
});

test('validateCsrfAndOrigin validates Referer when Origin is absent', () => {
  const req = Readable.from([]);
  req.method = 'POST';
  req.headers = {
    host: 'localhost:3000',
    referer: 'http://localhost:3000/some/path',
    'x-csrf-token': 'token-abc'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, true);
});

test('validateCsrfAndOrigin returns false + 403 for cross-origin Referer', () => {
  const req = Readable.from([]);
  req.method = 'GET';
  req.headers = {
    host: 'localhost:3000',
    referer: 'http://evil.com/phishing'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, false);
  assert.equal(res.statusCode, 403);
  assert.match(res.body(), /Forbidden cross-origin/);
});

test('validateCsrfAndOrigin silently skips malformed Referer', () => {
  const req = Readable.from([]);
  req.method = 'GET';
  req.headers = {
    host: 'localhost:3000',
    referer: ':::::not-a-url'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, true);
});

test('validateCsrfAndOrigin returns true when neither Origin nor Referer present', () => {
  const req = Readable.from([]);
  req.method = 'GET';
  req.headers = {
    host: 'localhost:3000'
  };
  const res = captureRes();

  const result = validateCsrfAndOrigin(req, res, 'token-abc');
  assert.equal(result, true);
});
