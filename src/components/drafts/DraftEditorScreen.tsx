"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import type { Editor } from "@tiptap/react";
import {
  createEmptyDraftDocument,
  type DraftDocument,
} from "@/lib/composer/canonical";
import { AUTOSAVE_DEBOUNCE_MS } from "@/lib/phase2/contracts";
import type { DraftRecord, DraftVersionRecord } from "@/lib/phase2/contracts";
import {
  createDraft,
  DraftApiError,
  getDraft,
  saveDraft,
  type RestoreVersionResult,
} from "@/lib/drafts/api";
import { AutosaveController, type AutosaveStatus } from "@/lib/drafts/autosave";
import { ComposerEditor } from "@/components/composer/ComposerEditor";
import { DraftVersionHistory } from "./DraftVersionHistory";

const STATUS_LABELS: Record<AutosaveStatus, string> = {
  idle: "Saved",
  unsaved: "Unsaved",
  saving: "Saving…",
  saved: "Saved",
  offline: "Offline",
  conflict: "Conflict",
  error: "Save failed",
};

interface CompareMetadata {
  localLastSavedAt: string | null;
  remoteRevision: number;
  remoteUpdatedAt: string;
  remoteUpdatedBy: string;
}

export interface DraftEditorScreenProps {
  workspaceId: string;
  draftId: string;
  /** Test hook; defaults to the shared autosave policy. */
  debounceMs?: number;
  /** Test/integration hook to reach the Tiptap editor instance. */
  onEditorReady?: (editor: Editor) => void;
}

