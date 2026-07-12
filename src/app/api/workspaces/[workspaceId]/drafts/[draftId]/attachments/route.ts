import {
  ATTACHMENT_MAX_FILE_BYTES,
  RPC,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";
import { isAllowedMimeType } from "@/lib/attachments/validation";
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
    .from("draft_attachments")
    .select("*")
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId)
    .order("created_at", { ascending: true });
  if (error) return mapDatabaseError(error);
  return Response.json({
    attachments: (data ?? []) as unknown as AttachmentRecord[],
  });
}

/** Creates a pending attachment intent with a server-authorized path. */
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
    originalFilename?: unknown;
    mimeType?: unknown;
    sizeBytes?: unknown;
  };

  if (
    typeof payload.originalFilename !== "string" ||
    payload.originalFilename.length === 0 ||
    payload.originalFilename.length > 255
  ) {
    return jsonError(422, "invalid_body", "originalFilename is required.");
  }
  if (
    typeof payload.mimeType !== "string" ||
    !isAllowedMimeType(payload.mimeType)
  ) {
    return jsonError(
      422,
      "attachment_type_forbidden",
      "This file type is not allowed.",
    );
  }
  if (
    typeof payload.sizeBytes !== "number" ||
    !Number.isSafeInteger(payload.sizeBytes) ||
    payload.sizeBytes <= 0 ||
    payload.sizeBytes > ATTACHMENT_MAX_FILE_BYTES
  ) {
    return jsonError(
      422,
      "attachment_limit_exceeded",
      "The file size is not within the allowed range.",
    );
  }

  // Scope check.
  const { data: draft, error: draftError } = await guard.context.supabase
    .from("drafts")
    .select("id")
    .eq("id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (draftError) return mapDatabaseError(draftError);
  if (!draft) return jsonError(404, "not_found", "Not found.");

  const { data, error } = await guard.context.supabase.rpc(
    RPC.createAttachmentIntent,
    {
      p_draft_id: draftId,
      p_workspace_id: workspaceId,
      p_original_filename: payload.originalFilename,
      p_mime_type: payload.mimeType.toLowerCase(),
      p_size_bytes: payload.sizeBytes,
    },
  );
  if (error) return mapDatabaseError(error);
  const attachment = data as unknown as AttachmentRecord;
  return Response.json(
    { attachment, uploadPath: attachment.storage_path },
    { status: 201 },
  );
}
