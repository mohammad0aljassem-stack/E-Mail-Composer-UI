import { validateDraftDocument } from "@/lib/composer/canonical";
import {
  RPC,
  type SaveDraftResult,
  type SignatureRecord,
} from "@/lib/phase2/contracts";
import { toDbJson } from "@/lib/phase2/db-json";
import { applySignature } from "@/lib/signatures/apply-signature";
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

/**
 * Applies one of the caller's own signatures to a draft:
 * checkpoint (before_signature) -> deterministic, duplicate-safe append ->
 * save (after_signature) -> record the signature used.
 */
export async function POST(
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
    signatureId?: unknown;
    expectedRevision?: unknown;
  };
  if (typeof payload.signatureId !== "string" || !isUuid(payload.signatureId)) {
    return jsonError(422, "invalid_body", "signatureId is required.");
  }
  if (
    typeof payload.expectedRevision !== "number" ||
    !Number.isSafeInteger(payload.expectedRevision) ||
    payload.expectedRevision < 1
  ) {
    return jsonError(422, "invalid_body", "expectedRevision is required.");
  }

  const supabase = guard.context.supabase;

  const { data: signature, error: signatureError } = await supabase
    .from("signatures")
    .select("*")
    .eq("id", payload.signatureId)
    .eq("workspace_id", workspaceId)
    .eq("owner_user_id", guard.context.userId)
    .maybeSingle();
  if (signatureError) return mapDatabaseError(signatureError);
  if (!signature) return jsonError(404, "not_found", "Not found.");

  const { data: draft, error: draftError } = await supabase
    .from("drafts")
    .select("subject, body_json, revision")
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (draftError) return mapDatabaseError(draftError);
  if (!draft) return jsonError(404, "not_found", "Not found.");

  const current = validateDraftDocument(
    (draft as { body_json: unknown }).body_json,
  );
  if (!current.ok) {
    return jsonError(500, "internal_error", "Stored draft is invalid.");
  }

  const applied = applySignature(
    current.document,
    signature as unknown as SignatureRecord,
  );
  if (applied === current.document) {
    // Signature already present — deterministic no-op, no duplicate insert.
    return Response.json({
      revision: (draft as { revision: number }).revision,
      version_created: false,
      alreadyApplied: true,
    });
  }

  const { error: checkpointError } = await supabase.rpc(RPC.checkpointDraft, {
    p_draft_id: draftId,
    p_expected_revision: payload.expectedRevision,
    p_reason: "before_signature",
  });
  if (checkpointError) return mapDatabaseError(checkpointError);

  const { data: saved, error: saveError } = await supabase.rpc(RPC.saveDraft, {
    p_draft_id: draftId,
    p_expected_revision: payload.expectedRevision,
    p_subject: (draft as { subject: string }).subject,
    p_body_json: toDbJson(applied),
    p_save_reason: "after_signature",
  });
  if (saveError) return mapDatabaseError(saveError);

  const { error: traceError } = await supabase
    .from("drafts")
    .update({ last_signature_id: payload.signatureId })
    .eq("id", draftId)
    .eq("workspace_id", workspaceId);
  if (traceError) return mapDatabaseError(traceError);

  return Response.json({
    ...(saved as unknown as SaveDraftResult),
    document: applied,
    signatureId: payload.signatureId,
  });
}
