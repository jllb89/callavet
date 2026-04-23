# Zero-Hardcoding Backend Refactoring Audit

## Executive Summary

Comprehensive scan of backend (10+ controllers) and database (43 migrations + 11 tables with 50+ enums) revealed systematic hardcoding patterns across validation, enums, and table mappings.

**Total Issues Found:** 60+
**Controllers Affected:** 10
**Tables with Enum Constraints:** 11
**Hardcoded Patterns:** 5 categories

---

## Backend Hardcoding Audit

### Category 1: Enum Type Unions (Hardcoded in Code)
| Location | Pattern | Values | Impact |
|----------|---------|--------|--------|
| vets.controller.ts (line 19) | `type ActorRole = 'user' \| 'vet' \| 'admin'` | 3 | Used in 5 methods |
| appointments.controller.ts (line 6) | Same pattern | 3 | Duplicated |
| Multiple controllers | Various role/status unions | 5+ | Scattered definitions |

**Problem:** If database adds new role, must edit 2+ controller files and rebuild

---

### Category 2: Regex Constants (Duplicated)
| Pattern | Locations | Count |
|---------|-----------|-------|
| `const UUID_RE = /^[0-9a-fA-F-]{36}$/` | vets, appointments, ratings | 3 |
| `const TIME_RE = /^\d{2}:\d{2}(?::\d{2})?$/` | vets only | 1 |
| `const EMAIL_RE = ...` | otp.controller | 1 |
| Phone E.164 regex | otp.controller | 1 |

**Problem:** Same validation logic repeated; bug fix requires patching 3+ files

---

### Category 3: Hardcoded Enum Values
| Controller | Code | Count |
|------------|------|-------|
| subscriptions.controller.ts (line 47) | `const allowed = new Set(['trialing', 'active', 'past_due', 'canceled', 'expired'])` | 1 |
| vector.controller.ts (line 5) | `type VectorTarget = 'kb' \| 'messages' \| ...` | 1 |
| vector.controller.ts (line 10-18) | `targetDim: Record<VectorTarget, number> = { kb: 1536, ... }` | All 1536 |
| vets.controller.ts (line 105) | `normalizePriority()` hardcoded 'routine' \| 'urgent' | 2 |

**Problem:** Adding new vector target or priority requires controller code change + recompile

---

### Category 4: Hardcoded Field Lists
| Controller | Code | Fields | Impact |
|------------|------|--------|--------|
| Old pets.controller.ts | Explicit `name, species, sex, ...` list | 24 | Hardcoded INSERT/UPDATE |
| Old vets.controller | Hardcoded availability fields | 4+ | Manual SQL building |
| vector.controller.ts | Hardcoded table→columns mapping | 7 targets × 3 fields each | 21 hardcoded values |

**Problem:** Changing pet schema required editing 24+ locations in controller

---

### Category 5: Duplicated Validation Functions
| Function | Locations | Purpose |
|----------|-----------|---------|
| `normalizeUuidArray()` | vets.controller | UUID array parsing |
| `normalizeStringArray()` | vets.controller | String array parsing |
| `assertUuid()` | vets.controller | UUID validation |
| `normalizeTime()` | vets.controller | HH:MM validation |
| `assertAdminSecret()` | vets.controller | Secret header check |

**Problem:** Copy-paste validation logic, inconsistent error messages, hard to audit

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

### Enums Defined in DB but NOT Loaded Dynamically
1. ✅ **pets** — NOW loaded via SchemaService (0043 + pets.controller refactor)
2. ❌ **users.role** — Hardcoded, should use EnumService
3. ❌ **users.customer_type** — Hardcoded, should use EnumService
4. ❌ **vet_referrals.priority** — Hardcoded in vets.controller
5. ❌ **vet_referrals.status** — Hardcoded reference exists
6. ❌ **appointments.status** — Hardcoded reference exists
7. ❌ **subscription_plan_provider_products.provider** — Hardcoded (external provider, borderline)
8. ❌ **subscription_plan_provider_products.billing_period** — Not validated
9. ❌ **apple_subscription_events.environment** — Hardcoded as default

