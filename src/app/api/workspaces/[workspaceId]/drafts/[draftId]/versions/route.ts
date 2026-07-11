import { type DraftVersionRecord } from "@/lib/phase2/contracts";
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
    .from("draft_versions")
    .select("*")
    .eq("draft_id", draftId)
    .eq("workspace_id", workspaceId)
    .order("version_no", { ascending: false });
  if (error) return mapDatabaseError(error);
  return Response.json({
    versions: (data ?? []) as unknown as DraftVersionRecord[],
  });
}
