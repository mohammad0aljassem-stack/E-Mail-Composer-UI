"use client";

/**
 * Attachment panel: file selection, per-row status, remove/retry actions.
 *
 * Security notes:
 * - Filenames are always rendered as React children (plain text) — never as
 *   HTML — so a malicious filename cannot inject markup.
 * - No content previews: no <img>, no iframe, no object URLs. Icon and text
 *   only.
 * - Selections are pre-validated with the shared validation module BEFORE
 *   any upload starts; rejected files never reach the upload callback and
 *   the reason is shown to the user.
 */

import { useCallback, useId, useRef, useState, type ChangeEvent } from "react";
import {
  ATTACHMENT_MAX_COUNT_PER_DRAFT,
  ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";
import { validateAttachmentPlan } from "@/lib/attachments/validation";
import { formatByteSize } from "@/lib/attachments/format";

export interface AttachmentPanelProps {
  attachments: AttachmentRecord[];
  /** Receives only files that passed client-side pre-validation. */
  onSelectFiles: (files: File[]) => void;
  onRemove: (attachmentId: string) => void;
  onRetry: (attachmentId: string) => void;
  disabled?: boolean;
}

const ACCEPTED_EXTENSIONS = ".pdf,.png,.jpg,.jpeg,.txt";

function isActive(record: AttachmentRecord): boolean {
  return record.status !== "deleted" && record.deleted_at === null;
}

/**
 * Placeholder record so files accepted earlier in the same selection batch
 * count against the count/total-size limits for the files after them.
 */
function planPlaceholder(file: File, index: number): AttachmentRecord {
  return {
    id: `candidate-${index}`,
    workspace_id: "",
    draft_id: "",
    storage_bucket: "",
    storage_path: "",
    original_filename: file.name,
    safe_filename: "",
    mime_type: file.type,
    size_bytes: file.size,
    sha256: null,
    status: "pending",
    created_by: "",
    verified_at: null,
    deleted_at: null,
    created_at: "",
  };
}

function statusChip(record: AttachmentRecord): {
  label: string;
  modifier: string;
} {
  switch (record.status) {
    case "pending":
      return { label: "Uploading…", modifier: "pending" };
    case "ready":
      return { label: "Attached", modifier: "ready" };
    case "failed":
      return { label: "Failed", modifier: "failed" };
    case "deleted":
      return { label: "Deleted", modifier: "deleted" };
  }
}

export function AttachmentPanel({
  attachments,
  onSelectFiles,
  onRemove,
  onRetry,
  disabled = false,
}: AttachmentPanelProps) {
  const [rejections, setRejections] = useState<string[]>([]);
  const inputRef = useRef<HTMLInputElement>(null);
  const errorsId = useId();

  const active = attachments.filter(isActive);
  const totalBytes = active.reduce((sum, record) => sum + record.size_bytes, 0);

  const handleChange = useCallback(
    (event: ChangeEvent<HTMLInputElement>) => {
      const files = Array.from(event.target.files ?? []);
      if (files.length === 0) return;

      const accepted: File[] = [];
      const rejected: string[] = [];
      const virtual = attachments.slice();
      for (const file of files) {
        const result = validateAttachmentPlan(virtual, {
          originalFilename: file.name,
          mimeType: file.type,
          sizeBytes: file.size,
        });
        if (result.ok) {
          virtual.push(planPlaceholder(file, accepted.length));
          accepted.push(file);
        } else {
          rejected.push(`${file.name}: ${result.message}`);
        }
      }

      setRejections(rejected);
      if (accepted.length > 0) {
        onSelectFiles(accepted);
      }
      // Allow re-selecting the same file after a rejection or removal.
      if (inputRef.current) {
        inputRef.current.value = "";
      }
    },
    [attachments, onSelectFiles],
  );

  return (
    <section className="attachment-panel" aria-label="Attachments">
      <h2>Attachments</h2>
      <p className="attachment-panel-limits" data-testid="attachment-limits">
        {active.length} / {ATTACHMENT_MAX_COUNT_PER_DRAFT} files ·{" "}
        {formatByteSize(totalBytes)} /{" "}
        {formatByteSize(ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT)} total
      </p>
      <input
        ref={inputRef}
        type="file"
        multiple
        accept={ACCEPTED_EXTENSIONS}
        aria-label="Add attachment"
        aria-describedby={rejections.length > 0 ? errorsId : undefined}
        disabled={disabled}
        onChange={handleChange}
      />
      {rejections.length > 0 && (
        <ul
          id={errorsId}
          role="alert"
          className="attachment-panel-errors"
          data-testid="attachment-errors"
        >
          {rejections.map((message, index) => (
            <li key={`${index}-${message}`}>{message}</li>
          ))}
        </ul>
      )}
      {active.length === 0 ? (
        <p className="attachment-panel-empty">No attachments.</p>
      ) : (
        <ul className="attachment-panel-list">
          {active.map((record) => {
            const chip = statusChip(record);
            return (
              <li
                key={record.id}
                className="attachment-panel-row"
                data-testid="attachment-row"
              >
                <span aria-hidden="true" className="attachment-panel-icon">
                  📄
                </span>
                <span className="attachment-panel-filename">
                  {record.safe_filename}
                </span>
                <span className="attachment-panel-meta">
                  {record.mime_type} · {formatByteSize(record.size_bytes)}
                </span>
                <span
                  className={`attachment-panel-status attachment-panel-status-${chip.modifier}`}
                >
                  {chip.label}
                </span>
                {record.status === "failed" && (
                  <button
                    type="button"
                    aria-label={`Retry upload of ${record.safe_filename}`}
                    disabled={disabled}
                    onClick={() => onRetry(record.id)}
                  >
                    Retry
                  </button>
                )}
                <button
                  type="button"
                  aria-label={`Remove attachment ${record.safe_filename}`}
                  disabled={disabled}
                  onClick={() => onRemove(record.id)}
                >
                  Remove
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
