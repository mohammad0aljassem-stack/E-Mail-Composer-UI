import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DraftVersionHistory } from "@/components/drafts/DraftVersionHistory";
import type { RestoreVersionResult } from "@/lib/drafts/api";
import type { DraftVersionRecord } from "@/lib/phase2/contracts";
import {
  apiErrorResponse,
  createFetchMock,
  docWithText,
  jsonResponse,
  makeVersion,
  on,
  type FetchRoute,
} from "./helpers";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const versionsUrl = "/api/workspaces/ws-1/drafts/draft-1/versions";

const versions: DraftVersionRecord[] = [
  makeVersion({
    id: "v2",
    version_no: 2,
    source_revision: 2,
    subject: "Older subject",
    body_json: docWithText("Alter Inhalt mit Grüßen"),
    reason: "autosave_checkpoint",
    created_by: "user-bob",
  }),
  makeVersion({
    id: "v1",
    version_no: 1,
    subject: "First subject",
    body_json: docWithText("Erster Inhalt"),
    reason: "initial",
  }),
];

function stubFetch(routes: FetchRoute[]) {
  const { fetchMock, calls } = createFetchMock(routes);
  vi.stubGlobal("fetch", vi.fn(fetchMock));
  return { calls };
}

async function mountHistory(
  onRestored?: (
    version: DraftVersionRecord,
    result: RestoreVersionResult,
  ) => void,
) {
  render(
    <DraftVersionHistory
      workspaceId="ws-1"
      draftId="draft-1"
      currentRevision={7}
      onRestored={onRestored}
    />,
  );
  await waitFor(() => {
    expect(screen.getByLabelText("Preview version 2")).toBeDefined();
  });
}

describe("DraftVersionHistory", () => {
  it("lists versions with version number, reason label, and author", async () => {
    stubFetch([on("GET", versionsUrl, () => jsonResponse(200, { versions }))]);
    await mountHistory();

    expect(screen.getByText("Version 2")).toBeDefined();
    expect(screen.getByText("Version 1")).toBeDefined();
    expect(screen.getByText(/Autosave checkpoint/)).toBeDefined();
    expect(screen.getByText(/Initial version/)).toBeDefined();
    expect(screen.getByText(/user-bob/)).toBeDefined();
  });

  it("shows a read-only preview with historical subject and plain text", async () => {
    stubFetch([on("GET", versionsUrl, () => jsonResponse(200, { versions }))]);
    await mountHistory();

    fireEvent.click(screen.getByLabelText("Preview version 2"));

    expect(screen.getByText(/Older subject/)).toBeDefined();
    expect(screen.getByText("Alter Inhalt mit Grüßen")).toBeDefined();
    // Rendered as plain text, not injected markup.
    expect(document.querySelector(".draft-version-preview pre")).not.toBeNull();
  });

  it("restores only after confirmation and sends expectedRevision", async () => {
    const onRestored = vi.fn();
    const { calls } = stubFetch([
      on("GET", versionsUrl, () => jsonResponse(200, { versions })),
      on("POST", `${versionsUrl}/v2/restore`, () =>
        jsonResponse(200, { revision: 8, restored_from_version_no: 2 }),
      ),
    ]);
    await mountHistory(onRestored);

    fireEvent.click(screen.getByLabelText("Preview version 2"));
    fireEvent.click(screen.getByText("Restore this version"));

    // Confirmation step: nothing has been sent yet.
    expect(calls.filter((call) => call.method === "POST")).toHaveLength(0);
    expect(
      screen.getByText(/replaces the current draft content/i),
    ).toBeDefined();

    fireEvent.click(screen.getByText("Confirm restore"));

    await waitFor(() => {
      expect(screen.getByRole("status").textContent).toContain("revision 8");
    });
    const post = calls.find((call) => call.method === "POST");
    expect(post?.url).toBe(`${versionsUrl}/v2/restore`);
    expect(post?.body).toEqual({ expectedRevision: 7 });
    expect(onRestored).toHaveBeenCalledTimes(1);
    expect(onRestored.mock.calls[0]?.[1]).toEqual({
      revision: 8,
      restored_from_version_no: 2,
    });
  });

  it("cancel keeps the restore from happening", async () => {
    const { calls } = stubFetch([
      on("GET", versionsUrl, () => jsonResponse(200, { versions })),
    ]);
    await mountHistory();

    fireEvent.click(screen.getByLabelText("Preview version 2"));
    fireEvent.click(screen.getByText("Restore this version"));
    fireEvent.click(screen.getByText("Cancel"));

    expect(calls.filter((call) => call.method === "POST")).toHaveLength(0);
    expect(screen.getByText("Restore this version")).toBeDefined();
  });

  it("surfaces a 409 restore conflict as a visible message", async () => {
    stubFetch([
      on("GET", versionsUrl, () => jsonResponse(200, { versions })),
      on("POST", `${versionsUrl}/v2/restore`, () =>
        apiErrorResponse(409, "revision_conflict", { currentRevision: 12 }),
      ),
    ]);
    await mountHistory();

    fireEvent.click(screen.getByLabelText("Preview version 2"));
    fireEvent.click(screen.getByText("Restore this version"));
    fireEvent.click(screen.getByText("Confirm restore"));

    await waitFor(() => {
      expect(screen.getByRole("alert").textContent).toMatch(
        /conflict.*changed elsewhere/i,
      );
    });
    expect(screen.getByRole("alert").textContent).toContain("revision 12");
  });
});
