#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const fixturePath = path.join(__dirname, '..', 'docs', 'service-rating-survey-fixtures.json');
const data = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

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

const expectedLabels = ['Excelente', 'Buena', 'Regular', 'Mala', 'Pésima'];
const expectedScores = [5, 4, 3, 2, 1];
assert(Array.isArray(data.scoreOptions), 'scoreOptions array exists');
for (const [index, label] of expectedLabels.entries()) {
  const option = data.scoreOptions[index];
  assert(option?.label === label, `score option ${index} label ${label}`);
  assert(option?.score === expectedScores[index], `score option ${label} score ${expectedScores[index]}`);
}

for (const state of data.states || []) {
  assert(typeof state.name === 'string' && state.name.length > 0, 'state has name');
  assert(['pending', 'accepted', 'deferred', 'dismissed', 'completed'].includes(state.initialStatus), `${state.name}: valid initialStatus`);
  assert(['deferred', 'dismissed', 'completed'].includes(state.expectedStatus), `${state.name}: valid expectedStatus`);
  if (state.action === 'later') {
    assert(state.expectedNextPromptHours === 24, `${state.name}: later defers 24 hours`);
  }
  if (state.action === 'dismiss') {
    assert(state.permanentForSession === true, `${state.name}: dismiss permanent`);
  }
  if (state.expectedStatus === 'completed') {
    assert(Number.isInteger(state.answers?.vetAssistanceScore), `${state.name}: vet score required`);
    assert(Number.isInteger(state.answers?.appServiceScore), `${state.name}: app score required`);
    assert(state.expectedRatingScore === state.answers.vetAssistanceScore, `${state.name}: ratings table uses vet score only`);
    assert(state.answers.appServiceScore !== undefined, `${state.name}: app score captured separately`);
  }
}

console.log(`Service rating survey fixture eval: PASS=${pass} FAIL=${fail}`);
if (fail > 0) process.exit(1);