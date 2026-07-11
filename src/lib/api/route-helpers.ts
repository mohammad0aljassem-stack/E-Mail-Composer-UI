/**
 * Shared helpers for the Phase 2 workspace-scoped API routes.
 *
 * Every route: verified session required, JSON-only bounded bodies,
 * structured errors without stack traces, no draft/template/attachment
 * content in logs (nothing is logged at all), 404 that does not distinguish
 * "does not exist" from "not yours".
 */

import {
  API_MAX_JSON_BODY_BYTES,
  PG_REVISION_CONFLICT_ERRCODE,
  type ApiError,
  type ApiErrorCode,
} from "@/lib/phase2/contracts";
import {
  requireAuthenticatedUser,
  type AuthenticatedContext,
} from "@/lib/supabase/auth";
import { readJsonBodyWithLimit } from "@/lib/http/body";

export function jsonError(
  status: number,
  code: ApiErrorCode,
  message: string,
  extras?: Partial<ApiError["error"]>,
): Response {
  const body: ApiError = { error: { code, message, ...extras } };
  return Response.json(body, { status });
}

export function featureEnabled(): boolean {
  return process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED === "true";
}

export type GuardResult =
  | { ok: true; context: AuthenticatedContext }
  | { ok: false; response: Response };

/** Feature flag gate (fail closed) + verified-session gate. */
export async function guardRequest(): Promise<GuardResult> {
  if (!featureEnabled()) {
    return {
      ok: false,
      response: jsonError(404, "not_found", "Not found."),
    };
  }
  const auth = await requireAuthenticatedUser();
  if (!auth.ok) {
    return {
      ok: false,
      response: jsonError(auth.status, auth.code, auth.message),
    };
  }
  return { ok: true, context: auth.context };
}

export type ParsedBody =
  | { ok: true; value: unknown }
  | { ok: false; response: Response };

export async function parseJsonBody(request: Request): Promise<ParsedBody> {
  const result = await readJsonBodyWithLimit(request, API_MAX_JSON_BODY_BYTES);
  if (!result.ok) {
    return {
      ok: false,
      response: jsonError(result.status, result.code, result.message),
    };
  }
  return { ok: true, value: result.value };
}

interface PostgrestErrorLike {
  code?: string;
  message?: string;
  details?: string | null;
  hint?: string | null;
}

/**
 * Maps PostgREST/PostgreSQL errors to structured API errors. Authorization
 * failures and missing rows share the same 404 so record existence never
 * leaks across workspaces.
 */
export function mapDatabaseError(error: PostgrestErrorLike): Response {
  if (error.code === PG_REVISION_CONFLICT_ERRCODE) {
    const current = extractCurrentRevision(error);
    return jsonError(
      409,
      "revision_conflict",
      "The draft was changed by someone else. Reload or save as a copy.",
      current === null ? undefined : { currentRevision: current },
    );
  }
  if (error.code === "PGRST116") {
    return jsonError(404, "not_found", "Not found.");
  }
  // Raised business-rule errors from our RPCs (P0001 and friends) carry a
  // human-readable, content-free message.
  if (error.code?.startsWith("P0") && error.message) {
    return jsonError(422, "invalid_body", sanitizeDbMessage(error.message));
  }
  if (error.code === "23514" || error.code === "23505") {
    return jsonError(422, "invalid_body", "The change violates a constraint.");
  }
  return jsonError(500, "internal_error", "The request could not be handled.");
}

function extractCurrentRevision(error: PostgrestErrorLike): number | null {
  const hint = error.hint ?? "";
  const match = /current_revision=(\d+)/.exec(hint);
  if (!match || match[1] === undefined) {
    return null;
  }
  const value = Number(match[1]);
  return Number.isSafeInteger(value) ? value : null;
}

function sanitizeDbMessage(message: string): string {
  // Defensive: keep it short and single-line; RPC messages are content-free.
  return message.split("\n")[0]?.slice(0, 300) ?? "Invalid request.";
}

export function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    value,
  );
}
