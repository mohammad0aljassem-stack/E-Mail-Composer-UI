// @vitest-environment node

import { describe, expect, it } from "vitest";
import { renderDraft } from "@/server/render/renderDraft";
import { sanitizeEmailHtml } from "@/server/render/sanitize";
import { validateDraftDocument } from "@/lib/composer/canonical";
import type { DraftDocument } from "@/lib/composer/canonical";

function docWithText(text: string): DraftDocument {
  return {
    type: "doc",
    content: [{ type: "paragraph", content: [{ type: "text", text }] }],
  };
}

describe("rendering escapes user text", () => {
  it("script tags do not survive as markup", async () => {
    const { html } = await renderDraft(
      docWithText("<script>alert(1)</script>"),
    );
    expect(html).not.toContain("<script");
    expect(html).toContain("&lt;script&gt;");
  });

  it("img/onerror payloads do not survive as markup", async () => {
    const { html } = await renderDraft(
      docWithText("<img src=x onerror=alert(1)>"),
    );
    expect(html).not.toContain("<img");
    // The payload may survive only as escaped, inert text — never inside a tag.
    expect(html).not.toMatch(/<[^>]*\sonerror\s*=/i);
    expect(html).toContain("&lt;img");
  });

  it("iframe payloads do not survive as markup", async () => {
    const { html } = await renderDraft(
      docWithText('<iframe src="https://evil.example"></iframe>'),
    );
    expect(html).not.toContain("<iframe");
  });

  it("inline event handlers do not survive as attributes", async () => {
    const { html } = await renderDraft(
      docWithText('<a href="https://x.example" onclick="alert(1)">x</a>'),
    );
    expect(html).not.toMatch(/<[^>]+onclick=/);
  });

  it("style injection does not survive as markup", async () => {
    const { html } = await renderDraft(
      docWithText("<style>body{display:none}</style>"),
    );
    expect(html).not.toContain("<style");
  });
});

describe("canonical validation blocks executable content", () => {
  it("javascript: links are rejected", () => {
    const result = validateDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "x",
              marks: [{ type: "link", attrs: { href: "javascript:alert(1)" } }],
            },
          ],
        },
      ],
    });
    expect(result.ok).toBe(false);
  });

  it("data: links are rejected", () => {
    const result = validateDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "x",
              marks: [
                {
                  type: "link",
                  attrs: { href: "data:text/html,<script>alert(1)</script>" },
                },
              ],
            },
          ],
        },
      ],
    });
    expect(result.ok).toBe(false);
  });

  it("iframe nodes are rejected", () => {
    expect(
      validateDraftDocument({
        type: "doc",
        content: [{ type: "iframe", attrs: { src: "https://evil.example" } }],
      }).ok,
    ).toBe(false);
  });

  it("raw HTML nodes are rejected", () => {
    expect(
      validateDraftDocument({
        type: "doc",
        content: [{ type: "rawHtml", html: "<script>alert(1)</script>" }],
      }).ok,
    ).toBe(false);
  });
});

describe("sanitizeEmailHtml output firewall", () => {
  it("removes script tags and contents", () => {
    const out = sanitizeEmailHtml("<p>ok<script>alert(1)</script></p>");
    expect(out).not.toContain("script");
    expect(out).toContain("ok");
  });

  it("removes iframes", () => {
    const out = sanitizeEmailHtml(
      '<p><iframe src="https://evil.example">fallback</iframe></p>',
    );
    expect(out).not.toContain("<iframe");
    expect(out).not.toContain("evil.example");
  });

  it("removes inline event handlers", () => {
    const out = sanitizeEmailHtml(
      '<p onclick="alert(1)" onmouseover="x">y</p>',
    );
    expect(out).not.toContain("onclick");
    expect(out).not.toContain("onmouseover");
  });

  it("removes javascript: and data: URLs", () => {
    expect(
      sanitizeEmailHtml('<a href="javascript:alert(1)">x</a>'),
    ).not.toContain("javascript:");
    expect(
      sanitizeEmailHtml('<a href="data:text/html,<script>x</script>">x</a>'),
    ).not.toContain("data:");
  });

  it("survives malformed nested HTML without crashing", () => {
    const out = sanitizeEmailHtml("<p><b>x<p>y<blockquote>z");
    expect(typeof out).toBe("string");
    expect(out).toContain("x");
  });

  it("keeps the allowed e-mail markup", () => {
    const input =
      '<p style="margin:0" dir="auto">Grüße <strong>fett</strong> <a href="https://example.com/">Link</a></p>';
    const out = sanitizeEmailHtml(input);
    expect(out).toContain("<strong>fett</strong>");
    expect(out).toContain('href="https://example.com/"');
    expect(out).toContain('dir="auto"');
  });
});
