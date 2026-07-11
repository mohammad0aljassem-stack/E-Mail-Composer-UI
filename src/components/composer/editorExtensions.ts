/**
 * Tiptap extension set for the canonical composer.
 *
 * The editor schema is the first line of defense: only nodes and marks of
 * the canonical document format exist, so pasted HTML is reduced to the
 * allowed subset by ProseMirror's schema-driven parsing — raw HTML can never
 * enter the document.
 */

import Link from "@tiptap/extension-link";
import StarterKit from "@tiptap/starter-kit";
import type { AnyExtension } from "@tiptap/core";
import { isSafeHref } from "@/lib/composer/links";

/**
 * Link mark reduced to a single `href` attribute (no target/rel/class in the
 * canonical document — presentation is decided at render time) and guarded
 * by the central URL policy for typed, pasted and autolinked URLs.
 */
export const SafeLink = Link.extend({
  addAttributes() {
    return {
      href: {
        default: null,
      },
    };
  },
}).configure({
  openOnClick: false,
  autolink: true,
  linkOnPaste: true,
  isAllowedUri: (url) => isSafeHref(url),
});

export const composerExtensions: AnyExtension[] = [
  StarterKit.configure({
    // Not part of the canonical format v1:
    heading: false,
    codeBlock: false,
    code: false,
    strike: false,
    horizontalRule: false,
    // Mixed Arabic/German input stays readable per paragraph; the editor as
    // a whole is not forced to RTL.
    paragraph: {
      HTMLAttributes: { dir: "auto" },
    },
  }),
  SafeLink,
];
