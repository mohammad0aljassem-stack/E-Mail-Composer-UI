import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
  type Mock,
} from "vitest";
import {
  AutosaveController,
  type AutosaveSaveCallback,
  type AutosaveSnapshot,
  type AutosaveStatus,
} from "@/lib/drafts/autosave";
import { DraftApiError } from "@/lib/drafts/api";
import { AUTOSAVE_DEBOUNCE_MS } from "@/lib/phase2/contracts";
import { docWithText } from "./helpers";

function snap(text: string, subject = "Subject"): AutosaveSnapshot {
  return { subject, document: docWithText(text) };
}

function setNavigatorOnline(value: boolean): void {
  Object.defineProperty(window.navigator, "onLine", {
    configurable: true,
    get: () => value,
  });
}

type SaveMock = Mock<AutosaveSaveCallback>;

interface ControllerHarness {
  controller: AutosaveController;
  save: SaveMock;
  statuses: AutosaveStatus[];
}

function makeController(
  save: SaveMock,
  options: { debounceMs?: number } = {},
): ControllerHarness {
  const statuses: AutosaveStatus[] = [];
  const controller = new AutosaveController(save, {
    initialRevision: 1,
    acknowledgedState: snap("start"),
    onStatusChange: (status) => {
      statuses.push(status);
    },
    ...options,
  });
  return { controller, save, statuses };
}

beforeEach(() => {
  vi.useFakeTimers();
  setNavigatorOnline(true);
});

afterEach(() => {
  vi.useRealTimers();
  setNavigatorOnline(true);
});

