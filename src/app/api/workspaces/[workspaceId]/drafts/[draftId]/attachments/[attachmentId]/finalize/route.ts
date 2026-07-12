import { RPC, type AttachmentRecord } from "@/lib/phase2/contracts";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{
    workspaceId: string;
    draftId: string;
    attachmentId: string;
  }>;
}

/**
 * Verified finalization: the metadata row only becomes "ready" when the
 * Storage object demonstrably exists at the authorized path with a matching
 * size. Verification happens inside the database function.
 */
export async function POST(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId, attachmentId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId) || !isUuid(attachmentId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as { sha256?: unknown };
  const sha256 =
    typeof payload.sha256 === "string" && /^[a-f0-9]{64}$/.test(payload.sha256)
      ? payload.sha256
      : null;

  // Scope check.
  const { data: row, error: readError } = await guard.context.supabase
    .from("draft_attachments")
    .select("id")
    .eq("id", attachmentId)
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!row) return jsonError(404, "not_found", "Not found.");

  const { data, error } = await guard.context.supabase.rpc(
    RPC.finalizeAttachment,
    {
      p_attachment_id: attachmentId,
      p_workspace_id: workspaceId,
      p_sha256: sha256 ?? undefined,
    },
  );
  if (error) {
    if (error.code?.startsWith("P0")) {
      return jsonError(
        422,
        "attachment_not_verified",
        "The uploaded object could not be verified.",
      );
    }
    return mapDatabaseError(error);
  }
  return Response.json({ attachment: data as unknown as AttachmentRecord });
}
