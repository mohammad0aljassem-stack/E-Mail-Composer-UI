"use client";

export interface ComposerPreviewProps {
  html: string | null;
  text: string | null;
}

/**
 * Shows the derived outputs. The HTML preview is isolated in an iframe with
 * an empty sandbox attribute: no scripts, no forms, no popups, no top-level
 * navigation.
 */
export function ComposerPreview({ html, text }: ComposerPreviewProps) {
  return (
    <section className="composer-panel" aria-label="E-mail preview">
      <h2>HTML preview</h2>
      {html !== null ? (
        <iframe
          className="composer-preview-frame"
          title="E-mail HTML preview"
          sandbox=""
          srcDoc={html}
        />
      ) : (
        <p className="composer-preview-empty">No preview generated yet.</p>
      )}
      <h2>Plain-text preview</h2>
      {text !== null ? (
        <pre
          className="composer-text"
          dir="auto"
          data-testid="plain-text-preview"
        >
          {text}
        </pre>
      ) : (
        <p className="composer-preview-empty">No preview generated yet.</p>
      )}
    </section>
  );
}
