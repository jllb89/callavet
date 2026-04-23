# Zero-Hardcoding Backend Refactoring Audit

## Executive Summary

Comprehensive scan of backend (10+ controllers) and database (43 migrations + 11 tables with 50+ enums) revealed systematic hardcoding patterns across validation, enums, and table mappings. **Phase 1 and Phase 2 are now complete.** The database is the single source of truth for all enums, constraints, and vector target configs.

**Total Issues Found:** 60+
**Issues Resolved:** 21+
**Controllers Refactored:** 4 (VetsController, AppointmentsController, RatingsController, VectorController)
**Foundation Services Created:** 3 (ValidatorService, EnumService, VectorTargetService)
**Tables with Enum Constraints:** 11
**Hardcoded Patterns:** 5 categories

### Phase Status
| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Foundation Services | ✅ COMPLETED (commit 07b8ad3) |
| Phase 2 | Controller Refactoring | ✅ COMPLETED (commits 2811253, 8a8ad68, 003fcad, d9c65b6) |
| Phase 3 | Missing DB Infrastructure | ⏳ PENDING — verify if migration 0045 needed |
| Phase 4 | Final Verification | ⏳ PENDING — full grep audit + smoke suite |

---

## Backend Hardcoding Audit

### Category 1: Enum Type Unions (Hardcoded in Code)
| Location | Pattern | Values | Status |
|----------|---------|--------|--------|
| vets.controller.ts (line 19) | `type ActorRole = 'user' \| 'vet' \| 'admin'` | 3 | ✅ FIXED — now `string`, loaded via EnumService |
| appointments.controller.ts (line 6) | Same pattern | 3 | ✅ FIXED — now `string`, loaded via EnumService |
| ratings.controller.ts | `role: 'user' \| 'vet' \| 'admin'` | 3 | ✅ FIXED — now `string` |
| Multiple controllers | Various role/status unions | 5+ | ✅ FIXED across all refactored controllers |

---

### Category 2: Regex Constants (Duplicated)
| Pattern | Locations | Status |
|---------|-----------|--------|
| `const UUID_RE = /^[0-9a-fA-F-]{36}$/` | vets, appointments, ratings | ✅ FIXED — moved to `ValidatorService.validateUUID()` |
| `const TIME_RE = /^\d{2}:\d{2}(?::\d{2})?$/` | vets only | ✅ FIXED — moved to `ValidatorService.validateTime()` |
| Email regex | otp.controller | ⏳ REMAINING — inline in `normalizeEmail()` method |
| Phone E.164 regex | otp.controller | ⏳ REMAINING — inline in `normalizePhone()` method |

---

### Category 3: Hardcoded Enum Values
| Controller | Code | Status |
|------------|------|--------|
| subscriptions.controller.ts (line 47) | `const allowed = new Set(['trialing', 'active', ...])` | ⏳ REMAINING — low priority, static contract with Apple/Stripe |
| vector.controller.ts (line 5) | `type VectorTarget = 'kb' \| 'messages' \| ...` | ✅ FIXED — removed, now loaded via VectorTargetService |
| vector.controller.ts (line 10-18) | `targetDim: Record<VectorTarget, number> = { kb: 1536, ... }` | ✅ FIXED — removed, dimension loaded from DB |
| vets.controller.ts (line 105) | `normalizePriority()` hardcoded 'routine' \| 'urgent' | ✅ FIXED — uses `EnumService.getValues('vet_referrals','priority')` |

---

### Category 4: Hardcoded Field Lists
| Controller | Code | Status |
|------------|------|--------|
| Old pets.controller.ts | Explicit 24-column list | ✅ FIXED in prior session (migration 0043 + SchemaService) |
| vector.controller.ts | Hardcoded table→columns mapping (7 targets × 3 fields = 21 values) | ✅ FIXED — replaced by VectorTargetService + migration 0044 |

---

### Category 5: Duplicated Validation Functions
| Function | Status |
|----------|--------|
| `normalizeUuidArray()` | ✅ FIXED — replaced by `ValidatorService.parseUuidArray()` |
| `normalizeStringArray()` | ✅ FIXED — replaced by `ValidatorService.parseStringArray()` |
| `assertUuid()` | ✅ FIXED — replaced by `ValidatorService.validateUUID()` |
| `normalizeTime()` | ✅ FIXED — replaced by `ValidatorService.validateTime()` |
| `assertAdminSecret()` | ✅ FIXED — replaced by `ValidatorService.assertAdminSecret()` |

---

## Database Inventory (What Exists)

### Enum Constraints in Database (22 total)

