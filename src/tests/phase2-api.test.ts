// @vitest-environment node

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AuthResult } from "@/lib/supabase/auth";

// The route handlers obtain identity exclusively through this boundary;
// mocking it lets the routes run without a Next request context.
const authState: { result: AuthResult } = {
  result: {
    ok: false,
    status: 401,
    code: "unauthorized",
    message: "A valid session is required.",
  },
};

vi.mock("@/lib/supabase/auth", () => ({
  requireAuthenticatedUser: vi.fn(async () => authState.result),
}));

import {
  GET as listDrafts,
  POST as createDraft,
} from "@/app/api/workspaces/[workspaceId]/drafts/route";
import { PATCH as saveDraft } from "@/app/api/workspaces/[workspaceId]/drafts/[draftId]/route";
import { POST as applyTemplate } from "@/app/api/workspaces/[workspaceId]/templates/[templateId]/apply/route";
import { createSampleDraftDocument } from "@/lib/composer/samples";

const WS = "11111111-1111-4111-8111-111111111111";
const DRAFT = "22222222-2222-4222-8222-222222222222";
const USER = "33333333-3333-4333-8333-333333333333";
const TEMPLATE = "44444444-4444-4444-8444-444444444444";
const TEMPLATE_VERSION = "55555555-5555-4555-8555-555555555555";

type QueryResult = { data: unknown; error: unknown };

/** Minimal chainable PostgREST-style mock. */
function makeSupabaseMock(overrides: {
  selectResult?: QueryResult;
  rpcResult?: QueryResult;
}) {
  const terminal = overrides.selectResult ?? { data: [], error: null };
  const chain: Record<string, unknown> = {};
  const passthrough = () => chain;
  for (const method of [
    "select",
    "eq",
    "order",
    "insert",
    "update",
    "delete",
  ]) {
    chain[method] = vi.fn(passthrough);
  }
  chain.maybeSingle = vi.fn(async () => terminal);
  chain.single = vi.fn(async () => terminal);
  chain.then = (resolve: (value: QueryResult) => unknown) =>
    Promise.resolve(terminal).then(resolve);
  return {
    from: vi.fn(() => chain),
    rpc: vi.fn(async () => overrides.rpcResult ?? { data: null, error: null }),
  };
}

function authed(supabase: unknown): AuthResult {
  return {
    ok: true,
    context: {
      supabase: supabase as never,
      userId: USER,
    },
  };
}

function params<T extends Record<string, string>>(value: T) {
  return { params: Promise.resolve(value) };
}

