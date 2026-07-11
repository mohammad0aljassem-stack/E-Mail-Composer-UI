import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Editor } from "@tiptap/react";
import { ComposerEditor } from "@/components/composer/ComposerEditor";
import type { DraftDocument } from "@/lib/composer/canonical";

afterEach(() => {
  cleanup();
});

async function mountEditor() {
  const documents: DraftDocument[] = [];
  let editor: Editor | null = null;
  const onDocumentChange = vi.fn((doc: DraftDocument) => {
    documents.push(doc);
  });
  render(
    <ComposerEditor
      onDocumentChange={onDocumentChange}
      onEditorReady={(instance) => {
        editor = instance;
      }}
    />,
  );
  await waitFor(() => {
    expect(editor).not.toBeNull();
  });
  return {
    editor: editor as unknown as Editor,
    documents,
    onDocumentChange,
    lastDocument: () => documents[documents.length - 1],
  };
}

describe("ComposerEditor", () => {
  it("updates the canonical JSON when text is entered", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("Hallo Grüße");
    });
    const doc = lastDocument();
    expect(doc).toBeDefined();
    expect(JSON.stringify(doc)).toContain("Hallo Grüße");
    expect(doc?.type).toBe("doc");
  });

  it("applies bold via the toolbar and exposes the active state", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("fett");
    });
    act(() => {
      editor.commands.selectAll();
    });
    const boldButton = screen.getByLabelText("Bold");
    fireEvent.click(boldButton);
    expect(JSON.stringify(lastDocument())).toContain('"bold"');
    await waitFor(() => {
      expect(screen.getByLabelText("Bold").getAttribute("aria-pressed")).toBe(
        "true",
      );
    });
  });

  it("applies italic, lists and blockquote via the toolbar", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("Inhalt");
    });
    act(() => {
      editor.commands.selectAll();
    });
    fireEvent.click(screen.getByLabelText("Italic"));
    expect(JSON.stringify(lastDocument())).toContain('"italic"');
    fireEvent.click(screen.getByLabelText("Bullet list"));
    expect(JSON.stringify(lastDocument())).toContain('"bulletList"');
    fireEvent.click(screen.getByLabelText("Ordered list"));
    expect(JSON.stringify(lastDocument())).toContain('"orderedList"');
    fireEvent.click(screen.getByLabelText("Ordered list")); // back to paragraph
    fireEvent.click(screen.getByLabelText("Blockquote"));
    expect(JSON.stringify(lastDocument())).toContain('"blockquote"');
  });

  it("supports undo and redo via the toolbar", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("Erster Stand");
    });
    expect(JSON.stringify(lastDocument())).toContain("Erster Stand");
    fireEvent.click(screen.getByLabelText("Undo"));
    expect(JSON.stringify(lastDocument())).not.toContain("Erster Stand");
    fireEvent.click(screen.getByLabelText("Redo"));
    expect(JSON.stringify(lastDocument())).toContain("Erster Stand");
  });

  it("rejects unsafe links entered through the link form", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("Dokumentation");
    });
    act(() => {
      editor.commands.selectAll();
    });
    fireEvent.click(screen.getByLabelText("Add or edit link"));
    const input = screen.getByLabelText("Link URL");
    fireEvent.change(input, { target: { value: "javascript:alert(1)" } });
    fireEvent.click(screen.getByLabelText("Apply link"));
    expect(screen.getByRole("alert").textContent).toContain(
      "Only http:, https: and mailto: links are allowed.",
    );
    expect(JSON.stringify(lastDocument())).not.toContain("javascript");
  });

  it("applies safe links entered through the link form and removes them again", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() => {
      editor.commands.insertContent("Dokumentation");
    });
    act(() => {
      editor.commands.selectAll();
    });
    fireEvent.click(screen.getByLabelText("Add or edit link"));
    fireEvent.change(screen.getByLabelText("Link URL"), {
      target: { value: "https://example.com/docs" },
    });
    fireEvent.click(screen.getByLabelText("Apply link"));
    expect(JSON.stringify(lastDocument())).toContain(
      "https://example.com/docs",
    );
    act(() => {
      editor.commands.selectAll();
    });
    fireEvent.click(screen.getByLabelText("Remove link"));
    expect(JSON.stringify(lastDocument())).not.toContain(
      "https://example.com/docs",
    );
  });

  it("keeps toolbar buttons keyboard accessible with aria labels", async () => {
    await mountEditor();
    for (const label of [
      "Bold",
      "Italic",
      "Bullet list",
      "Ordered list",
      "Blockquote",
      "Add or edit link",
      "Remove link",
      "Undo",
      "Redo",
    ]) {
      const button = screen.getByLabelText(label);
      expect(button.tagName).toBe("BUTTON");
      expect(button.getAttribute("type")).toBe("button");
    }
    // Disabled state is represented correctly on an empty document.
    expect(screen.getByLabelText("Undo")).toHaveProperty("disabled", true);
    expect(screen.getByLabelText("Remove link")).toHaveProperty(
      "disabled",
      true,
    );
  });

  it("strips scripts, event handlers and images from pasted HTML", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() =>
      editor.view.pasteHTML(
        '<p onclick="alert(1)">Hallo<script>alert(1)</script></p>' +
          '<img src="x" onerror="alert(1)"><iframe src="https://evil.example"></iframe>',
      ),
    );
    const serialized = JSON.stringify(lastDocument());
    expect(serialized).toContain("Hallo");
    expect(serialized).not.toContain("script");
    expect(serialized).not.toContain("onerror");
    expect(serialized).not.toContain("onclick");
    expect(serialized).not.toContain("image");
    expect(serialized).not.toContain("iframe");
  });

  it("does not keep unsafe links from pasted HTML in the canonical document", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() =>
      editor.view.pasteHTML('<a href="javascript:alert(1)">klick mich</a>'),
    );
    const serialized = JSON.stringify(lastDocument());
    expect(serialized).toContain("klick mich");
    expect(serialized).not.toContain("javascript:");
  });

  it("reduces pasted styled markup to canonical marks", async () => {
    const { editor, lastDocument } = await mountEditor();
    act(() =>
      editor.view.pasteHTML(
        '<div style="color:red"><b>wichtig</b> <span style="font-size:99px">groß</span></div>',
      ),
    );
    const serialized = JSON.stringify(lastDocument());
    expect(serialized).toContain("wichtig");
    expect(serialized).not.toContain("style");
    expect(serialized).not.toContain("color:red");
  });
});
