#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_FILE="$ROOT_DIR/docs/ai-chat-action-ux-fixtures.json"
SERVICE_FILE="$ROOT_DIR/services/gateway-api/dist/modules/ai/ai.service.js"

if [[ ! -f "$SERVICE_FILE" ]]; then
  echo "ERROR: gateway build output missing. Run: pnpm --filter @cav/gateway-api run build" >&2
  exit 1
fi

node - "$FIXTURE_FILE" "$SERVICE_FILE" <<'NODE'
const fs = require('fs');
const [fixtureFile, serviceFile] = process.argv.slice(2);
const { AiService } = require(serviceFile);
const fixtures = JSON.parse(fs.readFileSync(fixtureFile, 'utf8'));
const service = new AiService({}, {}, {}, {}, {});
const context = {
  actorUserId: '00000000-0000-0000-0000-000000000000',
  petId: null,
  sessionId: null,
  conversationId: null,
  user: null,
  pets: [],
  subscription: null,
  recentConversations: [],
};

for (const item of fixtures.cases) {
  const payload = service.normalizeChatTurnPayload(
    JSON.parse(JSON.stringify(item.payload)),
    context,
    item.latestMessage,
    item.state,
    []
  );
  const actionUx = service.chatActionUxEventMetadata(payload);
  const expect = item.expect || {};
  if (expect.nextStep && payload.nextStep !== expect.nextStep) {
    throw new Error(`${item.id}: expected nextStep ${expect.nextStep}, got ${payload.nextStep}`);
  }
  if ('recommendedService' in expect && (payload.recommendedService ?? null) !== expect.recommendedService) {
    throw new Error(`${item.id}: expected recommendedService ${expect.recommendedService}, got ${payload.recommendedService}`);
  }
  if ('intakeQuestionsMin' in expect && payload.intakeQuestions.length < expect.intakeQuestionsMin) {
    throw new Error(`${item.id}: expected at least ${expect.intakeQuestionsMin} intake questions`);
  }
  if ('intakeQuestionsMax' in expect && payload.intakeQuestions.length > expect.intakeQuestionsMax) {
    throw new Error(`${item.id}: expected at most ${expect.intakeQuestionsMax} intake questions, got ${payload.intakeQuestions.length}`);
  }
  if (expect.noNumberedList && payload.displayBlocks.some((block) => block.type === 'numbered_list')) {
    throw new Error(`${item.id}: numbered_list remained on action turn`);
  }
  if (expect.mixedQuestionActionState === false && actionUx.mixedQuestionActionState) {
    throw new Error(`${item.id}: mixed question/action state remained`);
  }
}

console.log(JSON.stringify({ ok: true, cases: fixtures.cases.length }, null, 2));
NODE