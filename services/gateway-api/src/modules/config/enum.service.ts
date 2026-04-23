import { Injectable, OnModuleInit } from '@nestjs/common';
import { DbService } from '../db/db.service';

/**
 * EnumService: Loads all database enum/check constraints at startup
 * Single source of truth: database CHECK constraints
 * Eliminates hardcoded enum type unions in controllers
 */
@Injectable()
export class EnumService implements OnModuleInit {
  // Cache: table.column -> Set<string> of allowed values
  private enumCache = new Map<string, Set<string>>();
  private isReady = false;

  constructor(private readonly db: DbService) {}

  async onModuleInit() {
    if (!this.db.isStub) {
      await this.loadAllEnums();
      this.isReady = true;
    }
  }

  /**
   * Get allowed values for a field (e.g., 'users.role')
   * Returns Set<string> for efficient lookup
   */
  getValues(table: string, column: string): Set<string> {
    const key = `${table}.${column}`;
    const cached = this.enumCache.get(key);
    if (cached) return cached;

    throw new Error(
      `Enum not loaded for ${key}. Cache keys: ${Array.from(this.enumCache.keys()).join(', ')}`,
    );
  }

  /**
   * Check if value is allowed for a field
   */
  isAllowed(table: string, column: string, value: string): boolean {
    try {
      const allowed = this.getValues(table, column);
      return allowed.has(value);
    } catch {
      return false;
    }
  }

  /**
   * Get as array (useful for UI/docs)
   */
  getValuesAsArray(table: string, column: string): string[] {
    const set = this.getValues(table, column);
    return Array.from(set).sort();
  }

  private async loadAllEnums(): Promise<void> {
    // Query all CHECK constraints from information_schema
    const { rows: constraints } = await this.db.query(
      `select table_name, constraint_definition
         from information_schema.table_constraints
         join information_schema.constraint_column_usage using (constraint_name, table_schema, table_name)
        where table_schema = 'public' and constraint_type = 'CHECK'
        order by table_name, constraint_name`,
      [],
    );

    for (const row of constraints) {
      const table = row.table_name;
      const def = row.constraint_definition || '';

      // Parse CHECK constraint to extract column name and allowed values
      const parsed = this.parseCheckConstraint(def);
      if (parsed) {
        const key = `${table}.${parsed.column}`;
        this.enumCache.set(key, parsed.values);
      }
    }
  }

  /**
   * Parse CHECK constraint definition and extract column + allowed values
   * Handles multiple formats:
   * - CHECK (status = ANY(ARRAY['a','b','c']))
   * - CHECK (role IN ('user','vet','admin'))
   * - CHECK (priority IN ('routine','urgent'))
   */
  private parseCheckConstraint(
    definition: string,
  ): { column: string; values: Set<string> } | null {
    if (!definition) return null;

    // Format 1: column = ANY(ARRAY['val1','val2',...])
    const anyMatch = definition.match(
      /\((\w+)\s*=\s*ANY\s*\(\s*ARRAY\[(.*?)\]\s*\)\)/,
    );
    if (anyMatch) {
      const column = anyMatch[1];
      const valuesStr = anyMatch[2];
      const values = this.extractQuotedStrings(valuesStr);
      return { column, values };
    }

    // Format 2: column IN ('val1','val2',...)
    const inMatch = definition.match(/\((\w+)\s+IN\s*\((.*?)\)\)/);
    if (inMatch) {
      const column = inMatch[1];
      const valuesStr = inMatch[2];
      const values = this.extractQuotedStrings(valuesStr);
      return { column, values };
    }

    // Format 3: array element check column[1] = ANY(ARRAY[...])
    const arrayElementMatch = definition.match(
      /\((\w+)\[1\]\s*=\s*ANY\s*\(\s*ARRAY\[(.*?)\]\s*\)\)/,
    );
    if (arrayElementMatch) {
      // Store under column_element_values for special handling
      const column = `${arrayElementMatch[1]}_element_values`;
      const valuesStr = arrayElementMatch[2];
      const values = this.extractQuotedStrings(valuesStr);
      return { column, values };
    }

    return null;
  }

  /**
   * Extract values from quoted string list
   * "val1','val2','val3" -> Set("val1", "val2", "val3")
   */
  private extractQuotedStrings(str: string): Set<string> {
    const values = str
      .split(',')
      .map((s) => s.trim().replace(/^'|'$/g, ''))
      .filter((s) => s.length > 0);
    return new Set(values);
  }
}
