import { RPC, type TemplateRecord } from "@/lib/phase2/contracts";
import { validateTemplateDocument } from "@/lib/templates/template-document";
import { parseSubjectTemplate } from "@/lib/templates/subject-template";
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
    .from("draft_templates")
    .select("*")
    .eq("workspace_id", workspaceId)
    .order("updated_at", { ascending: false });
  if (error) return mapDatabaseError(error);
  return Response.json({
    templates: (data ?? []) as unknown as TemplateRecord[],
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
  const payload = body.value as {
    name?: unknown;
    description?: unknown;
    subjectTemplate?: unknown;
    bodyTemplateJson?: unknown;
    variableSchema?: unknown;
  };

  if (
    typeof payload.name !== "string" ||
    payload.name.trim().length === 0 ||
    payload.name.length > 200
  ) {
    return jsonError(422, "invalid_body", "A template name is required.");
  }
  const subjectTemplate =
    typeof payload.subjectTemplate === "string" ? payload.subjectTemplate : "";
  const subjectParse = parseSubjectTemplate(subjectTemplate);
  if (!subjectParse.ok) {
    return jsonError(422, "invalid_body", "The subject template is invalid.", {
      details: subjectParse.errors,
    });
  }
  const templateValidation = validateTemplateDocument(payload.bodyTemplateJson);
  if (!templateValidation.ok) {
    return jsonError(
      422,
      "invalid_document",
      "The template body is not a valid template document.",
      { details: templateValidation.errors },
    );
  }

  const { data: template, error: insertError } = await guard.context.supabase
    .from("draft_templates")
    .insert({
      workspace_id: workspaceId,
      name: payload.name,
      description:
        typeof payload.description === "string" ? payload.description : null,
      created_by: guard.context.userId,
    })
    .select("*")
    .single();
  if (insertError) return mapDatabaseError(insertError);

  const { data: version, error: versionError } =
    await guard.context.supabase.rpc(RPC.createTemplateVersion, {
      p_template_id: (template as { id: string }).id,
      p_subject_template: subjectTemplate,
      p_body_template_json: payload.bodyTemplateJson,
      p_variable_schema: payload.variableSchema ?? [],
    });
  if (versionError) return mapDatabaseError(versionError);

  return Response.json({ template, version }, { status: 201 });
}
