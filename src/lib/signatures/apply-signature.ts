/**
 * Personal signatures.
 *
 * Applying a signature appends, to the END of a draft document:
 *   1. one empty separator paragraph,
 *   2. a marker paragraph containing the text "-- " (RFC 3676 style),
 *   3. the signature's own blocks.
 *
 * Application is deterministic and idempotent-by-detection: when the exact
 * signature block sequence (marker + blocks) is already the tail of the
 * document, the document is returned unchanged (same reference), so
 * repeated application never duplicates. Inputs are never mutated and the
 * result always passes Phase 1 validation.
 */

import {
  normalizeDraftDocument,
  type BlockNode,
  type DraftDocument,
  type ParagraphNode,
} from "@/lib/composer/canonical";
import type { SignatureRecord } from "@/lib/phase2/contracts";

/** RFC 3676 signature separator text (note the trailing space). */
export const SIGNATURE_MARKER_TEXT = "-- ";

function markerParagraph(): ParagraphNode {
  return {
    type: "paragraph",
    content: [{ type: "text", text: SIGNATURE_MARKER_TEXT }],
  };
}

/**
 * The block sequence a signature contributes (marker paragraph followed by
 * the normalized signature body blocks). Throws DraftValidationError when
 * the signature body is not a valid Phase 1 document.
 */
export function signatureTailBlocks(signature: SignatureRecord): BlockNode[] {
  const body = normalizeDraftDocument(signature.body_json);
  return [markerParagraph(), ...body.content];
}

function endsWithBlocks(
  document: DraftDocument,
  tail: readonly BlockNode[],
): boolean {
  const start = document.content.length - tail.length;
  if (start < 0) {
    return false;
  }
  return JSON.stringify(document.content.slice(start)) === JSON.stringify(tail);
}

/**
 * True when this exact signature block sequence is already the tail of the
 * document. Comparison happens on normalized forms, so formatting-neutral
 * differences (e.g. adjacent text nodes) do not defeat detection.
 */
export function containsSignatureBlock(
  document: DraftDocument,
  signature: SignatureRecord,
): boolean {
  const tail = signatureTailBlocks(signature);
  return endsWithBlocks(normalizeDraftDocument(document), tail);
}

/**
 * Appends the signature to the end of the document (separator paragraph,
 * "-- " marker paragraph, signature blocks). Returns the input document
 * unchanged when the signature is already applied. Never mutates inputs;
 * throws DraftValidationError when either document is invalid.
 */
export function applySignature(
  document: DraftDocument,
  signature: SignatureRecord,
): DraftDocument {
  const tail = signatureTailBlocks(signature);
  const base = normalizeDraftDocument(document);
  if (endsWithBlocks(base, tail)) {
    return document;
  }
  return normalizeDraftDocument({
    type: "doc",
    content: [...base.content, { type: "paragraph" }, ...tail],
  });
}
