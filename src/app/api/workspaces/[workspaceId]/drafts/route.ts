import { validateDraftDocument } from "@/lib/composer/canonical";
import { RPC, type DraftRecord } from "@/lib/phase2/contracts";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string }>;
}

export async function GET(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId } = await params;
  if (!isUuid(workspaceId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const { data, error } = await guard.context.supabase
    .from("drafts")
    .select("*")
    .eq("workspace_id", workspaceId)
    .order("updated_at", { ascending: false });
  if (error) return mapDatabaseError(error);
  return Response.json({ drafts: (data ?? []) as unknown as DraftRecord[] });
}

export async function POST(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId } = await params;
  if (!isUuid(workspaceId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as { subject?: unknown; document?: unknown };

  const subject = typeof payload.subject === "string" ? payload.subject : "";
  if (subject.length > 500) {
    return jsonError(422, "invalid_body", "Subject is too long (max 500).");
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

  const { data, error } = await guard.context.supabase.rpc(RPC.createDraft, {
    p_workspace_id: workspaceId,
    p_subject: subject,
    p_body_json: validation.document,
  });
  if (error) return mapDatabaseError(error);
  return Response.json(
    { draft: data as unknown as DraftRecord },
    {
      status: 201,
    },
  );
}
