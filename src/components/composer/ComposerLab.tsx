"use client";

import { useCallback, useRef, useState } from "react";
import type { Editor } from "@tiptap/react";
import {
  createEmptyDraftDocument,
  validateDraftDocument,
  type DraftDocument,
} from "@/lib/composer/canonical";
import { createSampleDraftDocument } from "@/lib/composer/samples";
import { ComposerEditor } from "./ComposerEditor";
import { ComposerJsonPanel } from "./ComposerJsonPanel";
import { ComposerPreview } from "./ComposerPreview";

/**
 * Versioned localStorage key. Only canonical JSON is ever stored — never
 * generated HTML. localStorage here is a development demonstration, not
 * production persistence.
 */
export const COMPOSER_LAB_STORAGE_KEY = "email-composer.composer-lab.draft.v1";

export function ComposerLab() {
  const enabled = process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED === "true";

  const editorRef = useRef<Editor | null>(null);
  const [document, setDocument] = useState<DraftDocument>(() =>
    createEmptyDraftDocument(),
  );
  const [previewHtml, setPreviewHtml] = useState<string | null>(null);
  const [previewText, setPreviewText] = useState<string | null>(null);
  const [status, setStatus] = useState<string>("");

  const replaceDocument = useCallback((next: DraftDocument) => {
    editorRef.current?.commands.setContent(next);
    setDocument(next);
  }, []);

  const handleSave = useCallback(() => {
    try {
      window.localStorage.setItem(
        COMPOSER_LAB_STORAGE_KEY,
        JSON.stringify(document),
      );
      setStatus("Draft JSON saved locally.");
    } catch {
      setStatus("Saving to localStorage failed.");
    }
  }, [document]);

  const handleLoad = useCallback(() => {
    let raw: string | null = null;
    try {
      raw = window.localStorage.getItem(COMPOSER_LAB_STORAGE_KEY);
    } catch {
      setStatus("Reading from localStorage failed.");
      return;
    }
    if (raw === null) {
      setStatus("No saved draft found.");
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      setStatus("The saved draft is not valid JSON.");
      return;
    }
    const result = validateDraftDocument(parsed);
    if (!result.ok) {
      setStatus("The saved draft is not a valid canonical document.");
      return;
    }
    replaceDocument(result.document);
    setStatus("Saved draft loaded.");
  }, [replaceDocument]);

  const handleReset = useCallback(() => {
    replaceDocument(createEmptyDraftDocument());
    setPreviewHtml(null);
    setPreviewText(null);
    setStatus("Editor reset to an empty draft.");
  }, [replaceDocument]);

  const handleSample = useCallback(() => {
    replaceDocument(createSampleDraftDocument());
    setStatus("Sample draft (Arabic and German) loaded.");
  }, [replaceDocument]);

  const handleGeneratePreview = useCallback(async () => {
    setStatus("Generating preview…");
    try {
      const response = await fetch("/api/composer/render", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ document }),
      });
      if (!response.ok) {
        setStatus(`Preview failed (HTTP ${response.status}).`);
        return;
      }
      const rendered = (await response.json()) as {
        html: string;
        text: string;
      };
      setPreviewHtml(rendered.html);
      setPreviewText(rendered.text);
      setStatus("Preview generated.");
    } catch {
      setStatus("Preview request failed.");
    }
  }, [document]);

  if (!enabled) {
    return (
      <main className="composer-lab">
        <h1>Composer laboratory</h1>
        <p>
          The composer v1 feature is disabled. Set
          <code> NEXT_PUBLIC_COMPOSER_V1_ENABLED=true </code>
          (see <code>.env.example</code>) to enable this page.
        </p>
      </main>
    );
  }

  return (
    <main className="composer-lab">
      <h1>Composer laboratory</h1>
      <p className="composer-lab-notice" role="note">
        Development demonstration only: drafts are kept in your browser&apos;s
        localStorage as canonical JSON. This is not production persistence.
      </p>

      <div className="composer-lab-actions">
        <button type="button" onClick={handleSave}>
          Save JSON locally
        </button>
        <button type="button" onClick={handleLoad}>
          Load saved JSON
        </button>
        <button type="button" onClick={handleReset}>
          Reset
        </button>
        <button type="button" onClick={handleSample}>
          Load Arabic/German sample
        </button>
        <button type="button" onClick={handleGeneratePreview}>
          Generate preview
        </button>
      </div>

      <p className="composer-lab-status" role="status" aria-live="polite">
        {status}
      </p>

      <div className="composer-lab-grid">
        <ComposerEditor
          onDocumentChange={setDocument}
          onEditorReady={(editor) => {
            editorRef.current = editor;
          }}
        />
        <ComposerJsonPanel document={document} />
        <ComposerPreview html={previewHtml} text={previewText} />
      </div>
    </main>
  );
}
