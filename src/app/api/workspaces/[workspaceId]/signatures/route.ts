import { validateDraftDocument } from "@/lib/composer/canonical";
import { type SignatureRecord } from "@/lib/phase2/contracts";
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

  // RLS restricts rows to the owner; the filter is defense in depth.
  const { data, error } = await guard.context.supabase
    .from("signatures")
    .select("*")
    .eq("workspace_id", workspaceId)
    .eq("owner_user_id", guard.context.userId)
    .order("created_at", { ascending: true });
  if (error) return mapDatabaseError(error);
  return Response.json({
    signatures: (data ?? []) as unknown as SignatureRecord[],
  });
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
  const payload = body.value as { name?: unknown; bodyJson?: unknown };

  if (
    typeof payload.name !== "string" ||
    payload.name.trim().length === 0 ||
    payload.name.length > 200
  ) {
    return jsonError(422, "invalid_body", "A signature name is required.");
  }
  const validation = validateDraftDocument(payload.bodyJson);
  if (!validation.ok) {
    return jsonError(
      422,
      "invalid_document",
      "The signature body is not a valid canonical document.",
      { details: validation.errors },
    );
  }

  const { data, error } = await guard.context.supabase
    .from("signatures")
    .insert({
      workspace_id: workspaceId,
      owner_user_id: guard.context.userId,
      name: payload.name,
      body_json: validation.document,
    })
    .select("*")
    .single();
  if (error) return mapDatabaseError(error);
  return Response.json(
    { signature: data as unknown as SignatureRecord },
    { status: 201 },
  );
}
