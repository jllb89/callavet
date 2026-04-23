# Gateway-API Hardcoding Patterns Audit

## Summary
Found **6 controllers** with **18+ hardcoding patterns** across type unions, regex patterns, enum/status checks, field lists, and duplicated validation functions.

---

## Detailed Findings by Controller

### 1. **subscriptions.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 47 | Enum values | `const allowed = new Set(['trialing', 'active', 'past_due', 'canceled', 'expired'])` | Subscription status values hardcoded | Easy - Move to config/service |
| 51 | Magic number | `30 * 24 * 60 * 60 * 1000` | Default 30-day trial period | Easy - Move to config constant |
| 234, 351, 386 | API version | `apiVersion: '2024-06-20'` | Stripe API version duplicated 3x | Easy - Extract to constant |
| 429 | Type mapping | `code.includes('video') ? 'video' : code.includes('chat') ? 'chat' : ...` | Type detection from code hardcoded | Medium - Extract to TypeMappingService |
| 612 | Status check | `status === 'paid' \|\| status === 'consumed'` | Hardcoded purchase status values | Easy - Create PurchaseStatusEnum |
| 685 | Status check | `prevStatus === 'paid'` | Hardcoded status comparison | Easy - Use enum |
| Multiple | Reason strings | `reason: 'provider_subscription_id_required'`, `reason: 'plan_mapping_missing'`, etc. | 15+ hardcoded error reason strings | Medium - Extract to ErrorReasonsEnum |

**Quick wins:** 1 hour total
- Extract `STRIPE_API_VERSION = '2024-06-20'` constant
- Create `SubscriptionStatusEnum` service
- Extract status-related error messages to enum

---

### 2. **admin.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 4 | Function | `function assertAdmin(secretHeader?: string) { const expected = process.env.ADMIN_PRICING_SYNC_SECRET \|\| process.env.ADMIN_SECRET \|\| ''; ... }` | Admin secret validation hardcoded in function | Easy - Extract to service |
| 78 | Type mapping | `body?.type === 'video' ? 'video_unit' : body?.type === 'chat' ? 'chat_unit' : ''` | Type-to-code mapping hardcoded | Easy - Move to config/enum |
| 146 | Test ID check | `pid.startsWith('test_') \|\| pid === 'test_payment_id'` | Test payment ID checks hardcoded | Easy - Move to config |
| 153 | API version | `apiVersion: '2024-06-20'` | Stripe API version (duplicate) | Easy - Use shared constant |
| 158-161 | Reason map | `{ 'requested_by_customer': 'requested_by_customer', 'duplicate': 'duplicate', 'fraudulent': 'fraudulent' }` | Refund reason mapping | Easy - Extract to enum/config |

**Quick wins:** 30 minutes total
- Extract `assertAdmin()` to AdminAuthService
- Create `OverageTypeCodeMappingEnum`
- Use shared Stripe version constant

---

### 3. **otp.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 17 | Type union | `type OtpChannel = 'sms' \| 'email'` | Channel type hardcoded (minor) | Very easy - Already typed |
| 80, 86-87 | Regex pattern | `/[^0-9+]/g`, `/[^0-9]/g` | Phone validation regexes hardcoded | Easy - Extract to validator service |
| 96 | Regex pattern | `/^[^@\s]+@[^@\s]+\.[^@\s]+$/` | Email validation regex hardcoded | Easy - Extract to validator service |
| 190 | Rate limit | `limit: 5, windowMs: 60_000, scope: 'ip'` | Rate limit hardcoded | Easy - Move to config |
| 193, 268, 307 | Validation | Repeated `if (channel !== 'sms' && channel !== 'email')` checks (3x) | Channel validation duplicated | Easy - Extract to guard or service |

**Quick wins:** 25 minutes total
- Create `PhoneValidatorService` with regex
- Create `EmailValidatorService` with regex
- Extract channel validation check to helper or use type guard
- Move rate-limit config to decorator or service config

---

