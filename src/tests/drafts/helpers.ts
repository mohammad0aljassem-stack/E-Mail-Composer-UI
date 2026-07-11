/** Shared fixtures and fetch-mock helpers for the draft lifecycle tests. */

import type { DraftDocument } from "@/lib/composer/canonical";
import type {
  ApiError,
  ApiErrorCode,
  DraftRecord,
  DraftVersionRecord,
} from "@/lib/phase2/contracts";

export function docWithText(text: string): DraftDocument {
  return {
    type: "doc",
    content: [{ type: "paragraph", content: [{ type: "text", text }] }],
  };
}

export function makeDraft(overrides: Partial<DraftRecord> = {}): DraftRecord {
  return {
    id: "draft-1",
    workspace_id: "ws-1",
    subject: "Quarterly update",
    body_json: docWithText("Hallo Welt"),
    status: "draft",
    revision: 3,
    created_by: "user-alice",
    updated_by: "user-alice",
    last_autosaved_at: null,
    archived_at: null,
    last_template_version_id: null,
    last_signature_id: null,
    created_at: "2026-07-10T10:00:00.000Z",
    updated_at: "2026-07-10T11:00:00.000Z",
    ...overrides,
  };
}

export function makeVersion(
  overrides: Partial<DraftVersionRecord> = {},
): DraftVersionRecord {
  return {
    id: "version-1",
    workspace_id: "ws-1",
    draft_id: "draft-1",
    version_no: 1,
    source_revision: 1,
    subject: "Older subject",
    body_json: docWithText("Alter Inhalt"),
    reason: "initial",
    created_by: "user-alice",
    created_at: "2026-07-09T09:00:00.000Z",
    ...overrides,
  };
}

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function apiErrorResponse(
  status: number,
  code: ApiErrorCode,
  extra: Partial<ApiError["error"]> = {},
): Response {
  const body: ApiError = {
    error: { code, message: `error: ${code}`, ...extra },
  };
  return jsonResponse(status, body);
}

export interface RecordedFetchCall {
  method: string;
  url: string;
  body: unknown;
}

export type FetchRoute = (
  call: RecordedFetchCall,
) => Response | Promise<Response> | null;

/**
 * Creates a fetch stub that records calls and dispatches to `routes` in
 * order (first non-null response wins).
 */
export function createFetchMock(routes: FetchRoute[]) {
  const calls: RecordedFetchCall[] = [];
  const fetchMock = async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    const method = init?.method ?? "GET";
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      body = JSON.parse(init.body);
    }
    const call: RecordedFetchCall = { method, url, body };
    calls.push(call);
    for (const route of routes) {
      const response = route(call);
      if (response !== null) {
        return response;
      }
    }
    throw new Error(`Unhandled fetch in test: ${method} ${url}`);
  };
  return { fetchMock, calls };
}

export function on(
  method: string,
  urlPattern: string | RegExp,
  respond: (call: RecordedFetchCall) => Response | Promise<Response>,
): FetchRoute {
  return (call) => {
    if (call.method !== method) {
      return null;
    }
    const matches =
      typeof urlPattern === "string"
        ? call.url === urlPattern
        : urlPattern.test(call.url);
    return matches ? respond(call) : null;
  };
}
