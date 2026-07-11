import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SignatureManager } from "@/components/templates/SignatureManager";
import { TemplatePicker } from "@/components/templates/TemplatePicker";
import { TemplateVariableForm } from "@/components/templates/TemplateVariableForm";
import type {
  SignatureRecord,
  TemplateRecord,
  TemplateVersionRecord,
} from "@/lib/phase2/contracts";

afterEach(() => {
  cleanup();
});

const version: TemplateVersionRecord = {
  id: "tv-1",
  workspace_id: "ws-1",
  template_id: "t-1",
  version_no: 3,
  subject_template: "Hello {{name}}",
  body_template_json: {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: [
          { type: "text", text: "Dear " },
          {
            type: "variable",
            attrs: { key: "name", label: "Recipient name", required: true },
          },
          {
            type: "variable",
            attrs: { key: "ps", label: "Postscript", required: false },
          },
        ],
      },
    ],
  },
  variable_schema: [
    { key: "name", label: "Recipient name", required: true },
    { key: "ps", label: "Postscript", required: false },
  ],
  created_by: "u-1",
  created_at: "2026-07-11T00:00:00Z",
};

describe("TemplateVariableForm", () => {
  it("starts with empty inputs and a disabled Apply button", () => {
    render(<TemplateVariableForm version={version} onApply={() => {}} />);
    const nameInput = screen.getByLabelText("Recipient name");
    expect((nameInput as HTMLInputElement).value).toBe("");
    expect(nameInput.getAttribute("dir")).toBe("auto");
    const apply = screen.getByRole("button", { name: "Apply template" });
    expect((apply as HTMLButtonElement).disabled).toBe(true);
  });

  it("shows a visible alert listing missing required variables", () => {
    render(<TemplateVariableForm version={version} onApply={() => {}} />);
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain("Recipient name");
    expect(alert.textContent).not.toContain("Postscript");
  });

  it("stays blocked for whitespace-only values", () => {
    const onApply = vi.fn();
    render(<TemplateVariableForm version={version} onApply={onApply} />);
    fireEvent.change(screen.getByLabelText("Recipient name"), {
      target: { value: "   " },
    });
    const apply = screen.getByRole("button", { name: "Apply template" });
    expect((apply as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(apply);
    expect(onApply).not.toHaveBeenCalled();
  });

  it("enables Apply once required values are filled and emits the values", () => {
    const onApply = vi.fn();
    render(<TemplateVariableForm version={version} onApply={onApply} />);
    fireEvent.change(screen.getByLabelText("Recipient name"), {
      target: { value: "شكراً جزيلاً" },
    });
    const apply = screen.getByRole("button", { name: "Apply template" });
    expect((apply as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByRole("alert")).toBeNull();
    fireEvent.click(apply);
    expect(onApply).toHaveBeenCalledWith({ name: "شكراً جزيلاً" });
  });

  it("renders an alert for an invalid template version", () => {
    const invalid: TemplateVersionRecord = {
      ...version,
      body_template_json: { type: "doc", content: [{ type: "image" }] },
    };
    render(<TemplateVariableForm version={invalid} onApply={() => {}} />);
    expect(screen.getByRole("alert").textContent).toContain("invalid");
  });
});

describe("TemplatePicker", () => {
  const template: TemplateRecord = {
    id: "t-1",
    workspace_id: "ws-1",
    name: "Onboarding",
    description: "Welcome mail",
    archived_at: null,
    created_by: "u-1",
    created_at: "2026-07-11T00:00:00Z",
    updated_at: "2026-07-11T00:00:00Z",
  };

  it("labels templates vs drafts and shows the immutable version number", () => {
    const onSelectVersion = vi.fn();
    render(
      <TemplatePicker
        templates={[template]}
        versions={[version]}
        onSelectVersion={onSelectVersion}
      />,
    );
    expect(screen.getByText("Onboarding")).toBeDefined();
    expect(screen.getByText(/Version 3/)).toBeDefined();
    expect(screen.getByText(/never changed/)).toBeDefined();
    fireEvent.click(
      screen.getByRole("button", {
        name: "Select version 3 of template Onboarding",
      }),
    );
    expect(onSelectVersion).toHaveBeenCalledWith(version);
  });
});

describe("SignatureManager", () => {
  const signatures: SignatureRecord[] = [
    {
      id: "sig-1",
      workspace_id: "ws-1",
      owner_user_id: "u-1",
      name: "Work",
      body_json: {
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Mohammad" }] },
        ],
      },
      is_default: true,
      created_at: "2026-07-11T00:00:00Z",
      updated_at: "2026-07-11T00:00:00Z",
    },
    {
      id: "sig-2",
      workspace_id: "ws-1",
      owner_user_id: "u-1",
      name: "Privat",
      body_json: {
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Mo" }] },
        ],
      },
      is_default: false,
      created_at: "2026-07-11T00:00:00Z",
      updated_at: "2026-07-11T00:00:00Z",
    },
  ];

  function mountManager() {
    const handlers = {
      onSave: vi.fn(),
      onSetDefault: vi.fn(),
      onDelete: vi.fn(),
      onApply: vi.fn(),
    };
    render(<SignatureManager signatures={signatures} {...handlers} />);
    return handlers;
  }

  it("renders the default badge only for the default signature", () => {
    mountManager();
    expect(screen.getAllByText("Default")).toHaveLength(1);
  });

  it("calls apply, set-default, and delete handlers", () => {
    const handlers = mountManager();
    fireEvent.click(
      screen.getByRole("button", { name: "Apply signature Work" }),
    );
    expect(handlers.onApply).toHaveBeenCalledWith(signatures[0]);

    const setDefaultOnDefault = screen.getByRole("button", {
      name: "Set signature Work as default",
    });
    expect((setDefaultOnDefault as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(
      screen.getByRole("button", { name: "Set signature Privat as default" }),
    );
    expect(handlers.onSetDefault).toHaveBeenCalledWith("sig-2");

    fireEvent.click(
      screen.getByRole("button", { name: "Delete signature Privat" }),
    );
    expect(handlers.onDelete).toHaveBeenCalledWith("sig-2");
  });

  it("creates a signature from textarea lines as canonical paragraphs", () => {
    const handlers = mountManager();
    fireEvent.change(screen.getByLabelText("Signature name"), {
      target: { value: "Neu" },
    });
    fireEvent.change(screen.getByLabelText("Signature body"), {
      target: { value: "Zeile eins\nسطر ثانٍ" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Create signature" }));
    expect(handlers.onSave).toHaveBeenCalledWith({
      name: "Neu",
      body_json: {
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [{ type: "text", text: "Zeile eins" }],
          },
          {
            type: "paragraph",
            content: [{ type: "text", text: "سطر ثانٍ" }],
          },
        ],
      },
    });
  });

  it("prefills the edit form and saves with the signature id", () => {
    const handlers = mountManager();
    fireEvent.click(
      screen.getByRole("button", { name: "Edit signature Work" }),
    );
    const nameInput = screen.getByLabelText(
      "Signature name",
    ) as HTMLInputElement;
    expect(nameInput.value).toBe("Work");
    const body = screen.getByLabelText("Signature body") as HTMLTextAreaElement;
    expect(body.value).toBe("Mohammad");
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(handlers.onSave).toHaveBeenCalledWith({
      id: "sig-1",
      name: "Work",
      body_json: signatures[0]?.body_json,
    });
  });

  it("disables save while the name is blank", () => {
    mountManager();
    const create = screen.getByRole("button", { name: "Create signature" });
    expect((create as HTMLButtonElement).disabled).toBe(true);
  });
});
