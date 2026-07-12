-- ============================================================================
-- Security-relevant schema snapshot for Phase 2 migration-equivalence checks.
--
-- NOT a test suite (it lives outside supabase/tests/database so the runner's
-- *.test.sql glob ignores it). scripts/test-db.sh runs it with `-A -t` against
-- freshly built databases (baseline->A, baseline->fixture->B, baseline->A->B->B)
-- and diffs the outputs; any difference fails the run. Every SELECT is fully
-- ordered so the output is deterministic.
-- ============================================================================
\pset pager off

-- 1. Table privileges for the six Phase 2 tables (anon/authenticated/service_role).
select 'GRANT|' || grantee || '|' || table_name || '|' || string_agg(privilege_type, ',' order by privilege_type)
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('drafts','draft_versions','draft_templates',
                     'draft_template_versions','signatures','draft_attachments')
  and grantee in ('anon','authenticated','service_role')
group by grantee, table_name
order by 1;

-- 2. Function shape: security, config, owner, and normalized definition.
select 'FUNC|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
       || '|secdef=' || p.prosecdef
       || '|config=' || coalesce(array_to_string(p.proconfig, ','), '')
       || '|owner=' || pg_get_userbyid(p.proowner)
       || '|acl=' || coalesce(array_to_string(p.proacl::text[], ','), 'NULL')
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (p.proname like 'phase2\_%'
       or p.proname in ('create_draft','save_draft','checkpoint_draft',
         'restore_draft_version','archive_draft','create_template_version',
         'set_default_signature','create_attachment_intent',
         'finalize_attachment','mark_attachment_deleted'))
order by 1;

-- 2b. Full function bodies (normalized by pg_get_functiondef).
select 'FUNCDEF|' || md5(pg_get_functiondef(p.oid)) || '|' || p.proname
       || '(' || pg_get_function_identity_arguments(p.oid) || ')'
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (p.proname like 'phase2\_%'
       or p.proname in ('create_draft','save_draft','checkpoint_draft',
         'restore_draft_version','archive_draft','create_template_version',
         'set_default_signature','create_attachment_intent',
         'finalize_attachment','mark_attachment_deleted'))
order by 1;

-- 3. RLS policies on the six Phase 2 tables.
select 'POLICY|' || tablename || '|' || policyname || '|' || cmd
       || '|roles=' || array_to_string(roles, ',')
       || '|using=' || coalesce(qual, '')
       || '|check=' || coalesce(with_check, '')
from pg_policies
where schemaname = 'public'
  and tablename in ('drafts','draft_versions','draft_templates',
                    'draft_template_versions','signatures','draft_attachments')
order by 1;

-- 4. Triggers on the six Phase 2 tables.
select 'TRIGGER|' || c.relname || '|' || t.tgname || '|' || pg_get_triggerdef(t.oid)
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where c.relnamespace = 'public'::regnamespace
  and c.relname in ('drafts','draft_versions','draft_templates',
                    'draft_template_versions','signatures','draft_attachments')
  and not t.tgisinternal
order by 1;

-- 5. Constraints on the six Phase 2 tables.
select 'CONSTRAINT|' || c.relname || '|' || con.conname || '|' || pg_get_constraintdef(con.oid)
from pg_constraint con
join pg_class c on c.oid = con.conrelid
where c.relnamespace = 'public'::regnamespace
  and c.relname in ('drafts','draft_versions','draft_templates',
                    'draft_template_versions','signatures','draft_attachments')
order by 1;

-- 6. Storage object policies (the draft-attachments hardening).
select 'STORAGE_POLICY|' || policyname || '|' || cmd
       || '|roles=' || array_to_string(roles, ',')
       || '|using=' || coalesce(qual, '')
       || '|check=' || coalesce(with_check, '')
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and policyname like 'draft_attachments_objects_%'
order by 1;

-- 7. Bucket configuration.
select 'BUCKET|' || id || '|public=' || coalesce(public::text,'')
       || '|limit=' || coalesce(file_size_limit::text,'')
       || '|mimes=' || coalesce(array_to_string(allowed_mime_types, ','),'')
from storage.buckets
where id = 'draft-attachments'
order by 1;

-- 8. Storage object privileges (should be unchanged from baseline).
select 'STORAGE_GRANT|' || grantee || '|' || string_agg(privilege_type, ',' order by privilege_type)
from information_schema.role_table_grants
where table_schema = 'storage' and table_name = 'objects'
  and grantee in ('anon','authenticated','service_role')
group by grantee
order by 1;
