/**
 * INTERIM Supabase database types.
 *
 * Regenerated from the local post-migration schema by scripts/gen-types.sh
 * (`pnpm gen:types`); CI regenerates and fails when this file drifts. Until
 * generation runs, this permissive-but-structured shape keeps the typed
 * client compiling; route code narrows rows to the Phase 2 contracts.
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

interface GenericTable {
  Row: Record<string, unknown>;
  Insert: Record<string, unknown>;
  Update: Record<string, unknown>;
  Relationships: never[];
}

export interface Database {
  public: {
    Tables: Record<string, GenericTable>;
    Views: Record<string, never>;
    Functions: Record<
      string,
      { Args: Record<string, unknown>; Returns: unknown }
    >;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}
