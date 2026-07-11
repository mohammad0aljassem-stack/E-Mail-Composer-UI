// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  collectVariables,
  declaredVariables,
  resolveTemplateVariables,
  validateTemplateDocument,
  type TemplateDocument,
} from "@/lib/templates/template-document";
import { deepFreeze } from "../helpers";

function variableNode(
  key: string,
  label = `Label for ${key}`,
  required = true,
): Record<string, unknown> {
  return { type: "variable", attrs: { key, label, required } };
}

function docWith(...content: unknown[]): Record<string, unknown> {
  return { type: "doc", content };
}

const validTemplateDoc = docWith(
  {
    type: "paragraph",
    content: [
      { type: "text", text: "Hello " },
      variableNode("first_name", "First name"),
      { type: "text", text: "," },
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
            content: [variableNode("topic", "Topic", false)],
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
          { type: "text", text: "Bold ", marks: [{ type: "bold" }] },
          variableNode("first_name", "First name"),
        ],
      },
    ],
  },
);

describe("validateTemplateDocument", () => {
  it("accepts a valid template document with variable nodes", () => {
    const result = validateTemplateDocument(deepFreeze(validTemplateDoc));
    expect(result.ok).toBe(true);
  });

  it("still accepts plain Phase 1 documents without variables", () => {
    const result = validateTemplateDocument(
      docWith({ type: "paragraph", content: [{ type: "text", text: "hi" }] }),
    );
    expect(result.ok).toBe(true);
  });

  it("rejects variable nodes with a bad key", () => {
    for (const key of [
      "FirstName",
      "1name",
      "first-name",
      "",
      "a".repeat(65),
    ]) {
      const result = validateTemplateDocument(
        docWith({ type: "paragraph", content: [variableNode(key)] }),
      );
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.errors.join(" ")).toContain("variable key must match");
      }
    }
  });

  it("rejects a variable node used as a block", () => {
    const result = validateTemplateDocument(docWith(variableNode("name")));
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.join(" ")).toContain(
        'unsupported node type "variable"',
      );
    }
  });

  it("rejects a variable node nested directly in a listItem", () => {
    const result = validateTemplateDocument(
      docWith({
        type: "bulletList",
        content: [
          {
            type: "listItem",
            content: [{ type: "paragraph" }, variableNode("name")],
          },
        ],
      }),
    );
    expect(result.ok).toBe(false);
  });

  it("rejects marks on variable nodes", () => {
    const node = {
      ...variableNode("name"),
      marks: [{ type: "bold" }],
    };
    const result = validateTemplateDocument(
      docWith({ type: "paragraph", content: [node] }),
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.join(" ")).toContain(
        "variable node must not have marks",
      );
    }
  });

  it("rejects unknown keys on the variable node and unknown attrs", () => {
    const extraKey = { ...variableNode("name"), extra: 1 };
    const resultA = validateTemplateDocument(
      docWith({ type: "paragraph", content: [extraKey] }),
    );
    expect(resultA.ok).toBe(false);
    if (!resultA.ok) {
      expect(resultA.errors.join(" ")).toContain('unsupported key "extra"');
    }

    const resultB = validateTemplateDocument(
      docWith({
        type: "paragraph",
        content: [
          {
            type: "variable",
            attrs: { key: "name", label: "Name", required: true, default: "x" },
          },
        ],
      }),
    );
    expect(resultB.ok).toBe(false);
    if (!resultB.ok) {
      expect(resultB.errors.join(" ")).toContain('unsupported key "default"');
    }
  });

  it("rejects bad labels and non-boolean required flags", () => {
    const badLabel = validateTemplateDocument(
      docWith({
        type: "paragraph",
        content: [
          { type: "variable", attrs: { key: "a", label: "", required: true } },
        ],
      }),
    );
    expect(badLabel.ok).toBe(false);

    const longLabel = validateTemplateDocument(
      docWith({
        type: "paragraph",
        content: [
          {
            type: "variable",
            attrs: { key: "a", label: "x".repeat(201), required: true },
          },
        ],
      }),
    );
    expect(longLabel.ok).toBe(false);

    const badRequired = validateTemplateDocument(
      docWith({
        type: "paragraph",
        content: [
          {
            type: "variable",
            attrs: { key: "a", label: "A", required: "yes" },
          },
        ],
      }),
    );
    expect(badRequired.ok).toBe(false);
  });

  it("keeps rejecting everything Phase 1 rejects", () => {
    expect(validateTemplateDocument(null).ok).toBe(false);
    expect(validateTemplateDocument(docWith({ type: "image" })).ok).toBe(false);
    expect(
      validateTemplateDocument(
        docWith({
          type: "paragraph",
          content: [
            { type: "text", text: "x", marks: [{ type: "underline" }] },
          ],
        }),
      ).ok,
    ).toBe(false);
  });
});

