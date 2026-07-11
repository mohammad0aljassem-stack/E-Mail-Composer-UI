import type { NextConfig } from "next";

const isDev = process.env.NODE_ENV === "development";

/**
 * Content-Security-Policy notes (see docs/adr/0001-canonical-composer.md):
 *
 * - `script-src` keeps `'unsafe-inline'` because Next.js emits inline
 *   bootstrap scripts without a nonce setup; `'unsafe-eval'` is added in
 *   development only (React Fast Refresh needs it).
 * - `style-src 'unsafe-inline'` is required by the email preview: generated
 *   email HTML uses inline styles by design, and the sandboxed srcdoc iframe
 *   inherits this policy.
 * - The preview iframe is additionally locked down with an empty `sandbox`
 *   attribute (no scripts, no forms, no popups, no top-level navigation).
 */
const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self'",
  "frame-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");

const nextConfig: NextConfig = {
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "Content-Security-Policy", value: contentSecurityPolicy },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
        ],
      },
    ];
  },
};

export default nextConfig;
