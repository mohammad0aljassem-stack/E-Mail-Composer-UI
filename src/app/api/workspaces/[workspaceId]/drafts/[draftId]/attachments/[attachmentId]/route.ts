import {
  ATTACHMENT_BUCKET,
  RPC,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
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
 * Deletion order matters: the Storage object is removed first (through the
 * authenticated, RLS-scoped client); the metadata row is only marked
 * "deleted" when the object is verifiably gone. If removal fails the row
 * keeps its previous status and the client sees a structured error.
 */
export async function DELETE(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId, attachmentId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId) || !isUuid(attachmentId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const supabase = guard.context.supabase;

  const { data: attachment, error: readError } = await supabase
    .from("draft_attachments")
    .select("*")
    .eq("id", attachmentId)
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!attachment) return jsonError(404, "not_found", "Not found.");

  const record = attachment as unknown as AttachmentRecord;
  if (record.status !== "deleted") {
    const { error: removeError } = await supabase.storage
      .from(ATTACHMENT_BUCKET)
      .remove([record.storage_path]);
    if (removeError) {
      // Object removal failed: do NOT mark the row deleted.
      return jsonError(
        502,
        "internal_error",
        "The stored file could not be removed; the attachment was not deleted.",
      );
    }
  }

  const { error: markError } = await supabase.rpc(RPC.markAttachmentDeleted, {
    p_attachment_id: attachmentId,
  });
  if (markError) return mapDatabaseError(markError);

  const { data: fresh, error: freshError } = await supabase
    .from("draft_attachments")
    .select("*")
    .eq("id", attachmentId)
    .maybeSingle();
  if (freshError) return mapDatabaseError(freshError);
  return Response.json({
    attachment: (fresh ?? attachment) as unknown as AttachmentRecord,
  });
}
