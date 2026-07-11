/**
 * Small deterministic relative-time formatter for draft list metadata.
 * Pure function (no locale surprises) so it is trivially unit-testable.
 */

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

export function formatRelativeTime(
  isoTimestamp: string,
  nowMs: number = Date.now(),
): string {
  const then = Date.parse(isoTimestamp);
  if (Number.isNaN(then)) {
    return "unknown";
  }
  const elapsed = nowMs - then;
  if (elapsed < MINUTE_MS) {
    return "just now";
  }
  if (elapsed < HOUR_MS) {
    const minutes = Math.floor(elapsed / MINUTE_MS);
    return minutes === 1 ? "1 minute ago" : `${minutes} minutes ago`;
  }
  if (elapsed < DAY_MS) {
    const hours = Math.floor(elapsed / HOUR_MS);
    return hours === 1 ? "1 hour ago" : `${hours} hours ago`;
  }
  const days = Math.floor(elapsed / DAY_MS);
  if (days < 30) {
    return days === 1 ? "1 day ago" : `${days} days ago`;
  }
  return new Date(then).toISOString().slice(0, 10);
}