describe("AutosaveController", () => {
  it("debounces: no save before AUTOSAVE_DEBOUNCE_MS, one save after", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => ({ revision: 2 }));
    const { controller, statuses } = makeController(save);

    controller.schedule(snap("changed"));
    expect(controller.status).toBe("unsaved");

    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS - 1);
    expect(save).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(save).toHaveBeenCalledTimes(1);
    expect(controller.status).toBe("saved");
    expect(statuses).toEqual(["unsaved", "saving", "saved"]);
  });

  it("coalesces rapid edits into a single request with the latest state", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => ({ revision: 2 }));
    const { controller } = makeController(save);

    controller.schedule(snap("one"));
    await vi.advanceTimersByTimeAsync(500);
    controller.schedule(snap("two"));
    await vi.advanceTimersByTimeAsync(500);
    controller.schedule(snap("three"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);

    expect(save).toHaveBeenCalledTimes(1);
    expect(save.mock.calls[0]?.[0]).toEqual(snap("three"));
  });

  it("skips the save when content is identical to the last acknowledged state", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => ({ revision: 2 }));
    const { controller } = makeController(save);

    controller.schedule(snap("start"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS * 2);

    expect(save).not.toHaveBeenCalled();
    expect(controller.status).toBe("idle");

    // Edit away and back before the debounce fires: still no save.
    controller.schedule(snap("temporary"));
    controller.schedule(snap("start"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS * 2);
    expect(save).not.toHaveBeenCalled();
  });

  it("aborts a stale in-flight save when a newer save supersedes it", async () => {
    const signals: AbortSignal[] = [];
    const resolvers: Array<(value: { revision: number }) => void> = [];
    const rejecters: Array<(reason: unknown) => void> = [];
    const save = vi.fn<AutosaveSaveCallback>(
      (_snapshot: AutosaveSnapshot, context: { signal: AbortSignal }) => {
        signals.push(context.signal);
        return new Promise<{ revision: number }>((resolve, reject) => {
          resolvers.push(resolve);
          rejecters.push(reject);
        });
      },
    );
    const { controller } = makeController(save);

    controller.schedule(snap("one"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(save).toHaveBeenCalledTimes(1);

    controller.schedule(snap("two"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(save).toHaveBeenCalledTimes(2);

    // The first request was cancelled, the second one is live.
    expect(signals[0]?.aborted).toBe(true);
    expect(signals[1]?.aborted).toBe(false);

    // The stale rejection (fetch abort) is ignored.
    const abortError = new Error("The operation was aborted.");
    abortError.name = "AbortError";
    rejecters[0]?.(abortError);
    resolvers[1]?.({ revision: 5 });
    await vi.advanceTimersByTimeAsync(0);

    expect(controller.status).toBe("saved");
    expect(controller.expectedRevision).toBe(5);
  });

  it("on 409 enters conflict, halts autosave, and preserves pending changes", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => {
      throw new DraftApiError({
        code: "revision_conflict",
        status: 409,
        message: "conflict",
        currentRevision: 7,
      });
    });
    const { controller } = makeController(save);

    controller.schedule(snap("local edit"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);

    expect(controller.status).toBe("conflict");
    expect(controller.getConflict()).toEqual({ remoteRevision: 7 });

    // Further edits and flushes never save while the conflict is unresolved.
    save.mockClear();
    controller.schedule(snap("more local edits"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS * 3);
    await controller.flush();
    expect(save).not.toHaveBeenCalled();
    expect(controller.status).toBe("conflict");
    expect(controller.getPendingSnapshot()).toEqual(snap("more local edits"));

    // Resolution (e.g. reload remote) re-arms autosave with the new revision.
    save.mockImplementation(async () => ({ revision: 8 }));
    controller.adoptRevision(7, snap("remote content"));
    expect(controller.status).toBe("saved");
    expect(controller.getConflict()).toBeNull();

    controller.schedule(snap("post-conflict edit"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(save).toHaveBeenCalledTimes(1);
    expect(save.mock.calls[0]?.[1]).toMatchObject({ expectedRevision: 7 });
  });

  it("reports Offline when navigator is offline and retries on flush", async () => {
    setNavigatorOnline(false);
    const save = vi.fn<AutosaveSaveCallback>(async () => {
      throw new TypeError("fetch failed");
    });
    const { controller } = makeController(save);

    controller.schedule(snap("edited while offline"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);

    expect(save).toHaveBeenCalledTimes(1);
    expect(controller.status).toBe("offline");
    expect(controller.getPendingSnapshot()).toEqual(
      snap("edited while offline"),
    );

    // Back online: flush retries the preserved pending changes.
    setNavigatorOnline(true);
    save.mockImplementation(async () => ({ revision: 2 }));
    await controller.flush();

    expect(save).toHaveBeenCalledTimes(2);
    expect(save.mock.calls[1]?.[0]).toEqual(snap("edited while offline"));
    expect(controller.status).toBe("saved");
  });

  it("reports a save failure as error when online and retries on next change", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => {
      throw new TypeError("fetch failed");
    });
    const { controller } = makeController(save);

    controller.schedule(snap("edit"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(controller.status).toBe("error");

    save.mockImplementation(async () => ({ revision: 2 }));
    controller.schedule(snap("edit again"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(controller.status).toBe("saved");
    expect(save).toHaveBeenCalledTimes(2);
  });

  it("flush() forces an immediate save without waiting for the debounce", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => ({ revision: 2 }));
    const { controller } = makeController(save);

    controller.schedule(snap("changed"));
    expect(save).not.toHaveBeenCalled();

    await controller.flush();
    expect(save).toHaveBeenCalledTimes(1);
    expect(save.mock.calls[0]?.[1]).toMatchObject({ trigger: "flush" });
    expect(controller.status).toBe("saved");

    // The debounce timer was cancelled — no duplicate save afterwards.
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS * 2);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it("adopts the revision returned by a successful save for the next save", async () => {
    const save = vi.fn<AutosaveSaveCallback>(async () => ({ revision: 5 }));
    const { controller } = makeController(save);

    controller.schedule(snap("first edit"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(save.mock.calls[0]?.[1]).toMatchObject({ expectedRevision: 1 });
    expect(controller.expectedRevision).toBe(5);

    save.mockImplementation(async () => ({ revision: 6 }));
    controller.schedule(snap("second edit"));
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DEBOUNCE_MS);
    expect(save.mock.calls[1]?.[1]).toMatchObject({ expectedRevision: 5 });
    expect(controller.expectedRevision).toBe(6);
  });
});
