import { Injectable, BadRequestException } from '@nestjs/common';

/**
 * ValidatorService: Centralized validation logic, eliminates hardcoded regex patterns
 * Replaces scattered UUID_RE, TIME_RE, EMAIL_RE patterns across controllers
 */
@Injectable()
export class ValidatorService {
  // UUID format: 36 chars including hyphens
  private readonly UUID_RE = /^[0-9a-fA-F-]{36}$/;

  // Time format: HH:MM or HH:MM:SS
  private readonly TIME_RE = /^\d{2}:\d{2}(?::\d{2})?$/;

  // Email format: basic validation
  private readonly EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  // E.164 phone format: +[1-15 digits]
  private readonly PHONE_E164_RE = /^\+[1-9]\d{1,14}$/;

  /**
   * Validate UUID v4 format
   * @param value - String to validate
   * @throws BadRequestException if not valid UUID
   */
  validateUUID(value: unknown, field: string = 'id'): string {
    const str = String(value || '').trim();
    if (!this.UUID_RE.test(str)) {
      throw new BadRequestException(`${field} must be a valid UUID`);
    }
    return str;
  }

  /**
   * Validate email format
   * @throws BadRequestException if not valid email
   */
  validateEmail(value: unknown, field: string = 'email'): string {
    const str = String(value || '').trim().toLowerCase();
    if (!this.EMAIL_RE.test(str)) {
      throw new BadRequestException(`${field} must be a valid email address`);
    }
    return str;
  }

  /**
   * Normalize and validate time format HH:MM or HH:MM:SS
   * Returns normalized HH:MM:SS
   * @throws BadRequestException if not valid time
   */
  validateTime(value: unknown, field: string = 'time'): string {
    const str = String(value || '').trim();
    if (!this.TIME_RE.test(str)) {
      throw new BadRequestException(`${field} must be HH:MM or HH:MM:SS format`);
    }
    // Normalize to HH:MM:SS
    return str.length === 5 ? `${str}:00` : str;
  }

  /**
   * Validate and normalize E.164 phone format
   * Accepts various formats, returns normalized E.164
   * @throws BadRequestException if not valid phone
   */
  validatePhoneE164(value: unknown, field: string = 'phone'): string {
    const input = String(value || '').trim();
    if (!input) {
      throw new BadRequestException(`${field} is required`);
    }

    // Remove common formatting characters
    const compact = input.replace(/[^0-9+]/g, '');
    if (!compact) {
      throw new BadRequestException(`${field} must contain digits`);
    }

    // Handle with or without +
    const e164 = compact.startsWith('+') ? compact : `+${compact.replace(/[^0-9]/g, '')}`;

    // Validate E.164 format
    if (!this.PHONE_E164_RE.test(e164)) {
      throw new BadRequestException(`${field} must be valid E.164 format (9-15 digits)`);
    }

    return e164;
  }

  /**
   * Parse array of UUIDs, remove duplicates
   * @throws BadRequestException if invalid
   */
  parseUuidArray(values: unknown, field: string = 'ids'): string[] {
    if (values == null) return [];
    if (!Array.isArray(values)) {
      throw new BadRequestException(`${field} must be an array`);
    }

    const unique = new Set<string>();
    for (const raw of values) {
      const value = String(raw || '').trim();
      if (!this.UUID_RE.test(value)) {
        throw new BadRequestException(`${field} entries must be valid UUIDs`);
      }
      unique.add(value);
    }
    return Array.from(unique);
  }

  /**
   * Parse array of strings, remove duplicates and empty values
   * @throws BadRequestException if invalid
   */
  parseStringArray(values: unknown, field: string = 'values'): string[] {
    if (values == null) return [];
    if (!Array.isArray(values)) {
      throw new BadRequestException(`${field} must be an array`);
    }

    const normalized = values
      .map((value) => String(value || '').trim())
      .filter(Boolean);

    return Array.from(new Set(normalized));
  }

  /**
   * Validate enum value against allowed set
   * Returns normalized string
   * @throws BadRequestException if not in allowed set
   */
  parseEnum(
    value: unknown,
    field: string,
    allowedSet: Set<string>,
  ): string {
    const str = String(value || '').trim();
    if (!str) {
      throw new BadRequestException(`${field} is required`);
    }
    if (!allowedSet.has(str)) {
      throw new BadRequestException(
        `${field} must be one of: ${Array.from(allowedSet).join(', ')}`,
      );
    }
    return str;
  }

  /**
   * Validate enum value, nullable variant
   * Returns undefined if null/empty and not required
   * @throws BadRequestException if invalid
   */
  parseEnumOrNull(
    value: unknown,
    field: string,
    allowedSet: Set<string>,
    required: boolean = false,
  ): string | undefined {
    if (value === null || value === undefined) {
      if (required) throw new BadRequestException(`${field} is required`);
      return undefined;
    }

    const str = String(value || '').trim();
    if (!str) {
      if (required) throw new BadRequestException(`${field} is required`);
      return undefined;
    }

    if (!allowedSet.has(str)) {
      throw new BadRequestException(
        `${field} must be one of: ${Array.from(allowedSet).join(', ')}`,
      );
    }
    return str;
  }

  /**
   * Validate admin secret from Authorization header
   * @throws BadRequestException if missing or invalid
   */
  assertAdminSecret(secretHeader?: string): boolean {
    const expected = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
    if (!expected) {
      throw new BadRequestException('admin secret not configured');
    }
    if (secretHeader !== expected) {
      throw new BadRequestException('invalid admin secret');
    }
    return true;
  }

  /**
   * Check if string is valid UUID without throwing
   */
  isValidUUID(value: unknown): boolean {
    return this.UUID_RE.test(String(value || ''));
  }

  /**
   * Check if string is valid email without throwing
   */
  isValidEmail(value: unknown): boolean {
    return this.EMAIL_RE.test(String(value || '').trim().toLowerCase());
  }

  /**
   * Check if string is valid E.164 phone without throwing
   */
  isValidPhoneE164(value: unknown): boolean {
    const str = String(value || '').trim();
    const compact = str.replace(/[^0-9+]/g, '');
    const e164 = compact.startsWith('+') ? compact : `+${compact.replace(/[^0-9]/g, '')}`;
    return this.PHONE_E164_RE.test(e164);
  }
}
