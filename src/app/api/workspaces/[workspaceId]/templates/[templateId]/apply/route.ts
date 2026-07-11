import {
  RPC,
  type SaveDraftResult,
  type TemplateVersionRecord,
} from "@/lib/phase2/contracts";
import { toDbJson } from "@/lib/phase2/db-json";
import { applyTemplate } from "@/lib/templates/apply-template";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string; templateId: string }>;
}

/**
 * Applies an immutable template version to a draft:
 * checkpoint (before_template) -> deterministic resolution with explicit
 * variable values (ask or block; never guess) -> save (after_template) ->
 * record the exact template version used.
 */
export async function POST(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, templateId } = await params;
  if (!isUuid(workspaceId) || !isUuid(templateId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as {
    templateVersionId?: unknown;
    draftId?: unknown;
    expectedRevision?: unknown;
    values?: unknown;
  };

  if (
    typeof payload.templateVersionId !== "string" ||
    !isUuid(payload.templateVersionId) ||
    typeof payload.draftId !== "string" ||
    !isUuid(payload.draftId)
  ) {
    return jsonError(
      422,
      "invalid_body",
      "templateVersionId and draftId are required.",
    );
  }
  if (
    typeof payload.expectedRevision !== "number" ||
    !Number.isSafeInteger(payload.expectedRevision) ||
    payload.expectedRevision < 1
  ) {
    return jsonError(422, "invalid_body", "expectedRevision is required.");
  }
  const values: Record<string, string> = {};
  if (payload.values !== undefined) {
    if (
      typeof payload.values !== "object" ||
      payload.values === null ||
      Array.isArray(payload.values)
    ) {
      return jsonError(422, "invalid_body", "values must be an object.");
    }
    for (const [key, value] of Object.entries(payload.values)) {
      if (typeof value !== "string") {
        return jsonError(422, "invalid_body", "Variable values must be text.");
      }
      values[key] = value;
    }
  }

  const supabase = guard.context.supabase;

  const { data: version, error: versionError } = await supabase
    .from("draft_template_versions")
    .select("*")
    .eq("id", payload.templateVersionId)
    .eq("template_id", templateId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (versionError) return mapDatabaseError(versionError);
  if (!version) return jsonError(404, "not_found", "Not found.");

  const applied = applyTemplate({
    version: version as unknown as TemplateVersionRecord,
    values,
  });
  if (!applied.ok) {
    return jsonError(
      422,
      "missing_variables",
      "Required template variables are missing.",
      { missingVariables: applied.missingVariables },
    );
  }

  // Checkpoint the current state before replacing it.
  const { error: checkpointError } = await supabase.rpc(RPC.checkpointDraft, {
    p_draft_id: payload.draftId,
    p_expected_revision: payload.expectedRevision,
    p_reason: "before_template",
  });
  if (checkpointError) return mapDatabaseError(checkpointError);

  const { data: saved, error: saveError } = await supabase.rpc(RPC.saveDraft, {
    p_draft_id: payload.draftId,
    p_expected_revision: payload.expectedRevision,
    p_subject: applied.subject,
    p_body_json: toDbJson(applied.document),
    p_save_reason: "after_template",
  });
  if (saveError) return mapDatabaseError(saveError);

  // Traceability: record the exact immutable template version used.
  const { error: traceError } = await supabase
    .from("drafts")
    .update({ last_template_version_id: payload.templateVersionId })
    .eq("id", payload.draftId)
    .eq("workspace_id", workspaceId);
  if (traceError) return mapDatabaseError(traceError);

  return Response.json({
    ...(saved as unknown as SaveDraftResult),
    subject: applied.subject,
    document: applied.document,
    templateVersionId: payload.templateVersionId,
  });
}
