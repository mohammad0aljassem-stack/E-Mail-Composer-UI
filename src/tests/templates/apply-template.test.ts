// @vitest-environment node

import { describe, expect, it } from "vitest";
import { validateDraftDocument } from "@/lib/composer/canonical";
import type {
  TemplateVariableSpec,
  TemplateVersionRecord,
} from "@/lib/phase2/contracts";
import { applyTemplate } from "@/lib/templates/apply-template";
import { deepFreeze } from "../helpers";

function makeVersion(overrides: {
  subject_template?: string;
  body_template_json: unknown;
  variable_schema?: TemplateVariableSpec[];
}): TemplateVersionRecord {
  return {
    id: "tv-1",
    workspace_id: "ws-1",
    template_id: "t-1",
    version_no: 1,
    subject_template: overrides.subject_template ?? "Subject",
    body_template_json: overrides.body_template_json,
    variable_schema: overrides.variable_schema ?? [],
    created_by: "u-1",
    created_at: "2026-07-11T00:00:00Z",
  };
}

function variableNode(
  key: string,
  label = `Label ${key}`,
  required = true,
): Record<string, unknown> {
  return { type: "variable", attrs: { key, label, required } };
}

const greetingVersion = makeVersion({
  subject_template: "Hello {{name}}",
  body_template_json: {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: [
          { type: "text", text: "Dear " },
          variableNode("name", "Name"),
          { type: "text", text: "," },
        ],
      },
      {
        type: "paragraph",
        content: [variableNode("ps", "Postscript", false)],
      },
    ],
  },
  variable_schema: [
    { key: "name", label: "Name", required: true },
    { key: "ps", label: "Postscript", required: false },
  ],
});