export function DraftEditorScreen({
  workspaceId,
  draftId,
  debounceMs = AUTOSAVE_DEBOUNCE_MS,
  onEditorReady,
}: DraftEditorScreenProps) {
  const enabled = process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED === "true";
  const router = useRouter();

  const [draft, setDraft] = useState<DraftRecord | null>(null);
  const [loadError, setLoadError] = useState<
    "unauthorized" | "not_found" | "failed" | null
  >(null);
  const [status, setStatus] = useState<AutosaveStatus>("idle");
  const [subject, setSubject] = useState("");
  const [revision, setRevision] = useState(0);
  const [compare, setCompare] = useState<CompareMetadata | null>(null);
  const [conflictActionError, setConflictActionError] = useState<string | null>(
    null,
  );

  const controllerRef = useRef<AutosaveController | null>(null);
  const editorRef = useRef<Editor | null>(null);
  const subjectRef = useRef("");
  const documentRef = useRef<DraftDocument>(createEmptyDraftDocument());
  const lastSavedAtRef = useRef<string | null>(null);

  useEffect(() => {
    if (!enabled) {
      return;
    }
    const abort = new AbortController();
    getDraft(workspaceId, draftId, { signal: abort.signal })
      .then((loaded) => {
        if (abort.signal.aborted) {
          return;
        }
        subjectRef.current = loaded.subject;
        documentRef.current = loaded.body_json;
        lastSavedAtRef.current = loaded.updated_at;
        setSubject(loaded.subject);
        setRevision(loaded.revision);
        const controller = new AutosaveController(
          async (snapshot, context) => {
            const result = await saveDraft(
              workspaceId,
              draftId,
              {
                expectedRevision: context.expectedRevision,
                subject: snapshot.subject,
                document: snapshot.document,
                saveReason:
                  context.trigger === "flush"
                    ? "manual_checkpoint"
                    : "autosave",
              },
              { signal: context.signal },
            );
            lastSavedAtRef.current = result.updated_at;
            return { revision: result.revision };
          },
          {
            initialRevision: loaded.revision,
            acknowledgedState: {
              subject: loaded.subject,
              document: loaded.body_json,
            },
            debounceMs,
            onStatusChange: (nextStatus) => {
              setStatus(nextStatus);
              setRevision(controller.expectedRevision);
            },
          },
        );
        controllerRef.current = controller;
        setDraft(loaded);
      })
      .catch((error: unknown) => {
        if (abort.signal.aborted) {
          return;
        }
        if (error instanceof DraftApiError) {
          if (error.code === "unauthorized") {
            setLoadError("unauthorized");
            return;
          }
          if (error.code === "not_found") {
            setLoadError("not_found");
            return;
          }
        }
        setLoadError("failed");
      });
    return () => {
      abort.abort();
      controllerRef.current?.dispose();
      controllerRef.current = null;
    };
  }, [enabled, workspaceId, draftId, debounceMs]);

  const scheduleSave = useCallback(() => {
    controllerRef.current?.schedule({
      subject: subjectRef.current,
      document: documentRef.current,
    });
  }, []);

  const handleDocumentChange = useCallback(
    (nextDocument: DraftDocument) => {
      documentRef.current = nextDocument;
      scheduleSave();
    },
    [scheduleSave],
  );

  const handleSubjectChange = useCallback(
    (value: string) => {
      subjectRef.current = value;
      setSubject(value);
      scheduleSave();
    },
    [scheduleSave],
  );

  const handleEditorReady = useCallback(
    (editor: Editor) => {
      editorRef.current = editor;
      onEditorReady?.(editor);
    },
    [onEditorReady],
  );

  /** Replace the editor with new acknowledged content (remote or restored). */
  const adoptContent = useCallback(
    (newSubject: string, newDocument: DraftDocument, newRevision: number) => {
      subjectRef.current = newSubject;
      documentRef.current = newDocument;
      setSubject(newSubject);
      editorRef.current?.commands.setContent(newDocument);
      controllerRef.current?.adoptRevision(newRevision, {
        subject: newSubject,
        document: newDocument,
      });
      setRevision(newRevision);
      setCompare(null);
      setConflictActionError(null);
    },
    [],
  );

  const handleReloadRemote = useCallback(async () => {
    try {
      const remote = await getDraft(workspaceId, draftId);
      lastSavedAtRef.current = remote.updated_at;
      adoptContent(remote.subject, remote.body_json, remote.revision);
    } catch {
      setConflictActionError("Reloading the remote version failed.");
    }
  }, [workspaceId, draftId, adoptContent]);

  const handleSaveAsNewDraft = useCallback(async () => {
    try {
      const created = await createDraft(workspaceId, {
        subject: subjectRef.current,
        document: documentRef.current,
      });
      router.push(`/w/${workspaceId}/drafts/${created.id}`);
    } catch {
      setConflictActionError("Saving your changes as a new draft failed.");
    }
  }, [workspaceId, router]);

  const handleCompareMetadata = useCallback(async () => {
    try {
      const remote = await getDraft(workspaceId, draftId);
      setCompare({
        localLastSavedAt: lastSavedAtRef.current,
        remoteRevision: remote.revision,
        remoteUpdatedAt: remote.updated_at,
        remoteUpdatedBy: remote.updated_by,
      });
      setConflictActionError(null);
    } catch {
      setConflictActionError("Loading the remote metadata failed.");
    }
  }, [workspaceId, draftId]);

  const handleRestored = useCallback(
    (version: DraftVersionRecord, result: RestoreVersionResult) => {
      adoptContent(version.subject, version.body_json, result.revision);
    },
    [adoptContent],
  );

  if (!enabled) {
    return (
      <main className="drafts-page">
        <h1>Draft editor</h1>
        <p>
          The draft lifecycle feature is disabled. Set
          <code> NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED=true </code>
          to enable this page.
        </p>
      </main>
    );
  }

  if (loadError === "unauthorized") {
    return (
      <main className="drafts-page">
        <h1>Draft editor</h1>
        <p role="alert">Sign-in required to open this draft.</p>
      </main>
    );
  }

  if (loadError !== null) {
    return (
      <main className="drafts-page">
        <h1>Draft editor</h1>
        <p role="alert">
          {loadError === "not_found"
            ? "This draft does not exist or is not accessible."
            : "Loading the draft failed. Reload the page to try again."}
        </p>
      </main>
    );
  }

  if (draft === null) {
    return (
      <main className="drafts-page" aria-busy="true">
        <h1>Draft editor</h1>
        <p>Loading draft…</p>
      </main>
    );
  }

  return (
    <main className="drafts-page">
      <h1>Draft editor</h1>
      <div className="draft-editor-header">
        <input
          type="text"
          className="draft-subject-input"
          aria-label="Subject"
          placeholder="Subject"
          value={subject}
          onChange={(event) => handleSubjectChange(event.target.value)}
        />
        <p
          className="draft-save-state"
          role="status"
          aria-live="polite"
          data-testid="draft-save-state"
        >
          {STATUS_LABELS[status]}
        </p>
        <div className="composer-lab-actions">
          <button
            type="button"
            onClick={() => void controllerRef.current?.flush()}
          >
            Save now
          </button>
        </div>
      </div>

      {status === "conflict" && (
        <section
          className="draft-conflict"
          role="alertdialog"
          aria-labelledby="draft-conflict-title"
          aria-describedby="draft-conflict-description"
        >
          <h2 id="draft-conflict-title">This draft changed elsewhere</h2>
          <p id="draft-conflict-description">
            Someone else (or another tab) saved a newer revision of this draft.
            Autosave is paused so nothing gets overwritten. Your local changes
            are kept in this editor — choose how to continue:
          </p>
          <div className="composer-lab-actions">
            <button type="button" onClick={() => void handleReloadRemote()}>
              Reload remote version
            </button>
            <button type="button" onClick={() => void handleSaveAsNewDraft()}>
              Save as new draft
            </button>
            <button type="button" onClick={() => void handleCompareMetadata()}>
              Compare metadata
            </button>
          </div>
          {compare !== null && (
            <dl className="draft-compare" data-testid="draft-compare">
              <dt>Your editor</dt>
              <dd>
                revision {revision}
                {compare.localLastSavedAt !== null
                  ? `, last saved ${compare.localLastSavedAt}`
                  : ""}
                , with unsaved local changes
              </dd>
              <dt>Remote draft</dt>
              <dd>
                revision {compare.remoteRevision}, updated{" "}
                {compare.remoteUpdatedAt} by {compare.remoteUpdatedBy}
              </dd>
            </dl>
          )}
          {conflictActionError !== null && (
            <p role="alert">{conflictActionError}</p>
          )}
        </section>
      )}

      <ComposerEditor
        initialDocument={draft.body_json}
        onDocumentChange={handleDocumentChange}
        onEditorReady={handleEditorReady}
      />

      <DraftVersionHistory
        workspaceId={workspaceId}
        draftId={draftId}
        currentRevision={revision}
        onRestored={handleRestored}
      />
    </main>
  );
}
