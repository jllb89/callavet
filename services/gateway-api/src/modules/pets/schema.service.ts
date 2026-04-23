import { Injectable, OnModuleInit } from '@nestjs/common';
import { DbService } from '../db/db.service';

export interface FieldSchema {
  name: string;
  type: 'string' | 'enum' | 'array' | 'boolean';
  required: boolean;
  maxLength?: number;
  enumValues?: Set<string>;
  arrayElementType?: 'string' | 'enum';
  arrayEnumValues?: Set<string>;
}

export interface PetSchema {
  fields: Map<string, FieldSchema>;
  selectSql: string;
  columns: string[];
}

@Injectable()
export class SchemaService implements OnModuleInit {
  private petSchema?: PetSchema;

  constructor(private readonly db: DbService) {}

  async onModuleInit() {
    await this.db.ensureReady();
    if (!this.db.isStub) {
      this.petSchema = await this.loadPetSchema();
    }
  }

  getPetSchema(): PetSchema {
    if (!this.petSchema) {
      throw new Error('Schema not loaded');
    }
    return this.petSchema;
  }

  private async loadPetSchema(): Promise<PetSchema> {
    const { rows: columns } = await this.db.runInTx(async (q) => {
      return q(
        `select column_name, data_type, is_nullable
           from information_schema.columns
          where table_schema = 'public' and table_name = 'pets'
          order by ordinal_position`,
        [],
      );
    });

    const { rows: constraints } = await this.db.runInTx(async (q) => {
      return q(
        `select tc.constraint_name,
                cc.check_clause as constraint_definition
           from information_schema.table_constraints tc
           join information_schema.check_constraints cc
             on cc.constraint_catalog = tc.constraint_catalog
            and cc.constraint_schema = tc.constraint_schema
            and cc.constraint_name = tc.constraint_name
          where tc.table_schema = 'public'
            and tc.table_name = 'pets'
            and tc.constraint_type = 'CHECK'`,
        [],
      );
    });

    const fields = new Map<string, FieldSchema>();
    const columnNames: string[] = [];

    // Parse constraints to extract enum values
    const enumMap = this.parseEnumConstraints(constraints);

    // Map column info to field schemas
    for (const col of columns) {
      const name = col.column_name;
      columnNames.push(name);

      const isRequired = col.is_nullable === 'NO';
      const enumVals = enumMap.get(name);

      let fieldSchema: FieldSchema;

      // Detect array fields from type
      if (col.data_type === 'ARRAY') {
        const arrayEnumVals = enumMap.get(`${name}_element`);
        fieldSchema = {
          name,
          type: 'array',
          required: isRequired,
          arrayElementType: arrayEnumVals ? 'enum' : 'string',
          arrayEnumValues: arrayEnumVals,
        };
      }
      // Detect enum fields
      else if (enumVals) {
        fieldSchema = {
          name,
          type: 'enum',
          required: isRequired,
          enumValues: enumVals,
        };
      }
      // Regular string fields
      else if (col.data_type === 'text' || col.data_type === 'character varying') {
        fieldSchema = {
          name,
          type: 'string',
          required: isRequired,
          maxLength: this.extractMaxLength(name, constraints),
        };
      }
      // Timestamps and IDs
      else {
        fieldSchema = {
          name,
          type: 'string',
          required: isRequired,
        };
      }

      fields.set(name, fieldSchema);
    }

    // Build SELECT SQL
    const selectSql = columnNames
      .filter((c) => !['id', 'user_id'].includes(c))
      .map((c) => `${c}`)
      .join(',\n  ');

    const fullSelectSql = `id::text as id,\n  user_id::text as user_id,\n  ${selectSql}`;

    return {
      fields,
      selectSql: fullSelectSql,
      columns: columnNames,
    };
  }

  private parseEnumConstraints(
    constraints: any[],
  ): Map<string, Set<string>> {
    const enumMap = new Map<string, Set<string>>();

    for (const constraint of constraints) {
      const def = constraint.constraint_definition;
      if (!def) continue;

      // Parse: CHECK (sex = ANY(ARRAY['male','female','gelding']))
      const anyMatch = def.match(/\((\w+)\s*=\s*ANY\s*\(\s*ARRAY\[(.*?)\]\s*\)\)/);
      if (anyMatch) {
        const fieldName = anyMatch[1];
        const valuesStr = anyMatch[2];
        const values = valuesStr
          .split(',')
          .map((v: string) => v.trim().replace(/^'|'$/g, ''))
          .filter((v: string) => v);
        enumMap.set(fieldName, new Set(values));
        continue;
      }

      // Parse: CHECK (observed_last_6_months[1] = ANY(ARRAY[...]))
      const arrayElementMatch = def.match(/\((\w+)\[1\]\s*=\s*ANY\s*\(\s*ARRAY\[(.*?)\]\s*\)\)/);
      if (arrayElementMatch) {
        const fieldName = arrayElementMatch[1];
        const valuesStr = arrayElementMatch[2];
        const values = valuesStr
          .split(',')
          .map((v: string) => v.trim().replace(/^'|'$/g, ''))
          .filter((v: string) => v);
        enumMap.set(`${fieldName}_element`, new Set(values));
        continue;
      }

      // Parse: CHECK (breed IN ('quarter_horse', 'thoroughbred', ...))
      const inMatch = def.match(/\((\w+)\s+IN\s*\((.*?)\)\)/);
      if (inMatch) {
        const fieldName = inMatch[1];
        const valuesStr = inMatch[2];
        const values = valuesStr
          .split(',')
          .map((v: string) => v.trim().replace(/^'|'$/g, ''))
          .filter((v: string) => v);
        enumMap.set(fieldName, new Set(values));
        continue;
      }
    }

    return enumMap;
  }

  private extractMaxLength(fieldName: string, constraints: any[]): number | undefined {
    // TODO: Extract from CHECK constraints if they define length limits
    const lengthMap: Record<string, number> = {
      name: 100,
      other_breed_text: 100,
      other_discipline_text: 100,
      other_terrain_text: 100,
      location_country: 100,
      location_state_region: 100,
      current_treatments_or_supplements: 500,
      additional_notes: 1000,
    };
    return lengthMap[fieldName];
  }
}
