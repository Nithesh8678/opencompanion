import test from 'node:test';
import assert from 'node:assert/strict';
import {validateRequest, scopedNavigation, isProtectedField} from './protocol.mjs';

test('requires bounded versioned browser requests and explicit tab scope', () => {
  const valid = {protocolVersion: 1, type: 'browser.request', requestID: 'request_1', tabID: 42, operation: 'snapshot'};
  assert.equal(validateRequest(valid), valid);
  for (const patch of [{protocolVersion: 2}, {type: 'exec'}, {requestID: ''}, {tabID: '42'}, {operation: 'eval'}, {requestID: 'x'.repeat(129)}]) assert.throws(() => validateRequest({...valid, ...patch}));
  assert.throws(() => validateRequest({...valid, payload: 'x'.repeat(1024 * 1024)}));
});
test('navigation stays on the explicitly connected web origin', () => {
  assert.equal(scopedNavigation('https://example.com/next', 'https://example.com'), 'https://example.com/next');
  for (const url of ['https://elsewhere.example/', 'javascript:alert(1)', 'file:///etc/passwd', 'https://user:password@example.com/']) assert.throws(() => scopedNavigation(url, 'https://example.com'));
});
test('protected browser fields cannot be filled or exposed', () => {
  for (const field of [{type: 'password'}, {type: 'file'}, {type: 'text', autocomplete: 'cc-number'}, {type: 'text', autocomplete: 'one-time-code'}]) assert.equal(isProtectedField(field), true);
  assert.equal(isProtectedField({type: 'text', autocomplete: 'name'}), false);
});