### 4. **messages.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 22 | Pagination | `Math.min(Math.max(parseInt(limitStr \|\| '50', 10) \|\| 50, 1), 200)` | Default limit=50, max=200 hardcoded | Easy - Extract constant |
| 23 | Pagination | `Math.max(parseInt(offsetStr \|\| '0', 10) \|\| 0, 0)` | Default offset=0 hardcoded | Easy - Use constant |
| 28, 86 | Validation | `['1','true','yes'].includes(...)` (2x duplicated) | Boolean string parsing duplicated | Easy - Create helper function |
| 80 | Pagination | `parseInt(sessionsLimitStr \|\| '10', 10) \|\| 10, 1), 50` | Sessions limit=10, max=50 hardcoded | Easy - Use constant |
| 81 | Pagination | `parseInt(perLimitStr \|\| '100', 10) \|\| 100, 1), 500` | Per-limit=100, max=500 hardcoded | Easy - Use constant |

**Quick wins:** 20 minutes total
- Create `PaginationDefaults` constant/enum:
  ```ts
  MESSAGES_DEFAULT_LIMIT: 50
  MESSAGES_MAX_LIMIT: 200
  SESSIONS_DEFAULT_LIMIT: 10
  SESSIONS_MAX_LIMIT: 50
  ```
- Extract `parseQueryBoolean()` helper function
- Consolidate pagination logic to utility

---

### 5. **session-notes.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 45 | Rate limit | `key: 'sessions.notes.create', limit: 10, windowMs: 300_000` | Rate limit hardcoded (10req/5min) | Easy - Move to config |
| 55 | Validation | `length > 8000` (2x for summary + plan) | Max note length hardcoded | Easy - Extract to constant |

**Quick wins:** 15 minutes total
- Create `NotesLimits` config:
  ```ts
  MAX_SUMMARY_LENGTH: 8000
  MAX_PLAN_SUMMARY_LENGTH: 8000
  RATE_LIMIT_PER_WINDOW: 10
  RATE_LIMIT_WINDOW_MS: 300_000
  ```

---

### 6. **me.controller.ts**

| Line | Type | Pattern | Description | Fixability |
|------|------|---------|-------------|-----------|
| 55 | Placeholder | `` `${sub}@placeholder.local` `` | Fallback email domain hardcoded | Easy - Move to config |
| 313-316 | Regex pattern | `/^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$/` | Mexican RFC pattern hardcoded | Easy - Extract to validator service |
| 319, 327 | Default value | `?? 'es'` (2x) | Default language hardcoded as 'es' | Easy - Use config constant |
| 350 | API version | `apiVersion: '2024-06-20'` | Stripe API version (duplicate) | Easy - Use shared constant |
| 381 | Stripe param | `usage: 'off_session'` | Usage value hardcoded | Easy - Move to constant |

**Quick wins:** 20 minutes total
- Extract placeholder domain to config
- Create `TaxIdValidatorService` with RFC regex
- Create UserDefaults config with `DEFAULT_LANGUAGE: 'es'`
- Use shared Stripe version constant
- Create `StripeSetupIntentDefaults` with usage value

---

## Refactoring Recommendations (Quick Wins < 30min each)

### Phase 1: Extract Global Constants (15 minutes)
```ts
// lib/constants/stripe.constants.ts
export const STRIPE_API_VERSION = '2024-06-20';

// lib/constants/defaults.constants.ts
export const DEFAULTS = {
  USER_LANGUAGE: 'es',
  USER_EMAIL_PLACEHOLDER: '@placeholder.local',
  STRIPE_USAGE: 'off_session',
  TRIAL_PERIOD_DAYS: 30,
  TEST_PAYMENT_PREFIXES: ['test_', 'test_payment_id'],
};

// lib/constants/pagination.constants.ts
export const PAGINATION = {
  MESSAGES: { DEFAULT: 50, MAX: 200 },
  SESSIONS: { DEFAULT: 10, MAX: 50 },
  SESSIONS_PER_PAGE: { DEFAULT: 100, MAX: 500 },
};

// lib/constants/validation.constants.ts
export const VALIDATION = {
  SESSION_NOTES_MAX_LENGTH: 8000,
  REFUND_REASONS: ['requested_by_customer', 'duplicate', 'fraudulent'],
};

// lib/constants/rate-limits.constants.ts
export const RATE_LIMITS = {
  OTP_SEND: { limit: 5, windowMs: 60_000 },
  SESSION_NOTES_CREATE: { limit: 10, windowMs: 300_000 },
};
```

