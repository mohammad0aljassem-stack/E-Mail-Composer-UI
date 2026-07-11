// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AttachmentPanel } from "@/components/attachments/AttachmentPanel";
import { AttachmentManifestPreview } from "@/components/attachments/AttachmentManifestPreview";
import {
  deletedAttachment,
  failedAttachment,
  pendingAttachment,
  readyAttachment,
} from "./fixtures";

afterEach(cleanup);

function renderPanel(
  attachments = [] as Parameters<typeof AttachmentPanel>[0]["attachments"],
) {
  const onSelectFiles = vi.fn();
  const onRemove = vi.fn();
  const onRetry = vi.fn();
  const utils = render(
    <AttachmentPanel
      attachments={attachments}
      onSelectFiles={onSelectFiles}
      onRemove={onRemove}
      onRetry={onRetry}
    />,
  );
  return { onSelectFiles, onRemove, onRetry, ...utils };
}

function selectFiles(files: File[]) {
  const input = screen.getByLabelText<HTMLInputElement>("Add attachment");
  fireEvent.change(input, { target: { files } });
}

describe("AttachmentPanel", () => {
  it("shows Uploading… (and not Attached) for pending attachments", () => {
    renderPanel([pendingAttachment({ safe_filename: "wip.pdf" })]);
    expect(screen.getByText("Uploading…")).toBeDefined();
    expect(screen.queryByText("Attached")).toBeNull();
  });

  it("shows Attached only for ready attachments", () => {
    renderPanel([readyAttachment({ safe_filename: "done.pdf" })]);
    expect(screen.getByText("Attached")).toBeDefined();
    expect(screen.queryByText("Uploading…")).toBeNull();
  });

  it("shows Failed with a retry button and wires onRetry", () => {
    const { onRetry } = renderPanel([
      failedAttachment({ id: "fail-1", safe_filename: "broken.pdf" }),
    ]);
    expect(screen.getByText("Failed")).toBeDefined();
    fireEvent.click(
      screen.getByRole("button", { name: "Retry upload of broken.pdf" }),
    );
    expect(onRetry).toHaveBeenCalledWith("fail-1");
  });

  it("hides deleted attachments", () => {
    renderPanel([deletedAttachment({ safe_filename: "gone.pdf" })]);
    expect(screen.queryByText("gone.pdf")).toBeNull();
    expect(screen.queryByTestId("attachment-row")).toBeNull();
  });

  it("rejects a forbidden file type with a visible error and no callback", () => {
    const { onSelectFiles } = renderPanel();
    selectFiles([
      new File(["<html></html>"], "evil.html", { type: "text/html" }),
    ]);
    const errors = screen.getByTestId("attachment-errors");
    expect(errors.textContent).toContain("evil.html");
    expect(errors.textContent).toContain("not allowed");
    expect(onSelectFiles).not.toHaveBeenCalled();
  });

  it("rejects a file when the draft already has 10 attachments", () => {
    const existing = Array.from({ length: 10 }, (_, i) =>
      readyAttachment({ id: `full-${i}`, size_bytes: 1 }),
    );
    const { onSelectFiles } = renderPanel(existing);
    selectFiles([new File(["x"], "extra.pdf", { type: "application/pdf" })]);
    expect(screen.getByTestId("attachment-errors").textContent).toContain(
      "at most 10",
    );
    expect(onSelectFiles).not.toHaveBeenCalled();
  });

  it("passes only the valid files of a mixed selection to onSelectFiles", () => {
    const { onSelectFiles } = renderPanel();
    const good = new File(["ok"], "good.pdf", { type: "application/pdf" });
    const bad = new File(["nope"], "bad.svg", { type: "image/svg+xml" });
    selectFiles([good, bad]);
    expect(onSelectFiles).toHaveBeenCalledTimes(1);
    expect(onSelectFiles).toHaveBeenCalledWith([good]);
    expect(screen.getByTestId("attachment-errors").textContent).toContain(
      "bad.svg",
    );
  });

  it("calls onRemove with the attachment id", () => {
    const { onRemove } = renderPanel([
      readyAttachment({ id: "rm-1", safe_filename: "report.pdf" }),
    ]);
    fireEvent.click(
      screen.getByRole("button", { name: "Remove attachment report.pdf" }),
    );
    expect(onRemove).toHaveBeenCalledWith("rm-1");
  });

  it("renders HTML-ish filenames as escaped text, never as markup", () => {
    const { container } = renderPanel([
      readyAttachment({
        safe_filename: '<img src="x" onerror="alert(1)">.pdf',
      }),
    ]);
    // No element is ever created from the filename ...
    expect(container.querySelector("img")).toBeNull();
    expect(container.querySelector("iframe")).toBeNull();
    // ... and the visible filename is serialized in escaped form.
    expect(container.innerHTML).toContain(
      '&lt;img src="x" onerror="alert(1)"&gt;.pdf',
    );
    expect(
      screen.getByText('<img src="x" onerror="alert(1)">.pdf'),
    ).toBeDefined();
  });

  it("shows count and total size against the limits", () => {
    renderPanel([
      readyAttachment({ id: "s-1", size_bytes: 1024 }),
      readyAttachment({ id: "s-2", size_bytes: 1024 }),
      deletedAttachment({ id: "s-3", size_bytes: 4096 }),
    ]);
    const limits = screen.getByTestId("attachment-limits");
    expect(limits.textContent).toContain("2 / 10 files");
    expect(limits.textContent).toContain("2.0 KiB / 25.0 MiB total");
  });

  it("restricts the file input to the allowed extensions", () => {
    renderPanel();
    const input = screen.getByLabelText<HTMLInputElement>("Add attachment");
    expect(input.accept).toBe(".pdf,.png,.jpg,.jpeg,.txt");
    expect(input.type).toBe("file");
  });
});

describe("AttachmentManifestPreview", () => {
  it("shows the explicit empty state", () => {
    render(<AttachmentManifestPreview items={[]} />);
    expect(screen.getByText("Attachments (0)")).toBeDefined();
    expect(screen.getByText("No verified attachments.")).toBeDefined();
  });

  it("lists manifest items as plain text", () => {
    const { container } = render(
      <AttachmentManifestPreview
        items={[
          {
            attachmentId: "att-1",
            bucket: "draft-attachments",
            path: "ws/draft/att-1/<b>bold</b>.pdf",
            filename: "<b>bold</b>.pdf",
            contentType: "application/pdf",
            sizeBytes: 2048,
            sha256: null,
          },
        ]}
      />,
    );
    expect(screen.getByText("Attachments (1)")).toBeDefined();
    expect(screen.getByText("<b>bold</b>.pdf")).toBeDefined();
    expect(container.querySelector("b")).toBeNull();
    expect(container.innerHTML).toContain("&lt;b&gt;");
  });
});
