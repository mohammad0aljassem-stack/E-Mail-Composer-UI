/**
 * Bounded streaming JSON body reader.
 *
 * Replaces the Phase 1 pattern of `await request.text()` followed by a size
 * check: the stream is read incrementally and aborted the moment the limit
 * is exceeded, so an oversized (or chunked, Content-Length-less) request can
 * never be buffered fully into memory.
 */

export type BodyReadResult =
  | { ok: true; value: unknown }
  | {
      ok: false;
      status: number;
      code:
        | "unsupported_media_type"
        | "payload_too_large"
        | "invalid_body"
        | "invalid_json";
      message: string;
    };

/**
 * Reads and parses a JSON request body while enforcing `maxBytes`.
 *
 * - rejects non-JSON Content-Type (415);
 * - rejects an oversized declared Content-Length before reading (413);
 * - enforces the real streamed byte count even without Content-Length (413),
 *   cancelling the reader as soon as the limit is crossed;
 * - decodes UTF-8 leniently (malformed sequences become U+FFFD, they never
 *   throw) and surfaces JSON errors as structured 400s.
 */
export async function readJsonBodyWithLimit(
  request: Request,
  maxBytes: number,
): Promise<BodyReadResult> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return {
      ok: false,
      status: 415,
      code: "unsupported_media_type",
      message: "Content-Type must be application/json.",
    };
  }

  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    return {
      ok: false,
      status: 413,
      code: "payload_too_large",
      message: `Request body must not exceed ${maxBytes} bytes.`,
    };
  }

  const body = request.body;
  let raw: string;

  if (body === null) {
    raw = "";
  } else {
    const reader = body.getReader();
    const decoder = new TextDecoder("utf-8", { fatal: false });
    let received = 0;
    let text = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        received += value.byteLength;
        if (received > maxBytes) {
          // Stop immediately; do not buffer the rest of the stream.
          await reader.cancel().catch(() => undefined);
          return {
            ok: false,
            status: 413,
            code: "payload_too_large",
            message: `Request body must not exceed ${maxBytes} bytes.`,
          };
        }
        text += decoder.decode(value, { stream: true });
      }
      text += decoder.decode();
    } catch {
      return {
        ok: false,
        status: 400,
        code: "invalid_body",
        message: "Request body could not be read.",
      };
    } finally {
      reader.releaseLock();
    }
    raw = text;
  }

  try {
    return { ok: true, value: JSON.parse(raw) as unknown };
  } catch {
    return {
      ok: false,
      status: 400,
      code: "invalid_json",
      message: "Request body is not valid JSON.",
    };
  }
}