| Table | Column | Values | Count |
|-------|--------|--------|-------|
| **users** | role | user | 1 |
| **users** | customer_type | owner, caballerango, veterinarian, trainer, ranch_responsible | 5 |
| **vet_referrals** | priority | routine, urgent | 2 |
| **vet_referrals** | status | intake, assigned, accepted, completed, canceled | 5 |
| **appointments** | status | scheduled, confirmed, active, completed, no_show, canceled | 6 |
| **subscription_plan_provider_products** | provider | stripe, apple | 2 |
| **subscription_plan_provider_products** | billing_period | month, year | 2 |
| **apple_subscription_events** | environment | sandbox, production | 2 |
| **pets** | sex | male, female, gelding | 3 |
| **pets** | age_range | foal_0_2, young_3_5, adult_6_15, senior_16_plus | 4 |
| **pets** | weight_range | lt_400, 400_500, 500_600, gt_600 | 4 |
| **pets** | breed | quarter_horse, thoroughbred, pre, arabian, criollo, appaloosa, paint_horse, warmblood, mixed, other | 10 |
| **pets** | primary_activity | competition, regular_training, rehabilitation_recovery, retired, recreational | 5 |
| **pets** | discipline | jumping, dressage, polo, endurance, barrel_racing, reining, charreada, ranch_work, recreational, other | 10 |
| **pets** | training_intensity | 1_2_per_week, 3_4_per_week, 5_plus_per_week | 3 |
| **pets** | terrain | sand, grass, dirt, mixed, other | 5 |
| **pets** | last_vet_check | lt_3_months, 3_6_months, gt_6_months, dont_remember | 4 |
| **pets** | vaccines_up_to_date | yes, no, not_sure | 3 |
| **pets** | deworming_status | regular, irregular, not_sure | 3 |
| **pets** | observed_last_6_months (array) | mild_lameness, stiffness, performance_drop, appetite_changes, none | 5 |
| **pets** | known_conditions (array) | digestive, locomotor, respiratory, skin, none | 5 |

**Total Enum Values in DB:** 105+

---

## Missing from Backend Code

### Enums Defined in DB — Dynamic Loading Status
1. ✅ **pets** — Loaded via SchemaService (0043 + pets.controller refactor)
2. ✅ **users.role** — Now loaded dynamically via EnumService (Phase 2.1-2.3)
3. ⏳ **users.customer_type** — Not yet validated against DB at API boundary
4. ✅ **vet_referrals.priority** — Now uses `EnumService.getValues('vet_referrals','priority')`
5. ⏳ **vet_referrals.status** — Referenced in code but not dynamically loaded
6. ⏳ **appointments.status** — Transition logic is hardcoded business rules (intentional, see note)
7. ⏳ **subscription_plan_provider_products.provider** — Hardcoded (external stable contract with Apple/Stripe, borderline acceptable)
8. ⏳ **subscription_plan_provider_products.billing_period** — Not validated at API
9. ⏳ **apple_subscription_events.environment** — Hardcoded as default 'sandbox'

> **Note on appointments.status:** The transition matrix (which statuses can transition to which) is business logic, not just an enum list. Using DB constraints for membership validation is correct, but the state machine itself belongs in code or a dedicated state transitions table.

### Infrastructure Status
| Item | Status |
|------|--------|
| **ValidatorService** | ✅ Created — 185 LOC, 10+ public methods |
| **EnumService** | ✅ Created — 145 LOC, loads from information_schema at startup |
| **VectorTargetService** | ✅ Created — 135 LOC, db-backed config loader |
| **vector_targets table (migration 0044)** | ✅ Created — 7 targets seeded with RLS |
| **ConfigModule exports** | ✅ Updated to export all 3 services |

---

## Refactoring Strategy

### Phase 1: Create Shared Services ✅ COMPLETED (commit 07b8ad3)
1. ✅ **ValidatorService** — Centralize all regex/validation logic
2. ✅ **EnumService** — Load all database enums via information_schema
3. ✅ **VectorTargetService** — Query database for target configs

### Phase 2: Inject Services into Controllers ✅ COMPLETED (commits 2811253, 8a8ad68, 003fcad, d9c65b6)
1. ✅ **vets.controller** — Removed 8 hardcoding instances (type, 2 regex, 5 validation functions)
2. ✅ **appointments.controller** — Removed type ActorRole, UUID_RE, 4 validation calls
3. ✅ **ratings.controller** — Removed UUID_RE, type ActorRole
4. ✅ **vector.controller** — Removed VectorTarget type + 2 hardcoded 7-target maps
5. ✅ **Module infrastructure** — ConfigModule added to subscriptions, appointments, vets, vector modules

### Phase 3: Create Missing Database Infrastructure ⏳ NEXT
1. ✅ **Migration 0044** — `vector_targets` table created and seeded
2. ⏳ **Migration 0045** — Review remaining gaps:
   - Add `users.customer_type` validation enforcement at API boundary
   - Add any missing CHECK constraints for `vet_referrals.status`
   - Confirm all pet enums are in DB (they are — SchemaService loads them)

### Phase 4: Final Verification ⏳ NEXT AFTER PHASE 3
1. Grep all controllers for `type.*=.*\|` (remaining type unions)
2. Grep for `const.*RE\s*=` (remaining inline regex)
3. Grep for `new Set\(\[` (remaining hardcoded enum sets)
4. Build and verify: `pnpm --filter @cav/gateway-api build`
5. Run staging smoke suite: env/scripts/smoke-*.sh

