"use client";

import { useEffect } from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import {
  createEmptyDraftDocument,
  normalizeDraftDocument,
  type DraftDocument,
} from "@/lib/composer/canonical";
import { composerExtensions } from "./editorExtensions";
import { ComposerToolbar } from "./ComposerToolbar";

export interface ComposerEditorProps {
  initialDocument?: DraftDocument;
  /** Receives the normalized canonical document after every change. */
  onDocumentChange?: (document: DraftDocument) => void;
  /** Test/integration hook to reach the Tiptap editor instance. */
  onEditorReady?: (editor: Editor) => void;
}

export function ComposerEditor({
  initialDocument,
  onDocumentChange,
  onEditorReady,
}: ComposerEditorProps) {
  const editor = useEditor({
    extensions: composerExtensions,
    content: initialDocument ?? createEmptyDraftDocument(),
    immediatelyRender: false,
    editorProps: {
      attributes: {
        class: "composer-editor-content",
        "aria-label": "E-mail body",
      },
    },
    onUpdate: ({ editor: currentEditor }) => {
      if (!onDocumentChange) {
        return;
      }
      try {
        onDocumentChange(normalizeDraftDocument(currentEditor.getJSON()));
      } catch {
        // The schema prevents unsupported content from entering the editor;
        // if normalization ever rejects a document anyway, it is not
        // propagated as canonical state.
      }
    },
  });

  useEffect(() => {
    if (editor && onEditorReady) {
      onEditorReady(editor);
    }
  }, [editor, onEditorReady]);

  if (!editor) {
    return <div className="composer-editor" aria-busy="true" />;
  }

  return (
    <div className="composer-editor">
      <ComposerToolbar editor={editor} />
      <EditorContent editor={editor} />
    </div>
  );
}
