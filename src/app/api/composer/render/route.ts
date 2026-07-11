/**
 * Development preview endpoint: canonical JSON in, { html, text } out.
 *
 * - JSON only (Content-Type enforced);
 * - bounded, streaming body read (stops as soon as the limit is exceeded —
 *   see src/lib/http/body.ts);
 * - strict canonical validation before rendering;
 * - structured errors, never stack traces;
 * - no logging of message content;
 * - no external services.
 */

import { renderDraft } from "@/server/render/renderDraft";
import { validateDraftDocument } from "@/lib/composer/canonical";
import { readJsonBodyWithLimit } from "@/lib/http/body";

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

  const body = await readJsonBodyWithLimit(request, MAX_BODY_BYTES);
  if (!body.ok) {
    return errorResponse(body.status, body.code, body.message);
  }
  const parsed = body.value;

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