describe("applyTemplate", () => {
  it("blocks on missing required variables with a structured list", () => {
    const result = applyTemplate({ version: greetingVersion, values: {} });
    expect(result).toEqual({
      ok: false,
      reason: "missing_variables",
      errors: [],
      missingVariables: ["name"],
    });
  });

  it("treats empty and whitespace-only required values as missing", () => {
    for (const value of ["", "   ", "\t\n"]) {
      const result = applyTemplate({
        version: greetingVersion,
        values: { name: value },
      });
      expect(result.ok).toBe(false);
      if (!result.ok && result.reason === "missing_variables") {
        expect(result.missingVariables).toEqual(["name"]);
      }
    }
  });

  it("never partially applies: no document or subject on failure", () => {
    const result = applyTemplate({ version: greetingVersion, values: {} });
    expect(result.ok).toBe(false);
    expect("document" in result).toBe(false);
    expect("subject" in result).toBe(false);
  });

  it("requires schema-declared required variables even when unused in the body", () => {
    const version = makeVersion({
      body_template_json: { type: "doc", content: [{ type: "paragraph" }] },
      variable_schema: [{ key: "code", label: "Code", required: true }],
    });
    const result = applyTemplate({ version, values: {} });
    expect(result).toEqual({
      ok: false,
      reason: "missing_variables",
      errors: [],
      missingVariables: ["code"],
    });
  });

  it("inserts values as plain text nodes and removes all variable nodes", () => {
    const result = applyTemplate({
      version: greetingVersion,
      values: { name: "Ada Lovelace", ps: "See you soon" },
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      const json = JSON.stringify(result.document);
      expect(json).toContain("Dear Ada Lovelace,");
      expect(json).toContain("See you soon");
      expect(json).not.toContain('"variable"');
      expect(result.subject).toBe("Hello Ada Lovelace");
      expect(validateDraftDocument(result.document).ok).toBe(true);
    }
  });

  it("removes an empty optional variable cleanly, keeping the paragraph valid", () => {
    const result = applyTemplate({
      version: greetingVersion,
      values: { name: "Ada" },
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.document.content[1]).toEqual({ type: "paragraph" });
      expect(validateDraftDocument(result.document).ok).toBe(true);
    }
  });

  it("keeps hostile values inert as literal text (no node or HTML injection)", () => {
    const hostile = "<script>alert(1)</script>";
    const result = applyTemplate({
      version: greetingVersion,
      values: { name: hostile, ps: "{{other}}" },
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(validateDraftDocument(result.document).ok).toBe(true);
      const json = JSON.stringify(result.document);
      // The value survives verbatim as text node content...
      expect(json).toContain(JSON.stringify(hostile).slice(1, -1));
      // ...but never becomes a node type.
      expect(json).not.toContain('"type":"script"');
      expect(json).not.toContain('"type":"variable"');
      // Template syntax inside values is not re-expanded.
      expect(json).toContain("{{other}}");
      const paragraph = result.document.content[1];
      expect(paragraph).toEqual({
        type: "paragraph",
        content: [{ type: "text", text: "{{other}}" }],
      });
    }
  });

  it("preserves Arabic, German, and mixed-direction values byte-exact", () => {
    const version = makeVersion({
      subject_template: "{{arabic}} / {{german}} / {{mixed}}",
      body_template_json: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              variableNode("arabic", "Arabic"),
              { type: "text", text: " | " },
              variableNode("german", "German"),
              { type: "text", text: " | " },
              variableNode("mixed", "Mixed"),
            ],
          },
        ],
      },
    });
    const values = {
      arabic: "شكراً جزيلاً",
      german: "Größenprüfung",
      mixed: "Größe مع شكراً 123",
    };
    const result = applyTemplate({ version, values });
    expect(result.ok).toBe(true);
    if (result.ok) {
      const paragraph = result.document.content[0];
      expect(paragraph).toEqual({
        type: "paragraph",
        content: [
          {
            type: "text",
            text: "شكراً جزيلاً | Größenprüfung | Größe مع شكراً 123",
          },
        ],
      });
      expect(result.subject).toBe(
        "شكراً جزيلاً / Größenprüfung / Größe مع شكراً 123",
      );
    }
  });

  it("is deterministic: two runs produce byte-identical JSON", () => {
    const values = { name: "Ada", ps: "PS" };
    const first = applyTemplate({ version: greetingVersion, values });
    const second = applyTemplate({ version: greetingVersion, values });
    expect(JSON.stringify(first)).toBe(JSON.stringify(second));
  });

  it("does not mutate its inputs", () => {
    const version = deepFreeze(
      makeVersion({
        subject_template: "Hello {{name}}",
        body_template_json: {
          type: "doc",
          content: [
            { type: "paragraph", content: [variableNode("name", "Name")] },
          ],
        },
        variable_schema: [{ key: "name", label: "Name", required: true }],
      }),
    );
    const values = deepFreeze({ name: "Ada" });
    const result = applyTemplate({ version, values });
    expect(result.ok).toBe(true);
  });

  it("rejects invalid template bodies and subjects as invalid_template", () => {
    const badBody = applyTemplate({
      version: makeVersion({
        body_template_json: { type: "doc", content: [{ type: "image" }] },
      }),
      values: {},
    });
    expect(badBody.ok).toBe(false);
    if (!badBody.ok) {
      expect(badBody.reason).toBe("invalid_template");
    }

    const badSubject = applyTemplate({
      version: makeVersion({
        subject_template: "Broken {{",
        body_template_json: { type: "doc", content: [{ type: "paragraph" }] },
      }),
      values: {},
    });
    expect(badSubject.ok).toBe(false);
    if (!badSubject.ok) {
      expect(badSubject.reason).toBe("invalid_template");
    }
  });

  it("resolves variables inside lists and blockquotes", () => {
    const version = makeVersion({
      body_template_json: {
        type: "doc",
        content: [
          {
            type: "orderedList",
            content: [
              {
                type: "listItem",
                content: [
                  {
                    type: "paragraph",
                    content: [variableNode("item", "Item")],
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
                content: [variableNode("quote", "Quote")],
              },
            ],
          },
        ],
      },
    });
    const result = applyTemplate({
      version,
      values: { item: "Erster Punkt", quote: "اقتباس" },
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      const json = JSON.stringify(result.document);
      expect(json).toContain("Erster Punkt");
      expect(json).toContain("اقتباس");
      expect(json).not.toContain('"variable"');
      expect(validateDraftDocument(result.document).ok).toBe(true);
    }
  });
});
