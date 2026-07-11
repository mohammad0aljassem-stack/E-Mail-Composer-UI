import { validateDraftDocument } from "@/lib/composer/canonical";
import { RPC, type DraftRecord, type SaveDraftResult } from "@/lib/phase2/contracts";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string; draftId: string }>;
}

const SAVE_REASONS = new Set([
  "autosave",
  "manual_checkpoint",
  "after_template",
  "after_signature",
]);

export async function GET(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const { data, error } = await guard.context.supabase
    .from("drafts")
    .select("*")
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (error) return mapDatabaseError(error);
  if (!data) return jsonError(404, "not_found", "Not found.");
  return Response.json({ draft: data as unknown as DraftRecord });
}

export async function PATCH(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as {
    expectedRevision?: unknown;
    subject?: unknown;
    document?: unknown;
    saveReason?: unknown;
  };

  if (
    typeof payload.expectedRevision !== "number" ||
    !Number.isSafeInteger(payload.expectedRevision) ||
    payload.expectedRevision < 1
  ) {
    return jsonError(422, "invalid_body", "expectedRevision is required.");
  }
  const subject = typeof payload.subject === "string" ? payload.subject : "";
  if (subject.length > 500) {
    return jsonError(422, "invalid_body", "Subject is too long (max 500).");
  }
  const saveReason =
    typeof payload.saveReason === "string" ? payload.saveReason : "autosave";
  if (!SAVE_REASONS.has(saveReason)) {
    return jsonError(422, "invalid_body", "Unknown saveReason.");
  }
  const validation = validateDraftDocument(payload.document);
  if (!validation.ok) {
    return jsonError(
      422,
      "invalid_document",
      "The document is not a valid canonical draft document.",
      { details: validation.errors },
    );
  }

  // Scope check: the draft must belong to the workspace in the path.
  const { data: existing, error: readError } = await guard.context.supabase
    .from("drafts")
    .select("id")
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!existing) return jsonError(404, "not_found", "Not found.");

  const { data, error } = await guard.context.supabase.rpc(RPC.saveDraft, {
    p_draft_id: draftId,
    p_expected_revision: payload.expectedRevision,
    p_subject: subject,
    p_body_json: validation.document,
    p_save_reason: saveReason,
  });
  if (error) return mapDatabaseError(error);
  return Response.json(data as unknown as SaveDraftResult);
}

export async function DELETE(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const { data, error } = await guard.context.supabase
    .from("drafts")
    .update({
      status: "archived",
      archived_at: new Date().toISOString(),
      updated_by: guard.context.userId,
    })
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .select("id")
    .maybeSingle();
  if (error) return mapDatabaseError(error);
  if (!data) return jsonError(404, "not_found", "Not found.");
  return Response.json({ archived: true });
}
