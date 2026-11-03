export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 1024 * 1024;
export const OPERATIONS = new Set(['snapshot', 'act', 'navigate', 'capture', 'stop']);
export function validateRequest(message) {
  if (!message || message.protocolVersion !== 1 || message.type !== 'browser.request') throw new Error('Unsupported browser protocol.');
  if (typeof message.requestID !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(message.requestID)) throw new Error('Invalid requestID.');
  if (!OPERATIONS.has(message.operation)) throw new Error('Unsupported browser operation.');
  if (message.operation !== 'stop' && !Number.isSafeInteger(message.tabID)) throw new Error('A connected tabID is required.');
  if (JSON.stringify(message).length > MAX_MESSAGE_BYTES) throw new Error('Request exceeds limit.');
  return message;
}
export function scopedNavigation(value, origin) {
  const url = new URL(value);
  if (!['https:', 'http:'].includes(url.protocol) || url.origin !== origin || url.username || url.password) throw new Error('Navigation requires the connected origin. Connect the destination tab manually for a new origin.');
  return url.href;
}
export function isProtectedField(element) {
  const type = String(element.type || '').toLowerCase();
  const autocomplete = String(element.autocomplete || '').toLowerCase();
  return ['password', 'file', 'hidden'].includes(type) || /(?:password|cc-|one-time-code)/.test(autocomplete);
}
