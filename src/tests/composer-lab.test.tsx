import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  ComposerLab,
  COMPOSER_LAB_STORAGE_KEY,
} from "@/components/composer/ComposerLab";
import {
  createEmptyDraftDocument,
  validateDraftDocument,
} from "@/lib/composer/canonical";

const originalFlag = process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED;

beforeEach(() => {
  process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = "true";
  window.localStorage.clear();
});

afterEach(() => {
  cleanup();
  process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = originalFlag;
});

async function mountLab() {
  render(<ComposerLab />);
  await waitFor(() => {
    expect(document.querySelector(".composer-editor-content")).not.toBeNull();
  });
}

function canonicalJsonPanel(): string {
  return screen.getByTestId("canonical-json").textContent ?? "";
}

describe("ComposerLab", () => {
  it("shows a disabled notice when the feature flag is off", () => {
    process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = "false";
    render(<ComposerLab />);
    expect(
      screen.getByText(/feature is disabled/i, { exact: false }),
    ).toBeDefined();
    expect(document.querySelector(".composer-editor")).toBeNull();
  });

  it("shows the localStorage development notice", async () => {
    await mountLab();
    expect(
      screen.getByText(/not production persistence/i, { exact: false }),
    ).toBeDefined();
  });

  it("loads the Arabic/German sample into editor and JSON panel", async () => {
    await mountLab();
    fireEvent.click(screen.getByText("Load Arabic/German sample"));
    await waitFor(() => {
      expect(canonicalJsonPanel()).toContain("Überprüfung der Größe");
      expect(canonicalJsonPanel()).toContain("مرحباً");
    });
  });

  it("saves canonical JSON (and only JSON) to a versioned localStorage key", async () => {
    await mountLab();
    fireEvent.click(screen.getByText("Load Arabic/German sample"));
    fireEvent.click(screen.getByText("Save JSON locally"));
    const stored = window.localStorage.getItem(COMPOSER_LAB_STORAGE_KEY);
    expect(stored).not.toBeNull();
    expect(COMPOSER_LAB_STORAGE_KEY).toMatch(/\.v1$/);
    const parsed: unknown = JSON.parse(stored as string);
    expect(validateDraftDocument(parsed).ok).toBe(true);
    // JSON only — never generated HTML.
    expect(stored).not.toContain("<");
  });

  it("reset restores the empty canonical document", async () => {
    await mountLab();
    fireEvent.click(screen.getByText("Load Arabic/German sample"));
    fireEvent.click(screen.getByText("Reset"));
    await waitFor(() => {
      expect(JSON.parse(canonicalJsonPanel())).toEqual(
        createEmptyDraftDocument(),
      );
    });
  });

  it("load restores the previously saved document", async () => {
    await mountLab();
    fireEvent.click(screen.getByText("Load Arabic/German sample"));
    fireEvent.click(screen.getByText("Save JSON locally"));
    fireEvent.click(screen.getByText("Reset"));
    await waitFor(() => {
      expect(canonicalJsonPanel()).not.toContain("مرحباً");
    });
    fireEvent.click(screen.getByText("Load saved JSON"));
    await waitFor(() => {
      expect(canonicalJsonPanel()).toContain("مرحباً");
    });
  });

  it("refuses to load tampered non-canonical localStorage content", async () => {
    await mountLab();
    window.localStorage.setItem(
      COMPOSER_LAB_STORAGE_KEY,
      JSON.stringify({
        type: "doc",
        content: [{ type: "rawHtml", html: "<script>alert(1)</script>" }],
      }),
    );
    fireEvent.click(screen.getByText("Load saved JSON"));
    await waitFor(() => {
      expect(screen.getByRole("status").textContent).toContain(
        "not a valid canonical document",
      );
    });
    expect(canonicalJsonPanel()).not.toContain("rawHtml");
  });
});
