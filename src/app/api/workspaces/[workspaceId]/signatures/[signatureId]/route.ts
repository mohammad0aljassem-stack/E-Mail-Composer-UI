import { validateDraftDocument } from "@/lib/composer/canonical";
import { RPC, type SignatureRecord } from "@/lib/phase2/contracts";
import { toDbJson } from "@/lib/phase2/db-json";
import type { Database } from "@/lib/supabase/database.types";
import {
  guardRequest,
  isUuid,
  jsonError,
  mapDatabaseError,
  parseJsonBody,
} from "@/lib/api/route-helpers";

export const runtime = "nodejs";

interface RouteParams {
  params: Promise<{ workspaceId: string; signatureId: string }>;
}

type SignatureUpdate = Database["public"]["Tables"]["signatures"]["Update"];

export async function PATCH(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, signatureId } = await params;
  if (!isUuid(workspaceId) || !isUuid(signatureId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as {
    name?: unknown;
    bodyJson?: unknown;
    setDefault?: unknown;
  };

  const update: SignatureUpdate = {};
  if (payload.name !== undefined) {
    if (
      typeof payload.name !== "string" ||
      payload.name.trim().length === 0 ||
      payload.name.length > 200
    ) {
      return jsonError(422, "invalid_body", "Invalid signature name.");
    }
    update.name = payload.name;
  }
  if (payload.bodyJson !== undefined) {
    const validation = validateDraftDocument(payload.bodyJson);
    if (!validation.ok) {
      return jsonError(
        422,
        "invalid_document",
        "The signature body is not a valid canonical document.",
        { details: validation.errors },
      );
    }
    update.body_json = toDbJson(validation.document);
  }

  if (Object.keys(update).length > 0) {
    update.updated_at = new Date().toISOString();
    const { data, error } = await guard.context.supabase
      .from("signatures")
      .update(update)
      .eq("id", signatureId)
      .eq("workspace_id", workspaceId)
      .eq("owner_user_id", guard.context.userId)
      .select("id")
      .maybeSingle();
    if (error) return mapDatabaseError(error);
    if (!data) return jsonError(404, "not_found", "Not found.");
  }

  if (payload.setDefault === true) {
    const { error } = await guard.context.supabase.rpc(
      RPC.setDefaultSignature,
      { p_signature_id: signatureId },
    );
    if (error) return mapDatabaseError(error);
  }

  const { data: fresh, error: readError } = await guard.context.supabase
    .from("signatures")
    .select("*")
    .eq("id", signatureId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!fresh) return jsonError(404, "not_found", "Not found.");
  return Response.json({ signature: fresh as unknown as SignatureRecord });
}

export async function DELETE(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, signatureId } = await params;
  if (!isUuid(workspaceId) || !isUuid(signatureId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const { data, error } = await guard.context.supabase
    .from("signatures")
    .delete()
    .eq("id", signatureId)
    .eq("workspace_id", workspaceId)
    .eq("owner_user_id", guard.context.userId)
    .select("id")
    .maybeSingle();
  if (error) return mapDatabaseError(error);
  if (!data) return jsonError(404, "not_found", "Not found.");
  return Response.json({ deleted: true });
}