describe("collectVariables", () => {
  const doc = validTemplateDoc as unknown as TemplateDocument;

  it("returns variables in document order, deduplicated by key", () => {
    const result = collectVariables(doc);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.variables).toEqual([
        { key: "first_name", label: "First name", required: true },
        { key: "topic", label: "Topic", required: false },
      ]);
    }
  });

  it("puts subject placeholders first", () => {
    const result = collectVariables(doc, "About {{topic}} for {{company}}");
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.variables.map((spec) => spec.key)).toEqual([
        "topic",
        "company",
        "first_name",
      ]);
      // Subject occurrence makes topic required; body node supplies label.
      expect(result.variables[0]).toEqual({
        key: "topic",
        label: "Topic",
        required: true,
      });
      // Subject-only variables fall back to the key as label.
      expect(result.variables[1]).toEqual({
        key: "company",
        label: "company",
        required: true,
      });
    }
  });

  it("errors on conflicting labels for the same key", () => {
    const conflicting = docWith(
      { type: "paragraph", content: [variableNode("name", "Name")] },
      { type: "paragraph", content: [variableNode("name", "Full name")] },
    ) as unknown as TemplateDocument;
    const result = collectVariables(conflicting);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.join(" ")).toContain(
        'conflicting labels for variable "name"',
      );
    }
  });

  it("propagates subject parse errors", () => {
    const result = collectVariables(doc, "Broken {{name");
    expect(result.ok).toBe(false);
  });
});

describe("declaredVariables", () => {
  it("accepts a valid schema", () => {
    const result = declaredVariables([
      { key: "name", label: "Name", required: true },
    ]);
    expect(result.ok).toBe(true);
  });

  it("rejects non-arrays, bad entries, and duplicates", () => {
    expect(declaredVariables("nope").ok).toBe(false);
    expect(
      declaredVariables([{ key: "BAD", label: "x", required: true }]).ok,
    ).toBe(false);
    expect(
      declaredVariables([{ key: "a", label: "", required: true }]).ok,
    ).toBe(false);
    expect(
      declaredVariables([{ key: "a", label: "A", required: true, extra: 1 }])
        .ok,
    ).toBe(false);
    expect(
      declaredVariables([
        { key: "a", label: "A", required: true },
        { key: "a", label: "A", required: true },
      ]).ok,
    ).toBe(false);
  });
});

describe("resolveTemplateVariables", () => {
  it("unions required flags across schema and collected nodes", () => {
    const result = resolveTemplateVariables({
      subject_template: "Hi",
      body_template_json: docWith({
        type: "paragraph",
        content: [variableNode("topic", "Topic", false)],
      }),
      variable_schema: [
        { key: "topic", label: "Topic", required: true },
        { key: "extra_var", label: "Extra", required: true },
      ],
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.variables).toEqual([
        { key: "topic", label: "Topic", required: true },
        { key: "extra_var", label: "Extra", required: true },
      ]);
    }
  });

  it("lets the schema label win for subject-only variables", () => {
    const result = resolveTemplateVariables({
      subject_template: "About {{topic}}",
      body_template_json: docWith({ type: "paragraph" }),
      variable_schema: [{ key: "topic", label: "The topic", required: false }],
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.variables).toEqual([
        { key: "topic", label: "The topic", required: true },
      ]);
    }
  });

  it("errors when schema and body labels conflict", () => {
    const result = resolveTemplateVariables({
      subject_template: "Hi",
      body_template_json: docWith({
        type: "paragraph",
        content: [variableNode("topic", "Topic")],
      }),
      variable_schema: [{ key: "topic", label: "Different", required: false }],
    });
    expect(result.ok).toBe(false);
  });
});