### Phase 2: Extract Type/Enum Mappings (20 minutes)
```ts
// lib/enums/subscription-status.enum.ts
export const SUBSCRIPTION_STATUSES = {
  TRIALING: 'trialing',
  ACTIVE: 'active',
  PAST_DUE: 'past_due',
  CANCELED: 'canceled',
  EXPIRED: 'expired',
} as const;

// lib/enums/overage-type-mapping.enum.ts
export const OVERAGE_TYPE_CODE_MAP = {
  'video': 'video_unit',
  'chat': 'chat_unit',
} as const;

export const CODE_TO_TYPE_MAP = {
  'video_unit': 'video',
  'chat_unit': 'chat',
  'chat': 'chat',
  'video': 'video',
  'sms': 'sms',
} as const;

// lib/enums/purchase-status.enum.ts
export const PURCHASE_STATUSES = {
  CHECKOUT_CREATED: 'checkout_created',
  PAID: 'paid',
  CONSUMED: 'consumed',
} as const;
```

### Phase 3: Extract Validation Functions (25 minutes)
```ts
// lib/validators/otp-validation.service.ts
@Injectable()
export class OtpValidationService {
  private readonly PHONE_REGEX = /[^0-9+]/g;
  private readonly EMAIL_REGEX = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
  private readonly VALID_CHANNELS = new Set(['sms', 'email']);

  validatePhoneFormat(e164: string): boolean { ... }
  validateEmailFormat(email: string): boolean { ... }
  isValidChannel(channel: string): boolean {
    return this.VALID_CHANNELS.has(channel);
  }
}

// lib/validators/tax-id-validator.service.ts
@Injectable()
export class TaxIdValidatorService {
  private readonly MX_RFC_REGEX = /^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$/;
  validateMxRfc(taxId: string): boolean { ... }
}

// lib/helpers/pagination.helper.ts
export function normalizePaginationParams(
  limitStr?: string,
  offsetStr?: string,
  defaults = { limit: 50, maxLimit: 200 }
) {
  const limit = Math.min(Math.max(parseInt(limitStr || defaults.limit.toString(), 10) || defaults.limit, 1), defaults.maxLimit);
  const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
  return { limit, offset };
}

export function parseQueryBoolean(value?: string): boolean {
  return ['1', 'true', 'yes'].includes((value || '').toLowerCase());
}
```

---

## Implementation Priority

| Priority | Task | Effort | Impact |
|----------|------|--------|--------|
| **High** | Extract shared Stripe API version constant | 5 min | Reduces duplication (6 controllers) |
| **High** | Extract pagination defaults and helper | 15 min | Eliminates duplication in messages.controller |
| **High** | Create subscription/purchase status enums | 15 min | Centralizes status values (subscriptions + admin) |
| **Medium** | Extract validator services (phone, email, tax-id) | 25 min | Improves testability |
| **Medium** | Extract rate limit config constants | 10 min | Makes tuning easier |
| **Medium** | Extract overage type mapping | 10 min | Single source of truth |
| **Low** | Extract error reason enums/maps | 15 min | Nice-to-have, improves maintainability |

**Total estimated time for all quick wins: ~2 hours**

---

## Table Summary for Tracking

| Controller | Hardcoding Count | Categories | Priority |
|-----------|-----------------|-----------|----------|
| subscriptions.controller.ts | 7 | Enum values, Magic numbers, Type mapping, Status checks, API version, Error reasons | High |
| admin.controller.ts | 5 | Function logic, Type mapping, Test IDs, API version, Reason map | High |
| otp.controller.ts | 5 | Type union, Regex patterns (3x), Rate limit, Validation duplication (3x) | Medium |
| messages.controller.ts | 5 | Pagination patterns (4x), Boolean parsing (2x) | High |
| session-notes.controller.ts | 2 | Rate limit, Validation length | Low |
| me.controller.ts | 5 | Placeholder domain, Regex pattern, Default language (2x), API version, Stripe param | Medium |
| **TOTAL** | **29+ instances** | | |

