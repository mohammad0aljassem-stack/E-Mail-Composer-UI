import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Editor } from "@tiptap/react";
import { DraftEditorScreen } from "@/components/drafts/DraftEditorScreen";
import type { DraftRecord } from "@/lib/phase2/contracts";
import {
  apiErrorResponse,
  createFetchMock,
  docWithText,
  jsonResponse,
  makeDraft,
  on,
  type FetchRoute,
  type RecordedFetchCall,
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

const draftUrl = "/api/workspaces/ws-1/drafts/draft-1";
const versionsUrl = `${draftUrl}/versions`;
const draftsUrl = "/api/workspaces/ws-1/drafts";

function baseDraft(): DraftRecord {
  return makeDraft({
    id: "draft-1",
    workspace_id: "ws-1",
    subject: "Quarterly update",
    body_json: docWithText("Hallo Welt"),
    revision: 3,
  });
}

function saveState(): string {
  return screen.getByTestId("draft-save-state").textContent ?? "";
}

interface MountResult {
  editor: Editor;
  calls: RecordedFetchCall[];
}

async function mountScreen(routes: FetchRoute[]): Promise<MountResult> {
  const { fetchMock, calls } = createFetchMock([
    on("GET", versionsUrl, () => jsonResponse(200, { versions: [] })),
    ...routes,
  ]);
  vi.stubGlobal("fetch", vi.fn(fetchMock));
  let editor: Editor | null = null;
  render(
    <DraftEditorScreen
      workspaceId="ws-1"
      draftId="draft-1"
      debounceMs={25}
      onEditorReady={(instance) => {
        editor = instance;
      }}
    />,
  );
  await waitFor(() => {
    expect(editor).not.toBeNull();
  });
  return { editor: editor as unknown as Editor, calls };
}

function typeInEditor(editor: Editor, text: string): void {
  act(() => {
    editor.commands.focus("end");
    editor.commands.insertContent(text);
  });
}

async function provokeConflict(editor: Editor): Promise<void> {
  typeInEditor(editor, " lokale Änderung");
  await waitFor(() => {
    expect(screen.getByRole("alertdialog")).toBeDefined();
  });
}

const conflictRoutes = (getRemote: () => DraftRecord): FetchRoute[] => [
  on("GET", draftUrl, () => jsonResponse(200, { draft: getRemote() })),
  on("PATCH", draftUrl, () =>
    apiErrorResponse(409, "revision_conflict", { currentRevision: 9 }),
  ),
];

describe("DraftEditorScreen", () => {
  it("renders subject input and editor content from the loaded draft", async () => {
    const { editor } = await mountScreen([
      on("GET", draftUrl, () => jsonResponse(200, { draft: baseDraft() })),
    ]);

    const subject = screen.getByLabelText("Subject") as HTMLInputElement;
    expect(subject.value).toBe("Quarterly update");
    expect(editor.getText()).toContain("Hallo Welt");
    expect(saveState()).toBe("Saved");
  });

  it("shows a sign-in-required state when loading returns 401", async () => {
    const { fetchMock } = createFetchMock([
      on("GET", draftUrl, () => apiErrorResponse(401, "unauthorized")),
    ]);
    vi.stubGlobal("fetch", vi.fn(fetchMock));
    render(<DraftEditorScreen workspaceId="ws-1" draftId="draft-1" />);
    await waitFor(() => {
      expect(screen.getByRole("alert").textContent).toContain(
        "Sign-in required",
      );
    });
  });

  it("typing walks the save state through Unsaved, Saving… and Saved", async () => {
    let resolvePatch: (response: Response) => void = () => {};
    const { editor, calls } = await mountScreen([
      on("GET", draftUrl, () => jsonResponse(200, { draft: baseDraft() })),
      on(
        "PATCH",
        draftUrl,
        () =>
          new Promise<Response>((resolve) => {
            resolvePatch = resolve;
          }),
      ),
    ]);

    typeInEditor(editor, " mit mehr Inhalt");
    expect(saveState()).toBe("Unsaved");

    await waitFor(() => {
      expect(saveState()).toBe("Saving…");
    });

    resolvePatch(
      jsonResponse(200, {
        revision: 4,
        updated_at: "2026-07-11T09:00:00.000Z",
        last_autosaved_at: "2026-07-11T09:00:00.000Z",
        version_created: false,
      }),
    );
    await waitFor(() => {
      expect(saveState()).toBe("Saved");
    });

    const patch = calls.find((call) => call.method === "PATCH");
    expect(patch).toBeDefined();
    const body = patch?.body as {
      expectedRevision: number;
      subject: string;
      document: unknown;
      saveReason: string;
    };
    expect(body.expectedRevision).toBe(3);
    expect(body.saveReason).toBe("autosave");
    expect(body.subject).toBe("Quarterly update");
    expect(JSON.stringify(body.document)).toContain("mit mehr Inhalt");
  });

  it("shows the conflict UI with exactly the three safe options on 409", async () => {
    const { editor } = await mountScreen(conflictRoutes(baseDraft));

    await provokeConflict(editor);

    expect(saveState()).toBe("Conflict");
    const dialog = screen.getByRole("alertdialog");
    expect(dialog.textContent).toContain("changed elsewhere");

    expect(
      screen.getByRole("button", { name: "Reload remote version" }),
    ).toBeDefined();
    expect(
      screen.getByRole("button", { name: "Save as new draft" }),
    ).toBeDefined();
    expect(
      screen.getByRole("button", { name: "Compare metadata" }),
    ).toBeDefined();

    // No overwrite-remote option — never last-write-wins.
    expect(screen.queryByRole("button", { name: /overwrite/i })).toBeNull();
    expect(dialog.querySelectorAll("button")).toHaveLength(3);
  });

  it("compare metadata shows local vs remote revision and author", async () => {
    let remote = baseDraft();
    const { editor } = await mountScreen(conflictRoutes(() => remote));

    await provokeConflict(editor);
    remote = makeDraft({
      ...baseDraft(),
      revision: 9,
      updated_at: "2026-07-11T08:30:00.000Z",
      updated_by: "user-bob",
    });
    fireEvent.click(screen.getByRole("button", { name: "Compare metadata" }));

    await waitFor(() => {
      expect(screen.getByTestId("draft-compare")).toBeDefined();
    });
    const compare = screen.getByTestId("draft-compare").textContent ?? "";
    expect(compare).toContain("revision 3");
    expect(compare).toContain("revision 9");
    expect(compare).toContain("user-bob");
  });

  it("save as new draft POSTs the current editor content and navigates", async () => {
    const { editor, calls } = await mountScreen([
      ...conflictRoutes(baseDraft),
      on("POST", draftsUrl, () =>
        jsonResponse(200, { draft: makeDraft({ id: "draft-copy" }) }),
      ),
    ]);

    await provokeConflict(editor);
    fireEvent.click(screen.getByRole("button", { name: "Save as new draft" }));

    await waitFor(() => {
      expect(routerPush).toHaveBeenCalledWith("/w/ws-1/drafts/draft-copy");
    });
    const post = calls.find(
      (call) => call.method === "POST" && call.url === draftsUrl,
    );
    expect(post).toBeDefined();
    const body = post?.body as { subject: string; document: unknown };
    expect(body.subject).toBe("Quarterly update");
    expect(JSON.stringify(body.document)).toContain("lokale Änderung");
  });

  it("reload remote version replaces the content and clears the conflict", async () => {
    let remote = baseDraft();
    const { editor } = await mountScreen(conflictRoutes(() => remote));

    await provokeConflict(editor);

    remote = makeDraft({
      id: "draft-1",
      workspace_id: "ws-1",
      subject: "Remote subject",
      body_json: docWithText("Remote Inhalt"),
      revision: 9,
      updated_by: "user-bob",
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Reload remote version" }),
    );

    await waitFor(() => {
      expect(screen.queryByRole("alertdialog")).toBeNull();
    });
    const subject = screen.getByLabelText("Subject") as HTMLInputElement;
    expect(subject.value).toBe("Remote subject");
    expect(editor.getText()).toContain("Remote Inhalt");
    expect(editor.getText()).not.toContain("lokale Änderung");
    expect(saveState()).toBe("Saved");
  });
});
