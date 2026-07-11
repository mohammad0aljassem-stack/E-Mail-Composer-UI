/**
 * Read-only preview of the render-package attachment manifest, shown next
 * to the sandboxed HTML preview. Renders filenames as plain text only —
 * never HTML, never file contents.
 */

import type { AttachmentManifestItem } from "@/lib/phase2/contracts";
import { formatByteSize } from "@/lib/attachments/format";

export interface AttachmentManifestPreviewProps {
  items: AttachmentManifestItem[];
}

export function AttachmentManifestPreview({
  items,
}: AttachmentManifestPreviewProps) {
  return (
    <section
      className="attachment-manifest-preview"
      aria-label="Attachment manifest"
    >
      <h3>Attachments ({items.length})</h3>
      {items.length === 0 ? (
        <p className="attachment-manifest-empty">No verified attachments.</p>
      ) : (
        <ul className="attachment-manifest-list">
          {items.map((item) => (
            <li key={item.attachmentId} data-testid="manifest-item">
              <span className="attachment-manifest-filename">
                {item.filename}
              </span>{" "}
              <span className="attachment-manifest-meta">
                ({item.contentType}, {formatByteSize(item.sizeBytes)})
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
