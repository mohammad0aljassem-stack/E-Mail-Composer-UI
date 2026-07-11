import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DraftList } from "@/components/drafts/DraftList";
import {
  apiErrorResponse,
  createFetchMock,
  jsonResponse,
  makeDraft,
  on,
  type FetchRoute,
} from "./helpers";

const { routerPush } = vi.hoisted(() => ({ routerPush: vi.fn() }));

vi.mock("next/navigation", () => ({
  useRouter: () => ({
    push: routerPush,
    replace: routerPush,
    prefetch: vi.fn(),
  }),
}));

const originalFlag = process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED;

beforeEach(() => {
  process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = "true";
  routerPush.mockClear();
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = originalFlag;
});

function stubFetch(routes: FetchRoute[]) {
  const { fetchMock, calls } = createFetchMock(routes);
  vi.stubGlobal("fetch", vi.fn(fetchMock));
  return { calls };
}

describe("DraftList", () => {
  it("shows a disabled notice when the feature flag is off", () => {
    process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED = "false";
    const { calls } = stubFetch([]);
    render(<DraftList workspaceId="ws-1" />);
    expect(
      screen.getByText(/feature is disabled/i, { exact: false }),
    ).toBeDefined();
    expect(calls).toHaveLength(0);
  });

  it("lists drafts with subject, relative time, status, and archived badge", async () => {
    const recent = new Date(Date.now() - 5 * 60_000).toISOString();
    stubFetch([
      on("GET", "/api/workspaces/ws-1/drafts", () =>
        jsonResponse(200, {
          drafts: [
            makeDraft({ id: "d1", subject: "Launch plan", updated_at: recent }),
            makeDraft({
              id: "d2",
              subject: "",
              status: "archived",
              archived_at: "2026-07-01T00:00:00.000Z",
            }),
          ],
        }),
      ),
    ]);

    render(<DraftList workspaceId="ws-1" />);

    await waitFor(() => {
      expect(screen.getByText("Launch plan")).toBeDefined();
    });
    expect(screen.getByText("(no subject)")).toBeDefined();
    expect(screen.getByText(/5 minutes ago/)).toBeDefined();
    expect(screen.getByText("Archived")).toBeDefined();
    // Archived drafts have no archive button; active drafts have one.
    expect(screen.getByLabelText('Archive draft "Launch plan"')).toBeDefined();
    expect(screen.queryByLabelText('Archive draft "(no subject)"')).toBeNull();
  });

  it("creates a draft via POST and navigates to it", async () => {
    const { calls } = stubFetch([
      on("GET", "/api/workspaces/ws-1/drafts", () =>
        jsonResponse(200, { drafts: [] }),
      ),
      on("POST", "/api/workspaces/ws-1/drafts", () =>
        jsonResponse(200, { draft: makeDraft({ id: "d-new" }) }),
      ),
    ]);

    render(<DraftList workspaceId="ws-1" />);
    await waitFor(() => {
      expect(screen.getByText(/no drafts yet/i)).toBeDefined();
    });

    fireEvent.click(screen.getByText("New draft"));

    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith("/w/ws-1/drafts/d-new");
    });
    const post = calls.find((call) => call.method === "POST");
    expect(post).toBeDefined();
    expect(post?.body).toEqual({
      subject: "",
      document: { type: "doc", content: [{ type: "paragraph" }] },
    });
  });

  it("archives a draft and refreshes the list", async () => {
    let archived = false;
    stubFetch([
      on("GET", "/api/workspaces/ws-1/drafts", () =>
        jsonResponse(200, {
          drafts: [
            makeDraft({
              id: "d1",
              subject: "To archive",
              ...(archived
                ? {
                    status: "archived" as const,
                    archived_at: "2026-07-11T00:00:00.000Z",
                  }
                : {}),
            }),
          ],
        }),
      ),
      on("DELETE", "/api/workspaces/ws-1/drafts/d1", () => {
        archived = true;
        return jsonResponse(200, { archived: true });
      }),
    ]);

    render(<DraftList workspaceId="ws-1" />);
    await waitFor(() => {
      expect(screen.getByText("To archive")).toBeDefined();
    });

    fireEvent.click(screen.getByLabelText('Archive draft "To archive"'));
    await waitFor(() => {
      expect(screen.getByText("Archived")).toBeDefined();
    });
  });

  it("shows a sign-in-required state on 401 without crashing", async () => {
    stubFetch([
      on("GET", "/api/workspaces/ws-1/drafts", () =>
        apiErrorResponse(401, "unauthorized"),
      ),
    ]);

    render(<DraftList workspaceId="ws-1" />);

    await waitFor(() => {
      expect(screen.getByRole("alert").textContent).toContain(
        "Sign-in required",
      );
    });
    expect(screen.queryByText("New draft")).toBeNull();
  });
});
