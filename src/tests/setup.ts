/**
 * Test setup. jsdom does not implement the DOM measurement APIs that
 * prosemirror-view relies on, so minimal stubs are installed for editor
 * tests. Node-environment tests (rendering, API) skip this block.
 */

if (typeof window !== "undefined") {
  const rect: DOMRect = {
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    top: 0,
    left: 0,
    bottom: 0,
    right: 0,
    toJSON: () => ({}),
  };

  const emptyRectList = (): DOMRectList => {
    const list = [] as unknown as DOMRectList;
    (list as unknown as { item: (index: number) => DOMRect | null }).item =
      () => null;
    return list;
  };

  Range.prototype.getBoundingClientRect = () => rect;
  Range.prototype.getClientRects = emptyRectList;
  HTMLElement.prototype.getBoundingClientRect = () => rect;
  HTMLElement.prototype.getClientRects = emptyRectList;
  Document.prototype.elementFromPoint = () => null;

  // jsdom has no ClipboardEvent/DataTransfer; prosemirror-view's pasteHTML
  // needs the constructors to exist.
  if (typeof globalThis.ClipboardEvent === "undefined") {
    class ClipboardEventPolyfill extends Event {
      clipboardData = null;
    }
    Object.assign(globalThis, { ClipboardEvent: ClipboardEventPolyfill });
  }
  if (typeof globalThis.DataTransfer === "undefined") {
    class DataTransferPolyfill {
      private data = new Map<string, string>();
      getData(format: string): string {
        return this.data.get(format) ?? "";
      }
      setData(format: string, value: string): void {
        this.data.set(format, value);
      }
    }
    Object.assign(globalThis, { DataTransfer: DataTransferPolyfill });
  }
}
