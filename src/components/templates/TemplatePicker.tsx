"use client";

import type {
  TemplateRecord,
  TemplateVersionRecord,
} from "@/lib/phase2/contracts";

export interface TemplatePickerProps {
  templates: TemplateRecord[];
  /** All available versions; grouped by template_id for display. */
  versions: TemplateVersionRecord[];
  onSelectVersion: (version: TemplateVersionRecord) => void;
}

/**
 * Presentational template picker. Lists templates and their immutable
 * versions; selecting a version never modifies the template — applying it
 * produces a Draft, which is a separate document.
 */
export function TemplatePicker({
  templates,
  versions,
  onSelectVersion,
}: TemplatePickerProps) {
  return (
    <section aria-label="Templates" className="composer-panel">
      <h2>Templates</h2>
      <p className="composer-lab-notice">
        Applying a template creates content for your <strong>Draft</strong>. The{" "}
        <strong>Template</strong> itself is never changed; each version number
        below is immutable.
      </p>
      {templates.length === 0 ? (
        <p>No templates available.</p>
      ) : (
        <ul>
          {templates.map((template) => {
            const templateVersions = versions
              .filter((version) => version.template_id === template.id)
              .sort((a, b) => b.version_no - a.version_no);
            return (
              <li key={template.id}>
                <span>{template.name}</span>{" "}
                <span aria-hidden="true">[Template]</span>
                {template.description ? <p>{template.description}</p> : null}
                {templateVersions.length === 0 ? (
                  <p>No versions yet.</p>
                ) : (
                  <ul>
                    {templateVersions.map((version) => (
                      <li key={version.id}>
                        <span>Version {version.version_no} (immutable)</span>{" "}
                        <span className="composer-lab-actions">
                          <button
                            type="button"
                            aria-label={`Select version ${version.version_no} of template ${template.name}`}
                            onClick={() => onSelectVersion(version)}
                          >
                            Select
                          </button>
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
