"use client";

import type { DraftDocument } from "@/lib/composer/canonical";

export function ComposerJsonPanel({ document }: { document: DraftDocument }) {
  return (
    <section className="composer-panel" aria-label="Canonical document JSON">
      <h2>Canonical JSON</h2>
      <pre className="composer-json" data-testid="canonical-json">
        {JSON.stringify(document, null, 2)}
      </pre>
    </section>
  );
}
