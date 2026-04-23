import { Injectable, OnModuleInit } from '@nestjs/common';
import { DbService } from '../db/db.service';

export interface VectorTargetConfig {
  id: string;
  table_name: string;
  embedding_column: string;
  dimension: number;
  snippet_expression: string;
  is_active: boolean;
}

/**
 * VectorTargetService: Load vector search configurations from database
 * Eliminates hardcoding of vector targets and their table/column mappings
 *
 * Instead of:
 *   const VectorTarget = 'kb' | 'messages' | 'notes' | ...
 *   const targetDim = { kb: 1536, messages: 1536, ...}
 *   const map = { kb: {table, embCol, snippet}, ...}
 *
 * Just query: SELECT * FROM vector_targets WHERE is_active = true
 */
@Injectable()
export class VectorTargetService implements OnModuleInit {
  // Cache: target_id -> full config
  private targetCache = new Map<string, VectorTargetConfig>();
  // Cache: all target IDs (useful for type generation at startup)
  private targetIds = new Set<string>();
  private isReady = false;

  constructor(private readonly db: DbService) {}

  async onModuleInit() {
    if (!this.db.isStub) {
      await this.loadAllTargets();
      this.isReady = true;
    }
  }

  /**
   * Get configuration for a vector target
   * Throws if target not found
   */
  getConfig(targetId: string): VectorTargetConfig {
    const config = this.targetCache.get(targetId);
    if (!config) {
      throw new Error(
        `Vector target "${targetId}" not found. Available: ${Array.from(this.targetIds).join(', ')}`,
      );
    }
    return config;
  }

  /**
   * Get embedding dimension for a target
   */
  getDimension(targetId: string): number {
    return this.getConfig(targetId).dimension;
  }

  /**
   * Get table name for a target
   */
  getTableName(targetId: string): string {
    return this.getConfig(targetId).table_name;
  }

  /**
   * Get embedding column name for a target
   */
  getEmbeddingColumn(targetId: string): string {
    return this.getConfig(targetId).embedding_column;
  }

  /**
   * Get snippet SQL expression for a target
   */
  getSnippetExpression(targetId: string): string {
    return this.getConfig(targetId).snippet_expression;
  }

  /**
   * Check if target is active and available
   */
  isAvailable(targetId: string): boolean {
    const config = this.targetCache.get(targetId);
    return !!config && config.is_active;
  }

  /**
   * Get list of all active targets
   */
  getActiveTargets(): VectorTargetConfig[] {
    return Array.from(this.targetCache.values()).filter((c) => c.is_active);
  }

  /**
   * Get list of all target IDs
   */
  getTargetIds(): string[] {
    return Array.from(this.targetIds).sort();
  }

  private async loadAllTargets(): Promise<void> {
    try {
      const { rows } = await this.db.query<VectorTargetConfig>(
        `select id, table_name, embedding_column, dimension, snippet_expression, is_active
           from vector_targets
          order by id`,
        [],
      );

      for (const row of rows) {
        this.targetCache.set(row.id, row);
        this.targetIds.add(row.id);
      }
    } catch (err: any) {
      // Table doesn't exist yet (normal during initial deployment)
      if (err?.message?.includes('vector_targets')) {
        // eslint-disable-next-line no-console
        console.warn('vector_targets table not found; VectorTargetService inactive');
      } else {
        throw err;
      }
    }
  }
}
