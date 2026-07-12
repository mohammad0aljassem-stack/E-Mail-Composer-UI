"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createEmptyDraftDocument } from "@/lib/composer/canonical";
import type { DraftRecord } from "@/lib/phase2/contracts";
import {
  archiveDraft,
  createDraft,
  DraftApiError,
  listDrafts,
} from "@/lib/drafts/api";
import { formatRelativeTime } from "@/lib/drafts/relative-time";

function subjectLabel(draft: DraftRecord): string {
  return draft.subject.length > 0 ? draft.subject : "(no subject)";
}

export interface DraftListProps {
  workspaceId: string;
}

export function DraftList({ workspaceId }: DraftListProps) {
  const enabled = process.env.NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED === "true";
  const router = useRouter();

  const [drafts, setDrafts] = useState<DraftRecord[] | null>(null);
  const [loadError, setLoadError] = useState<"unauthorized" | "failed" | null>(
    null,
  );
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  const loadDrafts = useCallback(
    (signal?: AbortSignal) =>
      listDrafts(workspaceId, { signal }).then(
        (loaded) => {
          if (signal?.aborted) {
            return;
          }
          setDrafts(loaded);
          setLoadError(null);
        },
        (error: unknown) => {
          if (signal?.aborted) {
            return;
          }
          setLoadError(
            error instanceof DraftApiError && error.code === "unauthorized"
              ? "unauthorized"
              : "failed",
          );
        },
      ),
    [workspaceId],
  );

  useEffect(() => {
    if (!enabled) {
      return;
    }
    const abort = new AbortController();
    void loadDrafts(abort.signal);
    return () => {
      abort.abort();
    };
  }, [enabled, loadDrafts]);

  const handleNewDraft = useCallback(async () => {
    if (busy) {
      return;
    }
    setBusy(true);
    setActionError(null);
    try {
      const created = await createDraft(workspaceId, {
        subject: "",
        document: createEmptyDraftDocument(),
      });
      router.push(`/w/${workspaceId}/drafts/${created.id}`);
    } catch (error) {
      setActionError(
        error instanceof DraftApiError && error.code === "unauthorized"
          ? "Sign-in required to create a draft."
          : "Creating a new draft failed.",
      );
    } finally {
      setBusy(false);
    }
  }, [busy, workspaceId, router]);

  const handleArchive = useCallback(
    async (draft: DraftRecord) => {
      setActionError(null);
      try {
        await archiveDraft(workspaceId, draft.id, {
          expectedRevision: draft.revision,
        });
        await loadDrafts();
      } catch {
        setActionError("Archiving the draft failed.");
      }
    },
    [workspaceId, loadDrafts],
  );

  if (!enabled) {
    return (
      <main className="drafts-page">
        <h1>Drafts</h1>
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
        <h1>Drafts</h1>
        <p role="alert">Sign-in required to view your drafts.</p>
      </main>
    );
  }

  return (
    <main className="drafts-page">
      <h1>Drafts</h1>
      <div className="composer-lab-actions">
        <button
          type="button"
          disabled={busy}
          onClick={() => void handleNewDraft()}
        >
          New draft
        </button>
      </div>
      {actionError !== null && <p role="alert">{actionError}</p>}
      {loadError === "failed" && (
        <p role="alert">Loading drafts failed. Reload the page to try again.</p>
      )}
      {drafts !== null && drafts.length === 0 && (
        <p className="draft-muted">No drafts yet. Create one to get started.</p>
      )}
      {drafts !== null && drafts.length > 0 && (
        <ul className="draft-list">
          {drafts.map((draft) => (
            <li key={draft.id} className="draft-list-item">
              <a
                className="draft-list-link"
                href={`/w/${workspaceId}/drafts/${draft.id}`}
              >
                <span className="draft-list-subject">
                  {subjectLabel(draft)}
                </span>
                <span className="draft-muted">
                  Updated {formatRelativeTime(draft.updated_at)} ·{" "}
                  {draft.status}
                </span>
              </a>
              {draft.status === "archived" ? (
                <span className="draft-badge-archived">Archived</span>
              ) : (
                <button
                  type="button"
                  className="composer-toolbar-button"
                  aria-label={`Archive draft "${subjectLabel(draft)}"`}
                  onClick={() => void handleArchive(draft)}
                >
                  Archive
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
