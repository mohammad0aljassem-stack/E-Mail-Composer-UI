/**
 * Framework-agnostic autosave controller for the draft editor.
 *
 * Responsibilities:
 * - debounce document/subject changes into one save request;
 * - cancel stale in-flight saves (AbortController) when a newer save starts;
 * - skip saves whose content is identical to the last acknowledged state;
 * - carry the optimistic-concurrency revision forward from successful saves;
 * - on a revision conflict (409), enter the "conflict" state and STOP saving
 *   until the conflict is explicitly resolved — never last-write-wins;
 * - on network failure, report "offline"/"error", keep the pending changes,
 *   and retry on the next change or flush().
 *
 * The controller is deterministic and free of framework imports so it can be
 * unit-tested with fake timers.
 */

import { AUTOSAVE_DEBOUNCE_MS } from "@/lib/phase2/contracts";
import type { DraftDocument } from "@/lib/composer/canonical";

export type AutosaveStatus =
  "idle" | "unsaved" | "saving" | "saved" | "offline" | "conflict" | "error";

/** What triggered a save attempt. */
export type AutosaveTrigger = "debounce" | "flush";

export interface AutosaveSnapshot {
  subject: string;
  document: DraftDocument;
}

export interface AutosaveSaveContext {
  expectedRevision: number;
  signal: AbortSignal;
  trigger: AutosaveTrigger;
}

export type AutosaveSaveCallback = (
  snapshot: AutosaveSnapshot,
  context: AutosaveSaveContext,
) => Promise<{ revision: number }>;

export interface AutosaveConflict {
  /** Server-side revision reported with the conflict, when available. */
  remoteRevision: number | null;
}

export interface AutosaveControllerOptions {
  /** Revision of the draft as loaded (optimistic-concurrency baseline). */
  initialRevision: number;
  /** Content matching `initialRevision`; identical content is never saved. */
  acknowledgedState: AutosaveSnapshot;
  debounceMs?: number;
  onStatusChange?: (status: AutosaveStatus) => void;
}

function serialize(snapshot: AutosaveSnapshot): string {
  return JSON.stringify({
    subject: snapshot.subject,
    document: snapshot.document,
  });
}

function isAbortError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.name === "AbortError" ||
      (error.cause instanceof Error && error.cause.name === "AbortError"))
  );
}

function isRevisionConflict(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { code?: unknown }).code === "revision_conflict"
  );
}

function conflictRevisionOf(error: unknown): number | null {
  const revision = (error as { currentRevision?: unknown }).currentRevision;
  return typeof revision === "number" ? revision : null;
}

function isNavigatorOffline(): boolean {
  return typeof navigator !== "undefined" && navigator.onLine === false;
}

interface InFlightSave {
  controller: AbortController;
  serialized: string;
}

export class AutosaveController {
  private readonly save: AutosaveSaveCallback;
  private readonly debounceMs: number;
  private readonly listeners = new Set<(status: AutosaveStatus) => void>();

  private statusValue: AutosaveStatus = "idle";
  private revision: number;
  private acknowledgedSerialized: string;
  private pending: AutosaveSnapshot | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private inFlight: InFlightSave | null = null;
  private conflictValue: AutosaveConflict | null = null;
  private hasSavedOnce = false;
  private disposed = false;

  constructor(save: AutosaveSaveCallback, options: AutosaveControllerOptions) {
    this.save = save;
    this.debounceMs = options.debounceMs ?? AUTOSAVE_DEBOUNCE_MS;
    this.revision = options.initialRevision;
    this.acknowledgedSerialized = serialize(options.acknowledgedState);
    if (options.onStatusChange) {
      this.listeners.add(options.onStatusChange);
    }
  }

  get status(): AutosaveStatus {
    return this.statusValue;
  }

  /** The revision the next save will assert via optimistic concurrency. */
  get expectedRevision(): number {
    return this.revision;
  }

  getConflict(): AutosaveConflict | null {
    return this.conflictValue;
  }

  hasPendingChanges(): boolean {
    return this.pending !== null;
  }

  /** Latest unsaved local content (preserved across failures/conflicts). */
  getPendingSnapshot(): AutosaveSnapshot | null {
    return this.pending;
  }