### Infrastructure Gaps
1. ❌ **No shared ValidatorService** — UUID, email, phone, time patterns scattered
2. ❌ **No EnumService** — Enum values not loaded from database
3. ❌ **No VectorTargetService** — Vector config hardcoded in controller
4. ❌ **No vector_targets table** — Targets must be added to database

---

## Refactoring Strategy

### Phase 1: Create Shared Services (Unblocks Phase 2)
1. **ValidatorService** — Centralize all regex/validation logic
2. **EnumService** — Load all database enums via information_schema
3. **VectorTargetService** — Query database for target configs

### Phase 2: Inject Services into Controllers
1. **vets.controller** — Remove 5 hardcoded functions, inject services
2. **appointments.controller** — Remove ActorRole type, inject services
3. **subscriptions.controller** — Inject EnumService for status
4. **vector.controller** — Inject VectorTargetService for targets
5. **Other controllers** — Audit and inject as needed

### Phase 3: Create Missing Database Infrastructure
1. **Migration 0044** — Create `vector_targets` table
2. **Migration 0045** — Add any missing constraints

### Phase 4: Verification
1. Grep for hardcoded enums/patterns
2. Build and test
3. Run staging smoke suite

---

## Impact Assessment

### By Severity

| Issue | Controllers | LOC | Effort | Risk |
|-------|-------------|-----|--------|------|
| Enum hardcoding | 6 | 40 | High | Medium (data inconsistency) |
| Regex duplication | 3 | 15 | Low | Low (refactor-only) |
| Vector targets | 1 | 50 | Medium | Medium (breaking if wrong) |
| Field lists | 2 | 100 | Very High | Very High (data loss risk) |
| Validation functions | 1 | 60 | Low | Low (consolidation) |

### By Architecture

| Metric | Current State | Target State |
|--------|---------------|--------------|
| Single source of truth for enums | ❌ Split (DB + 6 controllers) | ✅ Database only |
| Validation logic duplication | ❌ 5+ functions scattered | ✅ 1 shared service |
| Recompile needed for DB changes | ❌ Yes (almost always) | ✅ No (runtime load) |
| Type safety | ⚠️ Partial (hardcoded types) | ✅ Full (schema-driven) |

---

## Estimated Effort

| Phase | Task | Lines | Hours | Effort |
|-------|------|-------|-------|--------|
| 1.1 | ValidatorService | 150 | 1-2 | Low |
| 1.2 | EnumService | 200 | 2-3 | Low |
| 1.3 | VectorTargetService | 100 | 1-2 | Low |
| 1.4 | ConfigModule | 30 | 1 | Low |
| 2.1 | VetsController refactor | 80 | 1-2 | Low |
| 2.2 | AppointmentsController refactor | 60 | 1-2 | Low |
| 2.3 | VectorController refactor | 40 | 1 | Low |
| 3.1 | 0044 migration | 40 | 1 | Low |
| 4.1 | Testing + verification | - | 2-3 | Medium |
| **TOTAL** | | **700** | **11-16 hours** | **Low-Medium** |

---

## Next Steps

1. **Confirm this roadmap** with team
2. **Execute Phase 1** services in parallel (ValidatorService, EnumService, VectorTargetService)
3. **Create 0044 migration** for vector_targets
4. **Refactor controllers one by one**, test after each
5. **Final audit** to ensure zero hardcoding

---

## Reference: Controllers with Issues

```
services/gateway-api/src/modules/
├── vets/vets.controller.ts (8 issues)
├── appointments/appointments.controller.ts (4 issues)
├── subscriptions/subscriptions.controller.ts (2 issues)
├── subscriptions/entitlements.controller.ts (1 issue)
├── vector/vector.controller.ts (5 issues)
├── ratings/ratings.controller.ts (1 issue)
├── auth/otp.controller.ts (3 issues)
├── admin/admin.controller.ts (potential)
├── messages/messages.controller.ts (potential)
├── me/me.controller.ts (potential)
└── pets/pets.controller.ts (FIXED ✅)

Total: 10 controllers, 60+ hardcoding patterns
```

