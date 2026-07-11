/**
 * Server-only rendering of a canonical draft document into derived outputs:
 * e-mail-compatible HTML (React Email) and a plain-text alternative.
 *
 * The canonical JSON is validated before rendering; rendering never mutates
 * its input and its output is deterministic.
 */

import { createElement } from "react";
import { render } from "@react-email/render";
import {
  DraftValidationError,
  validateDraftDocument,
} from "@/lib/composer/canonical";
import { renderPlainText } from "@/lib/composer/plain-text";
import { DraftEmail } from "./DraftEmail";
import { sanitizeEmailHtml } from "./sanitize";

export interface RenderedDraft {
  html: string;
  text: string;
}

export async function renderDraft(input: unknown): Promise<RenderedDraft> {
  if (typeof window !== "undefined") {
    throw new Error("renderDraft must only run on the server");
  }
  const result = validateDraftDocument(input);
  if (!result.ok) {
    throw new DraftValidationError(result.errors);
  }
  const document = result.document;
  const rawHtml = await render(createElement(DraftEmail, { document }));
  return {
    html: sanitizeEmailHtml(rawHtml),
    text: renderPlainText(document),
  };
}