  /** Subscribe to status changes; returns an unsubscribe function. */
  onStatusChange(listener: (status: AutosaveStatus) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /**
   * Note a document/subject change. Debounces a save unless the controller
   * is in the conflict state (then only the pending snapshot is updated —
   * autosave stays halted until the conflict is resolved).
   */
  schedule(snapshot: AutosaveSnapshot): void {
    if (this.disposed) {
      return;
    }
    if (this.conflictValue !== null) {
      this.pending = snapshot;
      return;
    }
    const serialized = serialize(snapshot);
    if (serialized === this.acknowledgedSerialized) {
      this.pending = null;
      this.clearTimer();
      this.setStatus(this.hasSavedOnce ? "saved" : "idle");
      return;
    }
    this.pending = snapshot;
    this.setStatus("unsaved");
    this.clearTimer();
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.performSave("debounce");
    }, this.debounceMs);
  }

  /**
   * Save immediately (explicit user action). No-op while a conflict is
   * unresolved — resolving it must be an explicit, visible decision.
   */
  async flush(): Promise<void> {
    if (this.disposed || this.conflictValue !== null) {
      return;
    }
    this.clearTimer();
    await this.performSave("flush");
  }

  /**
   * Adopt a new acknowledged revision + content (after "reload remote
   * version" or a successful version restore). Clears any conflict and
   * discards pending changes — callers replace the editor content in the
   * same step, so the snapshot passed here is what the user now sees.
   */
  adoptRevision(revision: number, acknowledged: AutosaveSnapshot): void {
    if (this.disposed) {
      return;
    }
    this.clearTimer();
    this.abortInFlight();
    this.revision = revision;
    this.acknowledgedSerialized = serialize(acknowledged);
    this.pending = null;
    this.conflictValue = null;
    this.hasSavedOnce = true;
    this.setStatus("saved");
  }

  dispose(): void {
    this.disposed = true;
    this.clearTimer();
    this.abortInFlight();
    this.listeners.clear();
  }

  private setStatus(status: AutosaveStatus): void {
    if (this.statusValue === status) {
      return;
    }
    this.statusValue = status;
    for (const listener of this.listeners) {
      listener(status);
    }
  }

  private clearTimer(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  private abortInFlight(): void {
    if (this.inFlight !== null) {
      const stale = this.inFlight;
      this.inFlight = null;
      stale.controller.abort();
    }
  }

  private async performSave(trigger: AutosaveTrigger): Promise<void> {
    if (this.disposed || this.conflictValue !== null || this.pending === null) {
      return;
    }
    const snapshot = this.pending;
    const serialized = serialize(snapshot);
    if (serialized === this.acknowledgedSerialized) {
      this.pending = null;
      this.setStatus(this.hasSavedOnce ? "saved" : "idle");
      return;
    }
    // A newer save supersedes any still-running one.
    this.abortInFlight();
    const attempt: InFlightSave = {
      controller: new AbortController(),
      serialized,
    };
    this.inFlight = attempt;
    this.setStatus("saving");
    try {
      const result = await this.save(snapshot, {
        expectedRevision: this.revision,
        signal: attempt.controller.signal,
        trigger,
      });
      if (this.inFlight !== attempt || this.disposed) {
        return; // superseded by a newer save or disposed — ignore.
      }
      this.inFlight = null;
      this.revision = result.revision;
      this.acknowledgedSerialized = serialized;
      this.hasSavedOnce = true;
      if (this.pending !== null && serialize(this.pending) === serialized) {
        this.pending = null;
        this.setStatus("saved");
      } else {
        // The user kept typing while the save ran; the newer change has
        // already re-scheduled a debounce.
        this.setStatus("unsaved");
      }
    } catch (error) {
      if (this.inFlight !== attempt || this.disposed) {
        return; // stale attempt (aborted by a newer save) — ignore.
      }
      this.inFlight = null;
      if (isAbortError(error)) {
        return;
      }
      if (isRevisionConflict(error)) {
        // Never overwrite remote work: halt autosaving, keep local changes.
        this.conflictValue = { remoteRevision: conflictRevisionOf(error) };
        this.setStatus("conflict");
        return;
      }
      // Pending changes stay; the next schedule()/flush() retries.
      this.setStatus(isNavigatorOffline() ? "offline" : "error");
    }
  }
}
