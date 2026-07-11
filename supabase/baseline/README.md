# Baseline schema snapshot (test scaffolding — NOT deployable)

## What this is

`production_schema_2026_07_11.sql` recreates the **current production schema**
of the Supabase project (`fpanvpxjjddhasjmpflz`) on a vanilla local
PostgreSQL 16 server so that the Phase 2 migration
(`supabase/migrations/20260711130000_draft_lifecycle.sql`) and its
database/RLS tests (`supabase/tests/database/*.test.sql`) can run in complete
isolation, without Docker and without touching production.

It contains:

- the `public` schema as production has it today: `users`, `workspaces`,
  `workspace_members`, the core domain tables, the
  `is_workspace_member(uuid)` / `is_workspace_admin(uuid)` SECURITY DEFINER
  helpers, the `handle_new_auth_user` trigger, grants, and all RLS policies;
- **local shims** for the managed schemas: `auth` (`auth.uid()`,
  `auth.role()`, `auth.jwt()` reading the `request.jwt.claims` GUC, plus a
  minimal `auth.users` table) and `storage` (`storage.buckets`,
  `storage.objects` with `path_tokens`, `storage.foldername()` /
  `storage.filename()`), and the `anon` / `authenticated` / `service_role`
  roles. On a real Supabase stack these already exist and the shim sections
  skip themselves (`IF NOT EXISTS` guards).

## What this is NOT

This file is **non-deployable test scaffolding**. It must never be placed in
`supabase/migrations/` and never be executed against production: production
already contains everything in it (created by migrations
`20260709124453` … `20260709182252`), so applying it there would be a
destructive error. It contains no production data, no secrets, and no
`auth.users` records. The only deployable Phase 2 artifact is the migration
in `supabase/migrations/`.

## Provenance

- **Generation date:** 2026-07-11
- **Source:** read-only catalog inspection of the production project
  (`pg_policies`, `pg_proc`, `pg_indexes`, `pg_constraint`,
  `information_schema.role_table_grants`, `pg_trigger`). No writes were made.
- **Production migration history at generation time** (latest last):
  `20260709124453`, `20260709124644`, `20260709124738`, `20260709124846`,
  `20260709182129`, `20260709182252`.

## Checksum

```
sha256(production_schema_2026_07_11.sql) =
d4dee9b8be1b352d4c17db8a7952741661a9c547bec5ac4216f42b27be8c8487
```

Verify with:

```sh
sha256sum supabase/baseline/production_schema_2026_07_11.sql
```

## How to regenerate

1. Connect to production **read-only** (e.g. `supabase db dump --schema public`
   against the linked project, or inspect `pg_catalog` /
   `information_schema` views listed above; never run DDL).
2. Re-emit the `public` schema DDL (tables, functions, triggers, grants, RLS)
   exactly as observed, keeping objects created by later migrations out of
   the shims.
3. Keep the local `auth` / `storage` / role shim sections at the top intact —
   they emulate the managed Supabase schemas for vanilla PostgreSQL and are
   not part of production's `public` schema.
4. Name the file `production_schema_YYYY_MM_DD.sql`, update the header's
   generation date and migration history, then update the checksum in this
   README (`sha256sum <file>`), and point `scripts/test-db.sh` at the new
   filename.

## How it is used

`scripts/test-db.sh` spins up a throwaway PostgreSQL 16 cluster
(port 54329), applies this baseline, applies the Phase 2 migration on top —
mirroring what `supabase db push` will do to production — and then runs the
three test suites in `supabase/tests/database/`.
