"use client";

import { useMemo, useState } from "react";
import type { TemplateVersionRecord } from "@/lib/phase2/contracts";
import { resolveTemplateVariables } from "@/lib/templates/template-document";

export interface TemplateVariableFormProps {
  version: TemplateVersionRecord;
  onApply: (values: Record<string, string>) => void;
}

function isBlank(value: string | undefined): boolean {
  return value === undefined || value.trim().length === 0;
}

/**
 * Collects values for a template version's variables. Inputs always start
 * empty — no value is ever guessed or prefilled. Apply stays disabled and a
 * visible alert lists the missing variables until every required variable
 * has a non-whitespace value.
 */
export function TemplateVariableForm({
  version,
  onApply,
}: TemplateVariableFormProps) {
  const resolved = useMemo(() => resolveTemplateVariables(version), [version]);
  const [values, setValues] = useState<Record<string, string>>({});

  if (!resolved.ok) {
    return (
      <div role="alert" className="composer-link-error">
        <p>This template version is invalid and cannot be applied.</p>
        <ul>
          {resolved.errors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
      </div>
    );
  }

  const variables = resolved.variables;
  const missing = variables.filter(
    (spec) => spec.required && isBlank(values[spec.key]),
  );

  return (
    <form
      className="composer-link-form"
      aria-label="Template variables"
      onSubmit={(event) => {
        event.preventDefault();
        if (missing.length === 0) {
          onApply(values);
        }
      }}
    >
      {variables.length === 0 ? (
        <p>This template has no variables.</p>
      ) : (
        variables.map((spec) => {
          const inputId = `template-variable-${version.id}-${spec.key}`;
          return (
            <p key={spec.key}>
              <label htmlFor={inputId}>
                {spec.label}
                {spec.required ? <span aria-hidden="true"> *</span> : null}
              </label>{" "}
              <input
                id={inputId}
                type="text"
                dir="auto"
                aria-label={spec.label}
                aria-required={spec.required}
                value={values[spec.key] ?? ""}
                onChange={(event) => {
                  const next = event.target.value;
                  setValues((previous) => ({ ...previous, [spec.key]: next }));
                }}
              />
            </p>
          );
        })
      )}
      {missing.length > 0 ? (
        <div role="alert" className="composer-link-error">
          <p>Missing required variables:</p>
          <ul>
            {missing.map((spec) => (
              <li key={spec.key}>{spec.label}</li>
            ))}
          </ul>
        </div>
      ) : null}
      <span className="composer-lab-actions">
        <button type="submit" disabled={missing.length > 0}>
          Apply template
        </button>
      </span>
    </form>
  );
}