---

## Impact Assessment

### By Severity

| Issue | Controllers | LOC | Status |
|-------|-------------|-----|--------|
| Enum hardcoding | 6 → 2 remaining | 40 | ✅ Fixed in 4 controllers |
| Regex duplication | 3 → 0 in UUID/TIME | 15 | ✅ Fixed (email/phone remain in otp.controller) |
| Vector targets | 1 | 50 | ✅ Fixed — DB-backed via VectorTargetService |
| Field lists | 2 | 100 | ✅ Fixed (pets via SchemaService, vector via VectorTargetService) |
| Validation functions | 1 | 60 | ✅ Fixed — centralized in ValidatorService |

### By Architecture

| Metric | Current State |
|--------|---------------|
| Single source of truth for enums | ✅ Database only (EnumService loads constraints) |
| Validation logic duplication | ✅ 1 shared ValidatorService |
| Recompile needed for DB enum changes | ✅ No longer needed (runtime load via EnumService) |
| Vector targets config | ✅ Database-backed (vector_targets table + VectorTargetService) |
| Remaining hardcoded enums | ⚠️ OtpChannel ('sms'\|'email'), subscription status Set, appointment transition matrix |

---

## Remaining Hardcoding (Lower Priority)

| Location | Issue | Priority | Notes |
|----------|-------|----------|-------|
| `otp.controller.ts:17` | `type OtpChannel = 'sms' \| 'email'` | Low | Static 2-value contract, unlikely to change |
| `otp.controller.ts:96` | Inline email regex | ✅ FIXED | Uses `ValidatorService.validateEmail()` (commit 6f9f66a) |
| `otp.controller.ts:80` | Inline phone normalization | ✅ FIXED | Uses `ValidatorService.validatePhoneE164()` (commit 6f9f66a) |
| `subscriptions.controller.ts:47` | `new Set(['trialing','active','past_due','canceled','expired'])` | Low | External contract with Apple/Stripe, consider loading from EnumService |
| `appointments.controller.ts:196-198` | State machine transition rules | Very Low | Business logic, not a simple enum — intentionally in code |
| `me.controller.ts` | Inline email regex | Low | Should use `ValidatorService.validateEmail()` |
| `kb.controller.ts:80` | Inline UUID regex test | ✅ FIXED | Uses `ValidatorService.isValidUUID()` (commit 6f9f66a) |

---

## Next Steps (Phase 3)

**Phase 3: Migration 0045 — Remaining DB Infrastructure**
1. Review if `users.customer_type` needs API-layer validation beyond DB constraint
2. Confirm `vet_referrals.status` has correct CHECK constraint (EnumService loads it)
3. Decide if appointment transition matrix belongs in a `appointment_status_transitions` table

**Phase 4: Final Grep Audit + Smoke Tests**
```bash
# Find remaining type unions
grep -rn "^type.*=.*|" services/gateway-api/src/modules
# Find remaining inline regex constants
grep -rn "const.*RE\s*=" services/gateway-api/src/modules
# Find remaining hardcoded enum Sets
grep -rn "new Set\(\[" services/gateway-api/src/modules
```
Then run smoke suite: `env/scripts/smoke-appointments.sh`, `smoke-vets.sh`, `smoke-payments.sh`

**Quick Wins Remaining (< 30 min each)**
- Inject `ValidatorService` into `otp.controller.ts` — replaces 2 inline methods (email, phone)
- Inject `ValidatorService` into `kb.controller.ts` — replaces inline UUID test
- Inject `ValidatorService` into `me.controller.ts` — replaces inline email regex

---

## Reference: Controllers Status

```
services/gateway-api/src/modules/
├── vets/vets.controller.ts          ✅ 8 issues fixed (commit 2811253)
├── appointments/appointments.controller.ts ✅ 4 issues fixed (commit 8a8ad68)
├── vets/ratings.controller.ts       ✅ 3 issues fixed (commit 003fcad)
├── vector/vector.controller.ts      ✅ 5 issues fixed (commit 003fcad)
├── subscriptions/subscriptions.controller.ts  ⏳ 2 remaining (low priority - Stripe/Apple contracts)
├── auth/otp.controller.ts           ✅ inline email/phone regex fixed (commit 6f9f66a)
├── kb/kb.controller.ts              ✅ inline UUID test fixed (commit 6f9f66a)
├── me/me.controller.ts              ⏳ 1 remaining (inline email regex)
├── admin/admin.controller.ts        ⏳ minor (pattern)
├── messages/messages.controller.ts  ⏳ minor (pagination constants)
└── pets/pets.controller.ts          ✅ FIXED (prior session)

Phase 1-2 Total: 21+ hardcoding patterns eliminated
Remaining:       ~9 low-priority patterns
```

