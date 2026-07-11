import { type AttachmentRecord } from "@/lib/phase2/contracts";
import { renderDraftPackage } from "@/server/render/renderDraftPackage";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string; draftId: string }>;
}

/**
 * Render package preview: derived HTML + plain text + the verified
 * attachment manifest. Uses the STORED canonical draft (source of truth) and
 * only attachments whose Storage object has been verified as ready.
 */
export async function POST(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const supabase = guard.context.supabase;

  const { data: draft, error: draftError } = await supabase
    .from("drafts")
    .select("body_json")
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (draftError) return mapDatabaseError(draftError);
  if (!draft) return jsonError(404, "not_found", "Not found.");

  const { data: attachments, error: attachmentError } = await supabase
    .from("draft_attachments")
    .select("*")
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId);
  if (attachmentError) return mapDatabaseError(attachmentError);

  try {
    const rendered = await renderDraftPackage(
      (draft as { body_json: unknown }).body_json,
      (attachments ?? []) as unknown as AttachmentRecord[],
    );
    return Response.json(rendered);
  } catch {
    return jsonError(500, "internal_error", "The draft could not be rendered.");
  }
}
