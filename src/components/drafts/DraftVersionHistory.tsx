"use client";

import { useCallback, useEffect, useState } from "react";
import type {
  DraftSaveReason,
  DraftVersionRecord,
} from "@/lib/phase2/contracts";
import { renderPlainText } from "@/lib/composer/plain-text";
import {
  DraftApiError,
  listDraftVersions,
  restoreDraftVersion,
  type RestoreVersionResult,
} from "@/lib/drafts/api";
import { formatRelativeTime } from "@/lib/drafts/relative-time";

const REASON_LABELS: Record<DraftSaveReason, string> = {
  initial: "Initial version",
  autosave: "Autosave",
  autosave_checkpoint: "Autosave checkpoint",
  manual_checkpoint: "Manual checkpoint",
  before_template: "Before template",
  after_template: "After template",
  before_signature: "Before signature",
  after_signature: "After signature",
  restore: "Restore",
};

export interface DraftVersionHistoryProps {
  workspaceId: string;
  draftId: string;
  /** Revision the restore call asserts via optimistic concurrency. */
  currentRevision: number;
  /** Called after a successful restore so the editor can adopt the content. */
  onRestored?: (
    version: DraftVersionRecord,
    result: RestoreVersionResult,
  ) => void;
}

export function DraftVersionHistory({
  workspaceId,
  draftId,
  currentRevision,
  onRestored,
}: DraftVersionHistoryProps) {
  const [versions, setVersions] = useState<DraftVersionRecord[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [confirmingRestore, setConfirmingRestore] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const loadVersions = useCallback(
    (signal?: AbortSignal) =>
      listDraftVersions(workspaceId, draftId, { signal }).then(
        (loaded) => {
          if (signal?.aborted) {
            return;
          }
          setVersions(loaded);
          setLoadError(null);
        },
        (error: unknown) => {
          if (signal?.aborted) {
            return;
          }
          setLoadError(
            error instanceof DraftApiError && error.code === "unauthorized"
              ? "Sign-in required to view the version history."
              : "Loading the version history failed.",
          );
        },
      ),
    [workspaceId, draftId],
  );

  useEffect(() => {
    const abort = new AbortController();
    void loadVersions(abort.signal);
    return () => {
      abort.abort();
    };
  }, [loadVersions]);

  const selected =
    versions?.find((version) => version.id === selectedId) ?? null;

  const handleSelect = useCallback((versionId: string) => {
    setSelectedId(versionId);
    setConfirmingRestore(false);
    setMessage(null);
    setErrorMessage(null);
  }, []);

  const handleConfirmRestore = useCallback(async () => {
    if (!selected || restoring) {
      return;
    }
    setRestoring(true);
    setMessage(null);
    setErrorMessage(null);
    try {
      const result = await restoreDraftVersion(
        workspaceId,
        draftId,
        selected.id,
        { expectedRevision: currentRevision },
      );
      setConfirmingRestore(false);
      setMessage(
        `Restored version ${result.restored_from_version_no}. ` +
          `The draft is now at revision ${result.revision}.`,
      );
      onRestored?.(selected, result);
      void loadVersions();
    } catch (error) {
      if (
        error instanceof DraftApiError &&
        error.code === "revision_conflict"
      ) {
        setErrorMessage(
          "Restore conflict: the draft changed elsewhere while you were " +
            "looking at the history" +
            (typeof error.currentRevision === "number"
              ? ` (server is at revision ${error.currentRevision})`
              : "") +
            ". Nothing was overwritten — review the draft and try again.",
        );
      } else {
        setErrorMessage("Restoring this version failed.");
      }
    } finally {
      setRestoring(false);
    }
  }, [
    selected,
    restoring,
    workspaceId,
    draftId,
    currentRevision,
    onRestored,
    loadVersions,
  ]);

  return (
    <section className="draft-version-history" aria-label="Version history">
      <h2>Version history</h2>
      {loadError !== null && <p role="alert">{loadError}</p>}
      {versions !== null && versions.length === 0 && (
        <p className="draft-muted">No saved versions yet.</p>
      )}
      {versions !== null && versions.length > 0 && (
        <ul className="draft-version-list">
          {versions.map((version) => (
            <li key={version.id}>
              <button
                type="button"
                className="composer-toolbar-button draft-version-button"
                aria-pressed={version.id === selectedId}
                aria-label={`Preview version ${version.version_no}`}
                onClick={() => handleSelect(version.id)}
              >
                <span>Version {version.version_no}</span>
                <span className="draft-muted">
                  {REASON_LABELS[version.reason]} ·{" "}
                  {formatRelativeTime(version.created_at)} · by{" "}
                  {version.created_by}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
      {selected !== null && (
        <div className="draft-version-preview">
          <h3>Version {selected.version_no} (read-only preview)</h3>
          <p>
            <strong>Subject:</strong>{" "}
            {selected.subject.length > 0 ? selected.subject : "(no subject)"}
          </p>
          <pre className="composer-text">
            {renderPlainText(selected.body_json)}
          </pre>
          {!confirmingRestore ? (
            <div className="composer-lab-actions">
              <button
                type="button"
                onClick={() => {
                  setConfirmingRestore(true);
                  setMessage(null);
                  setErrorMessage(null);
                }}
              >
                Restore this version
              </button>
            </div>
          ) : (
            <div className="draft-restore-confirm">
              <p>
                Restoring replaces the current draft content with version{" "}
                {selected.version_no}. The current content is kept in the
                version history.
              </p>
              <div className="composer-lab-actions">
                <button
                  type="button"
                  disabled={restoring}
                  onClick={() => void handleConfirmRestore()}
                >
                  Confirm restore
                </button>
                <button
                  type="button"
                  onClick={() => setConfirmingRestore(false)}
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      )}
      {message !== null && (
        <p className="draft-muted" role="status">
          {message}
        </p>
      )}
      {errorMessage !== null && <p role="alert">{errorMessage}</p>}
    </section>
  );
}
