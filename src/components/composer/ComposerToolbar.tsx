"use client";

import { useCallback, useEffect, useState } from "react";
import type { Editor } from "@tiptap/react";
import { normalizeHref } from "@/lib/composer/links";

interface ToolbarButtonProps {
  label: string;
  active?: boolean;
  disabled?: boolean;
  onClick: () => void;
  children: React.ReactNode;
}

function ToolbarButton({
  label,
  active,
  disabled,
  onClick,
  children,
}: ToolbarButtonProps) {
  return (
    <button
      type="button"
      className={`composer-toolbar-button${active ? " is-active" : ""}`}
      aria-label={label}
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

export function ComposerToolbar({ editor }: { editor: Editor }) {
  // Re-render the toolbar whenever the editor state changes so active and
  // disabled states stay in sync with the selection.
  const [, setVersion] = useState(0);
  useEffect(() => {
    const update = () => setVersion((value) => value + 1);
    editor.on("transaction", update);
    return () => {
      editor.off("transaction", update);
    };
  }, [editor]);

  const [linkFormOpen, setLinkFormOpen] = useState(false);
  const [linkValue, setLinkValue] = useState("");
  const [linkError, setLinkError] = useState<string | null>(null);

  const openLinkForm = useCallback(() => {
    const current = editor.getAttributes("link").href;
    setLinkValue(typeof current === "string" ? current : "");
    setLinkError(null);
    setLinkFormOpen(true);
  }, [editor]);

  const applyLink = useCallback(() => {
    const normalized = normalizeHref(linkValue);
    if (normalized === null) {
      setLinkError("Only http:, https: and mailto: links are allowed.");
      return;
    }
    editor
      .chain()
      .focus()
      .extendMarkRange("link")
      .setLink({ href: normalized })
      .run();
    setLinkFormOpen(false);
    setLinkError(null);
  }, [editor, linkValue]);

  return (
    <div className="composer-toolbar" role="toolbar" aria-label="Formatting">
      <ToolbarButton
        label="Bold"
        active={editor.isActive("bold")}
        disabled={!editor.can().chain().focus().toggleBold().run()}
        onClick={() => editor.chain().focus().toggleBold().run()}
      >
        B
      </ToolbarButton>
      <ToolbarButton
        label="Italic"
        active={editor.isActive("italic")}
        disabled={!editor.can().chain().focus().toggleItalic().run()}
        onClick={() => editor.chain().focus().toggleItalic().run()}
      >
        I
      </ToolbarButton>
      <ToolbarButton
        label="Bullet list"
        active={editor.isActive("bulletList")}
        onClick={() => editor.chain().focus().toggleBulletList().run()}
      >
        • List
      </ToolbarButton>
      <ToolbarButton
        label="Ordered list"
        active={editor.isActive("orderedList")}
        onClick={() => editor.chain().focus().toggleOrderedList().run()}
      >
        1. List
      </ToolbarButton>
      <ToolbarButton
        label="Blockquote"
        active={editor.isActive("blockquote")}
        onClick={() => editor.chain().focus().toggleBlockquote().run()}
      >
        ❝
      </ToolbarButton>
      <ToolbarButton label="Add or edit link" onClick={openLinkForm}>
        Link
      </ToolbarButton>
      <ToolbarButton
        label="Remove link"
        disabled={!editor.isActive("link")}
        onClick={() => editor.chain().focus().unsetLink().run()}
      >
        Unlink
      </ToolbarButton>
      <ToolbarButton
        label="Undo"
        disabled={!editor.can().undo()}
        onClick={() => editor.chain().focus().undo().run()}
      >
        ↺
      </ToolbarButton>
      <ToolbarButton
        label="Redo"
        disabled={!editor.can().redo()}
        onClick={() => editor.chain().focus().redo().run()}
      >
        ↻
      </ToolbarButton>

      {linkFormOpen ? (
        <form
          className="composer-link-form"
          onSubmit={(event) => {
            event.preventDefault();
            applyLink();
          }}
        >
          <input
            type="text"
            aria-label="Link URL"
            placeholder="https://example.com"
            value={linkValue}
            onChange={(event) => setLinkValue(event.target.value)}
          />
          <button type="submit" aria-label="Apply link">
            Apply
          </button>
          <button
            type="button"
            aria-label="Cancel link editing"
            onClick={() => {
              setLinkFormOpen(false);
              setLinkError(null);
            }}
          >
            Cancel
          </button>
          {linkError ? (
            <p role="alert" className="composer-link-error">
              {linkError}
            </p>
          ) : null}
        </form>
      ) : null}
    </div>
  );
}
