// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  parseSubjectTemplate,
  renderSubject,
} from "@/lib/templates/subject-template";

describe("parseSubjectTemplate", () => {
  it("passes plain subjects through as a single text token", () => {
    const result = parseSubjectTemplate("Quarterly report");
    expect(result).toEqual({
      ok: true,
      tokens: [{ kind: "text", value: "Quarterly report" }],
    });
  });

  it("parses an empty subject to zero tokens", () => {
    expect(parseSubjectTemplate("")).toEqual({ ok: true, tokens: [] });
  });

  it("parses a single placeholder", () => {
    const result = parseSubjectTemplate("Hello {{first_name}}!");
    expect(result).toEqual({
      ok: true,
      tokens: [
        { kind: "text", value: "Hello " },
        { kind: "variable", key: "first_name" },
        { kind: "text", value: "!" },
      ],
    });
  });

  it("parses multiple and adjacent placeholders", () => {
    const result = parseSubjectTemplate("{{a}}{{b}} und {{c_1}}");
    expect(result).toEqual({
      ok: true,
      tokens: [
        { kind: "variable", key: "a" },
        { kind: "variable", key: "b" },
        { kind: "text", value: " und " },
        { kind: "variable", key: "c_1" },
      ],
    });
  });

  it("treats single braces as ordinary text", () => {
    const result = parseSubjectTemplate("a {b} c }} d");
    expect(result).toEqual({
      ok: true,
      tokens: [{ kind: "text", value: "a {b} c }} d" }],
    });
  });

  it("errors on an unclosed placeholder", () => {
    const result = parseSubjectTemplate("Hello {{first_name");
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors).toEqual([
        "subject[6]: unclosed variable placeholder",
      ]);
    }
  });

  it("errors on malformed keys", () => {
    for (const subject of [
      "{{First}}",
      "{{ name }}",
      "{{1a}}",
      "{{}}",
      "{{a.b}}",
      `{{${"a".repeat(65)}}}`,
    ]) {
      const result = parseSubjectTemplate(subject);
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.errors[0]).toContain("variable key must match");
      }
    }
  });

  it("reports every malformed placeholder", () => {
    const result = parseSubjectTemplate("{{A}} and {{B}}");
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors).toHaveLength(2);
    }
  });
});

describe("renderSubject", () => {
  it("joins tokens deterministically", () => {
    const result = renderSubject("Hello {{name}}, re {{topic}}", {
      name: "Ada",
      topic: "Q3",
    });
    expect(result).toEqual({ ok: true, subject: "Hello Ada, re Q3" });
  });

  it("errors on a missing value instead of guessing", () => {
    const result = renderSubject("Hello {{name}}", {});
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.missingVariables).toEqual(["name"]);
    }
  });

  it("accepts an explicit empty string as a provided value", () => {
    expect(renderSubject("A{{gap}}B", { gap: "" })).toEqual({
      ok: true,
      subject: "AB",
    });
  });

  it("propagates parse errors", () => {
    const result = renderSubject("Broken {{", { x: "1" });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.missingVariables).toEqual([]);
      expect(result.errors[0]).toContain("unclosed");
    }
  });

  it("preserves German umlauts and Arabic values exactly", () => {
    const german = renderSubject("Prüfung: {{wert}}", {
      wert: "Größenprüfung äöüß",
    });
    expect(german).toEqual({
      ok: true,
      subject: "Prüfung: Größenprüfung äöüß",
    });

    const arabic = renderSubject("رسالة إلى {{name}}", {
      name: "شكراً جزيلاً",
    });
    expect(arabic).toEqual({
      ok: true,
      subject: "رسالة إلى شكراً جزيلاً",
    });
  });

  it("does not re-parse template syntax inside values", () => {
    const result = renderSubject("X {{a}} Y", { a: "{{b}}" });
    expect(result).toEqual({ ok: true, subject: "X {{b}} Y" });
  });
});
