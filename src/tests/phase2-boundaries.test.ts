// @vitest-environment node

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Repository boundary tests: the Phase 2 rules that are cheapest to enforce
 * mechanically — no service-role usage, no e-mail transport, no AI SDKs,
 * fail-closed example configuration.
 */

const ROOT = process.cwd();

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      walk(full, out);
    } else {
      out.push(full);
    }
  }
  return out;
}

const sourceFiles = walk(join(ROOT, "src")).filter(
  (file) => /\.(ts|tsx|css)$/.test(file) && !/\/tests\//.test(file),
);

describe("service-role key exposure", () => {
  it("no source file references a service-role key", () => {
    for (const file of sourceFiles) {
      const content = readFileSync(file, "utf-8");
      expect(content, file).not.toMatch(/service[_-]?role/i);
      expect(content, file).not.toMatch(/sb_secret_/);
    }
  });

  it(".env.example contains no service-role variable and no real key", () => {
    const env = readFileSync(join(ROOT, ".env.example"), "utf-8");
    expect(env).not.toMatch(/SERVICE_ROLE\s*=/);
    expect(env).not.toMatch(/sb_secret_[a-z0-9]/i);
    expect(env).toContain("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  });

  it(".env.example is fail-closed (all flags disabled)", () => {
    const env = readFileSync(join(ROOT, ".env.example"), "utf-8");
    expect(env).toMatch(/NEXT_PUBLIC_COMPOSER_V1_ENABLED=false/);
    expect(env).toMatch(/NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED=false/);
  });
});

describe("forbidden dependencies", () => {
  const packageJson = JSON.parse(
    readFileSync(join(ROOT, "package.json"), "utf-8"),
  ) as {
    dependencies: Record<string, string>;
    devDependencies: Record<string, string>;
  };
  const allDeps = Object.keys({
    ...packageJson.dependencies,
    ...packageJson.devDependencies,
  });

  it("contains no e-mail transport, AI, or queue packages", () => {
    const forbidden = [
      "nodemailer",
      "mailparser",
      "imapflow",
      "smtp",
      "openai",
      "@anthropic-ai",
      "ai",
      "@ai-sdk",
      "redis",
      "ioredis",
      "bullmq",
      "@upstash/qstash",
      "googleapis",
      "@microsoft/microsoft-graph-client",
    ];
    for (const name of forbidden) {
      expect(
        allDeps.some((dep) => dep === name || dep.startsWith(`${name}/`)),
        `dependency ${name} must not be present`,
      ).toBe(false);
    }
  });

  it("source contains no transport or AI imports", () => {
    for (const file of sourceFiles) {
      const content = readFileSync(file, "utf-8");
      expect(content, file).not.toMatch(
        /from ["'](nodemailer|imapflow|mailparser|openai|@anthropic-ai)/,
      );
    }
  });
});

describe("deployable migration hygiene", () => {
  it("the baseline SQL lives outside supabase/migrations", () => {
    const migrations = readdirSync(join(ROOT, "supabase", "migrations"));
    for (const file of migrations) {
      expect(file).not.toMatch(/baseline|production_schema/);
    }
    const baseline = readdirSync(join(ROOT, "supabase", "baseline"));
    expect(baseline.join(",")).toContain("production_schema_2026_07_11.sql");
  });

  it("every post-production migration is newer than the last production migration", () => {
    const migrations = readdirSync(join(ROOT, "supabase", "migrations")).filter(
      (file) => file.endsWith(".sql"),
    );
    // Phase 2 draft-lifecycle + Phase 2 RPC hardening + Phase 3A transport;
    // all must sort after the production tip.
    expect(migrations.length).toBe(3);
    for (const file of migrations) {
      const version = file.split("_")[0] ?? "0";
      expect(Number(version)).toBeGreaterThan(20260709182252);
    }
  });

  it("no migration contains destructive statements", () => {
    const migrations = readdirSync(join(ROOT, "supabase", "migrations")).filter(
      (file) => file.endsWith(".sql"),
    );
    for (const file of migrations) {
      let sql = readFileSync(
        join(ROOT, "supabase", "migrations", file),
        "utf-8",
      );
      // Strip single-line comments (-- ...)
      sql = sql.replace(/--.*$/gm, "");
      // Strip multi-line comments (/* ... */)
      sql = sql.replace(/\/\*[\s\S]*?\*\//g, "");
      sql = sql.toLowerCase();
      // DROP POLICY / DROP FUNCTION / REVOKE are legitimate hardening tools;
      // only data-destroying statements are forbidden.
      expect(sql, file).not.toMatch(/\bdrop\s+table\b/);
      expect(sql, file).not.toMatch(/\btruncate\b/);
      expect(sql, file).not.toMatch(/\bdelete\s+from\s+public\./);
    }
  });
});
