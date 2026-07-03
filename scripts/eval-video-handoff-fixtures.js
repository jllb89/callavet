#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const fixturePath = path.join(root, 'docs', 'video-handoff-eval-fixtures.json');
const data = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const forbidden = (data.forbiddenPatterns || []).map((pattern) => new RegExp(pattern, 'i'));
const requiredHandoffFields = [
  'urgency',
  'summaryText',
  'reportedSigns',
  'redFlags',
  'questionsAnswered',
  'questionsUnanswered',
  'recommendedFirstChecks',
];

let pass = 0;
let fail = 0;

function assert(condition, message) {
  if (condition) {
    pass += 1;
    return;
  }
  fail += 1;
  console.error(`FAIL: ${message}`);
}

function textValues(value) {
  if (value == null) return [];
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(textValues);
  if (typeof value === 'object') return Object.values(value).flatMap(textValues);
  return [];
}

function validateFixture(fixture) {
  const prefix = fixture.id || '(missing id)';
  assert(typeof fixture.id === 'string' && fixture.id.length > 0, `${prefix}: id required`);
  assert(Array.isArray(fixture.messages) && fixture.messages.length > 0, `${prefix}: messages required`);
  assert(fixture.messages.some((message) => message.role === 'user'), `${prefix}: user message required`);
  assert(fixture.messages.some((message) => message.role === 'assistant'), `${prefix}: assistant message required`);
  assert(fixture.expectedHandoff && typeof fixture.expectedHandoff === 'object', `${prefix}: expectedHandoff required`);

  const handoff = fixture.expectedHandoff || {};
  for (const field of requiredHandoffFields) {
    assert(Object.prototype.hasOwnProperty.call(handoff, field), `${prefix}: expectedHandoff.${field} required`);
  }
  assert(['routine', 'urgent', 'emergency'].includes(handoff.urgency), `${prefix}: urgency enum`);
  assert(typeof handoff.summaryText === 'string' && handoff.summaryText.length >= 40, `${prefix}: summaryText useful length`);
  for (const field of ['reportedSigns', 'redFlags', 'questionsAnswered', 'questionsUnanswered', 'recommendedFirstChecks']) {
    assert(Array.isArray(handoff[field]), `${prefix}: ${field} array`);
  }
  for (const answer of handoff.questionsAnswered || []) {
    assert(typeof answer.question === 'string' && answer.question.length > 0, `${prefix}: answered question text`);
    assert(typeof answer.answer === 'string' && answer.answer.length > 0, `${prefix}: answered answer text`);
  }

  const allText = textValues(fixture).join('\n');
  for (const pattern of forbidden) {
    assert(!pattern.test(allText), `${prefix}: forbidden clinical claim pattern ${pattern}`);
  }
}

for (const fixture of data.fixtures || []) validateFixture(fixture);

console.log(`Video handoff fixture eval: PASS=${pass} FAIL=${fail}`);
if (fail > 0) process.exit(1);