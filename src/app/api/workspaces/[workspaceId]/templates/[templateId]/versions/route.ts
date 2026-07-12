import { RPC, type TemplateVersionRecord } from "@/lib/phase2/contracts";
import { toDbJson } from "@/lib/phase2/db-json";
import {
  declaredVariables,
  validateTemplateDocument,
} from "@/lib/templates/template-document";
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
  params: Promise<{ workspaceId: string; templateId: string }>;
}

export async function GET(
  _request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, templateId } = await params;
  if (!isUuid(workspaceId) || !isUuid(templateId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const { data, error } = await guard.context.supabase
    .from("draft_template_versions")
    .select("*")
    .eq("template_id", templateId)
    .eq("workspace_id", workspaceId)
    .order("version_no", { ascending: false });
  if (error) return mapDatabaseError(error);
  return Response.json({
    versions: (data ?? []) as unknown as TemplateVersionRecord[],
  });
}

export async function POST(
  request: Request,
  { params }: RouteParams,
): Promise<Response> {
  const guard = await guardRequest();
  if (!guard.ok) return guard.response;
  const { workspaceId, templateId } = await params;
  if (!isUuid(workspaceId) || !isUuid(templateId)) {
    return jsonError(404, "not_found", "Not found.");
  }

  const body = await parseJsonBody(request);
  if (!body.ok) return body.response;
  const payload = body.value as {
    subjectTemplate?: unknown;
    bodyTemplateJson?: unknown;
    variableSchema?: unknown;
  };

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
  const schemaValidation = declaredVariables(payload.variableSchema ?? []);
  if (!schemaValidation.ok) {
    return jsonError(422, "invalid_body", "The variable schema is invalid.", {
      details: schemaValidation.errors,
    });
  }

  // Scope check.
  const { data: template, error: readError } = await guard.context.supabase
    .from("draft_templates")
    .select("id")
    .eq("id", templateId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();
  if (readError) return mapDatabaseError(readError);
  if (!template) return jsonError(404, "not_found", "Not found.");

  const { data, error } = await guard.context.supabase.rpc(
    RPC.createTemplateVersion,
    {
      p_template_id: templateId,
      p_workspace_id: workspaceId,
      p_subject_template: subjectTemplate,
      p_body_template_json: toDbJson(templateValidation.document),
      p_variable_schema: toDbJson(schemaValidation.variables),
    },
  );
  if (error) return mapDatabaseError(error);
  return Response.json({ version: data }, { status: 201 });
}