function jsonRequest(body: unknown): Request {
  return new Request("http://localhost/api/test", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const originalFlag = process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED;

beforeEach(() => {
  process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = "true";
});

afterEach(() => {
  process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = originalFlag;
  authState.result = {
    ok: false,
    status: 401,
    code: "unauthorized",
    message: "A valid session is required.",
  };
});

describe("Phase 2 API guard behavior", () => {
  it("fails closed with 404 when the feature flag is disabled", async () => {
    process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = "false";
    authState.result = authed(makeSupabaseMock({}));
    const response = await listDrafts(
      new Request("http://localhost"),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(404);
  });

  it("rejects unauthenticated requests with 401", async () => {
    const response = await listDrafts(
      new Request("http://localhost"),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(401);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("unauthorized");
  });

  it("rejects non-UUID workspace ids with 404 (no probing)", async () => {
    authState.result = authed(makeSupabaseMock({}));
    const response = await listDrafts(
      new Request("http://localhost"),
      params({ workspaceId: "../../etc" }),
    );
    expect(response.status).toBe(404);
  });

  it("maps a P0409 revision conflict to HTTP 409 with the current revision", async () => {
    authState.result = authed(
      makeSupabaseMock({
        selectResult: { data: { id: DRAFT }, error: null },
        rpcResult: {
          data: null,
          // The hardened save_draft RPC RAISES P0409 with a
          // `hint = 'current_revision=N'` payload on optimistic-concurrency
          // mismatch; this is the real DB behavior, mirrored here in a mocked
          // PostgREST error (7 is a representative stored revision).
          error: {
            code: "P0409",
            message: "revision conflict",
            hint: "current_revision=7",
          },
        },
      }),
    );
    const response = await saveDraft(
      jsonRequest({
        expectedRevision: 5,
        subject: "Betreff",
        document: createSampleDraftDocument(),
        saveReason: "autosave",
      }),
      params({ workspaceId: WS, draftId: DRAFT }),
    );
    expect(response.status).toBe(409);
    const body = (await response.json()) as {
      error: { code: string; currentRevision?: number };
    };
    expect(body.error.code).toBe("revision_conflict");
    expect(body.error.currentRevision).toBe(7);
  });

  it("returns a uniform 404 for records outside the caller's workspaces", async () => {
    authState.result = authed(
      makeSupabaseMock({ selectResult: { data: null, error: null } }),
    );
    const response = await saveDraft(
      jsonRequest({
        expectedRevision: 1,
        subject: "",
        document: createSampleDraftDocument(),
        saveReason: "autosave",
      }),
      params({ workspaceId: WS, draftId: DRAFT }),
    );
    expect(response.status).toBe(404);
    const raw = JSON.stringify(await response.json());
    // No existence signal, no stack trace, no internals.
    expect(raw).not.toContain("stack");
    expect(raw).not.toMatch(/\n\s+at /);
  });

  it("maps an RPC P0002 (not-found/access-denied) to a uniform 404 on create_draft", async () => {
    // create_draft is SECURITY DEFINER and RAISES P0002 when the caller is not
    // a member of the target workspace. That must surface as a uniform 404,
    // never a 422, so cross-workspace existence never leaks.
    authState.result = authed(
      makeSupabaseMock({
        rpcResult: {
          data: null,
          error: { code: "P0002", message: "not found or access denied" },
        },
      }),
    );
    const response = await createDraft(
      jsonRequest({ subject: "x", document: createSampleDraftDocument() }),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("not_found");
  });

  it("maps a checkpoint P0002 to a uniform 404 on templates/apply", async () => {
    const version = {
      id: TEMPLATE_VERSION,
      workspace_id: WS,
      template_id: TEMPLATE,
      version_no: 1,
      subject_template: "Hallo",
      body_template_json: {
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Hallo" }] },
        ],
      },
      variable_schema: [],
      created_by: USER,
      created_at: "2026-01-01T00:00:00.000Z",
    };
    authState.result = authed(
      makeSupabaseMock({
        selectResult: { data: version, error: null },
        // checkpoint_draft (first RPC) RAISES P0002 for a draft the caller
        // cannot see across workspaces.
        rpcResult: {
          data: null,
          error: { code: "P0002", message: "not found or access denied" },
        },
      }),
    );
    const response = await applyTemplate(
      jsonRequest({
        templateVersionId: TEMPLATE_VERSION,
        draftId: DRAFT,
        expectedRevision: 1,
        values: {},
      }),
      params({ workspaceId: WS, templateId: TEMPLATE }),
    );
    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("not_found");
  });

  it("rejects invalid canonical documents with 422", async () => {
    authState.result = authed(makeSupabaseMock({}));
    const response = await createDraft(
      jsonRequest({
        subject: "x",
        document: { type: "doc", content: [{ type: "image" }] },
      }),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(422);
  });

  it("rejects oversized bodies with 413 before parsing", async () => {
    authState.result = authed(makeSupabaseMock({}));
    const big = "a".repeat(600 * 1024);
    const response = await createDraft(
      jsonRequest({ subject: big, document: createSampleDraftDocument() }),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(413);
  });

  it("rejects wrong content types with 415", async () => {
    authState.result = authed(makeSupabaseMock({}));
    const response = await createDraft(
      new Request("http://localhost/api/test", {
        method: "POST",
        headers: { "content-type": "text/plain" },
        body: "x",
      }),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(415);
  });

  it("error responses never contain stack traces", async () => {
    authState.result = authed(
      makeSupabaseMock({
        selectResult: { data: null, error: { code: "XX000", message: "boom" } },
      }),
    );
    const response = await listDrafts(
      new Request("http://localhost"),
      params({ workspaceId: WS }),
    );
    expect(response.status).toBe(500);
    const raw = await response.text();
    expect(raw).not.toContain("boom\n");
    expect(raw).not.toMatch(/\n\s+at /);
    expect(raw).not.toContain("stack");
  });
});
