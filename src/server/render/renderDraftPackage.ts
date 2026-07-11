/**
 * Render package: the existing renderDraft output plus the verified
 * attachment manifest for the future Phase 3 transport worker.
 *
 * Security boundary: the HTML returned by renderDraft is already sanitized
 * and final — this module returns it byte-for-byte unchanged and never
 * splices attachment data (or any other string) into it. The preview UI
 * renders the attachment list itself from the manifest. Only the plain-text
 * alternative gains an attachment section, because plain text cannot
 * execute; it lists exclusively manifest entries, so the text never claims
 * a file is attached unless it is in the manifest. File contents are never
 * downloaded or read here.
 */

import type {
  AttachmentManifestItem,
  AttachmentRecord,
} from "@/lib/phase2/contracts";
import { buildAttachmentManifest } from "@/lib/attachments/manifest";
import { renderDraft } from "./renderDraft";

export interface RenderedDraftPackage {
  html: string;
  text: string;
  attachments: AttachmentManifestItem[];
}

function formatManifestLine(item: AttachmentManifestItem): string {
  return `- ${item.filename} (${item.contentType}, ${item.sizeBytes} bytes)`;
}

export async function renderDraftPackage(
  document: unknown,
  attachments: AttachmentRecord[],
): Promise<RenderedDraftPackage> {
  const { html, text } = await renderDraft(document);
  const manifest = buildAttachmentManifest(attachments);
  if (manifest.length === 0) {
    return { html, text, attachments: manifest };
  }
  const section = ["Anlagen:", ...manifest.map(formatManifestLine)].join("\n");
  return {
    html,
    text: `${text.replace(/\n+$/, "")}\n\n${section}\n`,
    attachments: manifest,
  };
}
