/**
 * Development preview endpoint: canonical JSON in, { html, text } out.
 *
 * - JSON only (Content-Type is enforced);
 * - bounded body size;
 * - strict canonical validation before rendering;
 * - structured errors, never stack traces;
 * - no logging of message content;
 * - no external services.
 */

import { renderDraft } from "@/server/render/renderDraft";
import { validateDraftDocument } from "@/lib/composer/canonical";

export const runtime = "nodejs";

const MAX_BODY_BYTES = 256 * 1024;

interface ErrorBody {
  error: {
    code: string;
    message: string;
    details?: string[];
  };
}

function errorResponse(
  status: number,
  code: string,
  message: string,
  details?: string[],
): Response {
  const body: ErrorBody = { error: { code, message } };
  if (details && details.length > 0) {
    body.error.details = details;
  }
  return Response.json(body, { status });
}

function featureEnabled(): boolean {
  return process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED === "true";
}

export async function POST(request: Request): Promise<Response> {
  if (!featureEnabled()) {
    return errorResponse(404, "not_found", "Not found.");
  }

  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return errorResponse(
      415,
      "unsupported_media_type",
      "Content-Type must be application/json.",
    );
  }

  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return errorResponse(
      413,
      "payload_too_large",
      `Request body must not exceed ${MAX_BODY_BYTES} bytes.`,
    );
  }

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return errorResponse(
      400,
      "invalid_body",
      "Request body could not be read.",
    );
  }

  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    return errorResponse(
      413,
      "payload_too_large",
      `Request body must not exceed ${MAX_BODY_BYTES} bytes.`,
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return errorResponse(
      400,
      "invalid_json",
      "Request body is not valid JSON.",
    );
  }

  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !("document" in parsed)
  ) {
    return errorResponse(
      400,
      "missing_document",
      'Request body must be a JSON object with a "document" property.',
    );
  }

  const validation = validateDraftDocument(
    (parsed as { document: unknown }).document,
  );
  if (!validation.ok) {
    // Validation errors reference structure only (node types, keys, paths),
    // never user-entered text — safe to return to the client.
    return errorResponse(
      422,
      "invalid_document",
      "The document is not a valid canonical draft document.",
      validation.errors,
    );
  }

  try {
    const rendered = await renderDraft(validation.document);
    return Response.json(rendered);
  } catch {
    // Never leak stack traces or internals; never log draft content.
    return errorResponse(
      500,
      "render_failed",
      "The draft could not be rendered.",
    );
  }
}

export function GET(): Response {
  return errorResponse(405, "method_not_allowed", "Use POST.");
}
