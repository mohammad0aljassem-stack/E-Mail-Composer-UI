/**
 * Sample canonical documents for the composer laboratory.
 *
 * The sample deliberately mixes German (umlauts, ß) and Arabic (RTL) text,
 * lists, a blockquote, marks, a hard break and a safe link, so rendering and
 * direction handling can be inspected end to end.
 */

import type { DraftDocument } from "./canonical";

const SAMPLE: DraftDocument = {
  type: "doc",
  content: [
    {
      type: "paragraph",
      content: [{ type: "text", text: "Sehr geehrte Damen und Herren," }],
    },
    {
      type: "paragraph",
      content: [
        { type: "text", text: "Überprüfung der Größe, Straße und Grüße." },
      ],
    },
    {
      type: "paragraph",
      content: [
        {
          type: "text",
          text: "مرحباً، هذه رسالة تجريبية باللغة العربية للتحقق من اتجاه النص.",
        },
      ],
    },
    {
      type: "paragraph",
      content: [
        { type: "text", text: "Vielen Dank — " },
        { type: "text", text: "شكراً جزيلاً", marks: [{ type: "bold" }] },
        { type: "text", text: " — für Ihre Rückmeldung." },
      ],
    },
    {
      type: "bulletList",
      content: [
        {
          type: "listItem",
          content: [
            {
              type: "paragraph",
              content: [
                { type: "text", text: "Erster Punkt mit " },
                { type: "text", text: "Betonung", marks: [{ type: "italic" }] },
              ],
            },
          ],
        },
        {
          type: "listItem",
          content: [
            {
              type: "paragraph",
              content: [{ type: "text", text: "النقطة الثانية بالعربية" }],
            },
          ],
        },
      ],
    },
    {
      type: "orderedList",
      content: [
        {
          type: "listItem",
          content: [
            {
              type: "paragraph",
              content: [{ type: "text", text: "Erster Schritt" }],
            },
          ],
        },
        {
          type: "listItem",
          content: [
            {
              type: "paragraph",
              content: [{ type: "text", text: "Zweiter Schritt" }],
            },
          ],
        },
      ],
    },
    {
      type: "blockquote",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "Zitat: Qualität ist kein Zufall. — اقتباس للتجربة",
            },
          ],
        },
      ],
    },
    {
      type: "paragraph",
      content: [
        { type: "text", text: "Erste Zeile" },
        { type: "hardBreak" },
        { type: "text", text: "Zweite Zeile nach hartem Umbruch" },
      ],
    },
    {
      type: "paragraph",
      content: [
        { type: "text", text: "Mehr dazu: " },
        {
          type: "text",
          text: "Beispiel-Website",
          marks: [{ type: "link", attrs: { href: "https://example.com/" } }],
        },
      ],
    },
  ],
};

/** Returns a fresh copy so callers can never mutate the shared sample. */
export function createSampleDraftDocument(): DraftDocument {
  return structuredClone(SAMPLE);
}
