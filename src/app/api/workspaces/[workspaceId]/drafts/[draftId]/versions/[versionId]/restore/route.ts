import { RPC } from "@/lib/phase2/contracts";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string; draftId: string; versionId: string }>;
}

export async function POST(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, draftId, versionId } = await params;
  if (!isUuid(workspaceId) || !isUuid(draftId) || !isUuid(versionId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as { expectedRevision?: unknown };
  if (
    typeof payload.expectedRevision !== "number" ||
    !Number.isSafeInteger(payload.expectedRevision) ||
    payload.expectedRevision < 1
  ) {
    return jsonError(422, "invalid_body", "expectedRevision is required.");
  }

  // Scope check without leaking existence across workspaces.
  const { data: version, error: readError } = await guard.context.supabase
    .from("draft_versions")
    .select("id")
    .eq("id", versionId)
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!version) return jsonError(404, "not_found", "Not found.");

  const { data, error } = await guard.context.supabase.rpc(
    RPC.restoreDraftVersion,
    {
      p_draft_id: draftId,
      p_workspace_id: workspaceId,
      p_version_id: versionId,
      p_expected_revision: payload.expectedRevision,
    },
  );
  if (error) return mapDatabaseError(error);
  return Response.json(data);
}
