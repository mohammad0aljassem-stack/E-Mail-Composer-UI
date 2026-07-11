/**
 * Boundary between validated application documents and the generated
 * database `Json` type.
 *
 * Canonical documents and variable schemas are modeled as closed interface
 * types, which lack the index signature the generated `Json` type requires.
 * Rather than weaken those types or duplicate the schema by hand, this
 * module converts already-validated values through a structural
 * serialization round-trip.
 */

import type { DraftDocument } from "@/lib/composer/canonical";
import type { TemplateVariableSpec } from "@/lib/phase2/contracts";
import type { Json } from "@/lib/supabase/database.types";
import type { TemplateDocument } from "@/lib/templates/template-document";

/**
 * Converts a VALIDATED document (or validated variable schema) to the
 * generated `Json` type. The `as Json` assertion is sound because
 * JSON.parse returns a JSON-shaped value by construction, and the accepted
 * types contain only plain objects, arrays, strings, numbers, and booleans
 * — nothing JSON.stringify drops or transforms — so the round-trip is
 * lossless. Callers must pass values that already passed the canonical
 * validation (validateDraftDocument / validateTemplateDocument /
 * declaredVariables).
 */
export function toDbJson(
  value: DraftDocument | TemplateDocument | TemplateVariableSpec[],
): Json {
  return JSON.parse(JSON.stringify(value)) as Json;
}
