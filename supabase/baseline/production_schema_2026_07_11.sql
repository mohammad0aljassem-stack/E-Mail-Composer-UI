-- ============================================================================
-- NON-DEPLOYABLE TEST SCAFFOLDING — DO NOT APPLY TO PRODUCTION
-- ============================================================================
-- This file recreates the CURRENT production schema of Supabase project
-- fpanvpxjjddhasjmpflz as observed READ-ONLY on 2026-07-11, so that the
-- Phase 2 migration and its database/RLS tests can run against an isolated
-- local PostgreSQL database.
--
-- * It is NOT a migration. It must never be placed in supabase/migrations.
-- * Production already contains everything in here (created by migrations
--   20260709124453 .. 20260709182252); applying this file to production
--   would be a destructive error.
-- * It contains no production data, no secrets, and no auth.users records.
-- * The `auth` and `storage` sections are minimal local shims that emulate
--   the managed Supabase schemas (auth.uid(), storage.objects, ...) closely
--   enough for RLS testing on vanilla PostgreSQL. On a real Supabase stack
--   those schemas already exist and the shim section is skipped.
--
-- Generation date: 2026-07-11
-- Source: read-only catalog inspection of project fpanvpxjjddhasjmpflz
--         (pg_policies, pg_proc, pg_indexes, pg_constraint,
--          information_schema.role_table_grants, pg_trigger).
-- Production migration history at generation time:
--   20260709124453 core_domain_schema
--   20260709124644 core_domain_schema
--   20260709124738 revoke_anon_execute_on_helper_functions
--   20260709124846 core_domain_schema
--   20260709182129 add_confirmed_requirement_status
--   20260709182252 enforce_case_facts_integrity
-- The SHA-256 checksum of this file is recorded in supabase/baseline/README.md.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Local shim: Supabase roles (skipped when they already exist)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Local shim: auth schema (managed by Supabase in production)
-- ---------------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key,
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Mirrors the managed implementation: identity comes from the request JWT.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      current_setting('request.jwt.claims', true)::jsonb ->> 'sub'
    ),
    ''
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    'anon'
  )
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  )
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt()
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Local shim: storage schema (managed by Supabase Storage in production)
-- ---------------------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  public boolean default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  owner_id text
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  version text,
  owner_id text,
  user_metadata jsonb
);

create unique index if not exists objects_bucket_name_uidx
  on storage.objects (bucket_id, name);

create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select (string_to_array(name, '/'))[1 : array_length(string_to_array(name, '/'), 1) - 1]
$$;

create or replace function storage.filename(name text)
returns text
language sql
immutable
as $$
  select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)]
$$;

alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;

grant select, insert, update, delete on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
grant all on storage.objects, storage.buckets to service_role;

-- ---------------------------------------------------------------------------
-- 3. Production public schema — enums
-- ---------------------------------------------------------------------------
create type public.workspace_role as enum ('owner', 'admin', 'member');
create type public.intake_document_status as enum ('pending', 'processing', 'processed', 'failed');
create type public.requirement_status as enum ('available', 'missing', 'uncertain', 'needs_confirmation', 'confirmed');
create type public.clarification_question_status as enum ('open', 'answered', 'dismissed');
create type public.task_status as enum ('suggested', 'open', 'in_progress', 'done', 'dismissed');
create type public.reminder_status as enum ('scheduled', 'fired', 'cancelled');
create type public.notification_channel as enum ('in_app', 'email');

-- ---------------------------------------------------------------------------
-- 4. Production public schema — tables
-- ---------------------------------------------------------------------------
create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  full_name text,
  created_at timestamptz not null default now()
);

create table public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  role public.workspace_role not null default 'member',
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id)
);
create index idx_workspace_members_workspace_id on public.workspace_members (workspace_id);
create index idx_workspace_members_user_id on public.workspace_members (user_id);

create table public.intake_documents (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  uploaded_by uuid references public.users (id) on delete set null,
  file_name text not null,
  storage_path text,
  mime_type text,
  status public.intake_document_status not null default 'pending',
  created_at timestamptz not null default now()
);
create index idx_intake_documents_workspace_id on public.intake_documents (workspace_id);
create index idx_intake_documents_status on public.intake_documents (status);
create index idx_intake_documents_uploaded_by on public.intake_documents (uploaded_by);

create table public.requirements (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  intake_document_id uuid not null references public.intake_documents (id) on delete cascade,
  title text not null,
  description text,
  status public.requirement_status not null default 'missing',
  created_at timestamptz not null default now(),
  is_critical boolean not null default false
);
create index idx_requirements_workspace_id on public.requirements (workspace_id);
create index idx_requirements_status on public.requirements (status);
create index idx_requirements_intake_document_id on public.requirements (intake_document_id);

create table public.case_facts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  intake_document_id uuid references public.intake_documents (id) on delete set null,
  requirement_id uuid not null references public.requirements (id) on delete cascade,
  fact_key text not null,
  fact_value text,
  source text,
  created_at timestamptz not null default now()
);
create index idx_case_facts_workspace_id on public.case_facts (workspace_id);
create index idx_case_facts_intake_document_id on public.case_facts (intake_document_id);
create index idx_case_facts_requirement_id on public.case_facts (requirement_id);

create table public.clarification_questions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  requirement_id uuid not null references public.requirements (id) on delete cascade,
  question text not null,
  answer text,
  status public.clarification_question_status not null default 'open',
  created_at timestamptz not null default now()
);
create index idx_clarification_questions_workspace_id on public.clarification_questions (workspace_id);
create index idx_clarification_questions_status on public.clarification_questions (status);
create index idx_clarification_questions_requirement_id on public.clarification_questions (requirement_id);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  requirement_id uuid references public.requirements (id) on delete set null,
  title text not null,
  description text,
  status public.task_status not null default 'suggested',
  assigned_to uuid references public.users (id) on delete set null,
  due_date timestamptz,
  created_at timestamptz not null default now()
);
create index idx_tasks_workspace_id on public.tasks (workspace_id);
create index idx_tasks_status on public.tasks (status);
create index idx_tasks_requirement_id on public.tasks (requirement_id);
create index idx_tasks_assigned_to on public.tasks (assigned_to);

create table public.task_checklist_items (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  task_id uuid not null references public.tasks (id) on delete cascade,
  label text not null,
  is_complete boolean not null default false,
  position integer not null default 0,
  created_at timestamptz not null default now()
);
create index idx_task_checklist_items_workspace_id on public.task_checklist_items (workspace_id);
create index idx_task_checklist_items_task_id on public.task_checklist_items (task_id);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  task_id uuid references public.tasks (id) on delete cascade,
  remind_at timestamptz not null,
  status public.reminder_status not null default 'scheduled',
  created_at timestamptz not null default now()
);
create index idx_reminders_workspace_id on public.reminders (workspace_id);
create index idx_reminders_status on public.reminders (status);
create index idx_reminders_task_id on public.reminders (task_id);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  related_task_id uuid references public.tasks (id) on delete set null,
  type text not null,
  title text not null,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_notifications_workspace_id on public.notifications (workspace_id);
create index idx_notifications_user_id on public.notifications (user_id);
create index idx_notifications_related_task_id on public.notifications (related_task_id);

create table public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  channel public.notification_channel not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id, channel)
);
create index idx_notification_preferences_workspace_id on public.notification_preferences (workspace_id);
create index idx_notification_preferences_user_id on public.notification_preferences (user_id);

-- ---------------------------------------------------------------------------
-- 5. Production public schema — functions
-- ---------------------------------------------------------------------------
create or replace function public.is_workspace_member(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.workspace_members m
    where m.workspace_id = p_workspace_id
      and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_workspace_admin(p_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.workspace_members m
    where m.workspace_id = p_workspace_id
      and m.user_id = auth.uid()
      and m.role in ('owner', 'admin')
  );
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.users (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.enforce_case_fact_requirement_confirmed()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_status public.requirement_status;
begin
  select status into v_status
  from public.requirements
  where id = new.requirement_id;

  if v_status is distinct from 'confirmed'::public.requirement_status then
    raise exception 'case_facts.requirement_id % must reference a requirement with status ''confirmed'' (found ''%'')',
      new.requirement_id, v_status
      using errcode = '23514';
  end if;

  return new;
end;
$$;

-- Production function execution grants (helper functions are callable by
-- authenticated only; trigger functions by service_role/postgres only).
revoke execute on function public.is_workspace_member(uuid) from public, anon;
revoke execute on function public.is_workspace_admin(uuid) from public, anon;
grant execute on function public.is_workspace_member(uuid) to authenticated, service_role;
grant execute on function public.is_workspace_admin(uuid) to authenticated, service_role;
revoke execute on function public.handle_new_auth_user() from public, anon, authenticated;
revoke execute on function public.enforce_case_fact_requirement_confirmed() from public, anon, authenticated;
grant execute on function public.handle_new_auth_user() to service_role;
grant execute on function public.enforce_case_fact_requirement_confirmed() to service_role;

-- ---------------------------------------------------------------------------
-- 6. Production triggers
-- ---------------------------------------------------------------------------
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create trigger case_facts_require_confirmed_requirement
  before insert on public.case_facts
  for each row execute function public.enforce_case_fact_requirement_confirmed();

-- ---------------------------------------------------------------------------
-- 7. Production table grants (RLS is the row gate; case_facts writes are
--    additionally revoked from authenticated at the privilege level).
-- ---------------------------------------------------------------------------
grant all on all tables in schema public to anon, authenticated, service_role;
revoke insert, update, delete on public.case_facts from authenticated;

-- ---------------------------------------------------------------------------
-- 8. Production RLS
-- ---------------------------------------------------------------------------
alter table public.workspaces enable row level security;
alter table public.users enable row level security;
alter table public.workspace_members enable row level security;
alter table public.intake_documents enable row level security;
alter table public.requirements enable row level security;
alter table public.case_facts enable row level security;
alter table public.clarification_questions enable row level security;
alter table public.tasks enable row level security;
alter table public.task_checklist_items enable row level security;
alter table public.reminders enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;

create policy workspaces_select_members on public.workspaces
  for select to authenticated using (public.is_workspace_member(id));
create policy workspaces_insert_any_authenticated on public.workspaces
  for insert to authenticated with check (auth.uid() is not null);
create policy workspaces_update_admins on public.workspaces
  for update to authenticated using (public.is_workspace_admin(id)) with check (public.is_workspace_admin(id));
create policy workspaces_delete_admins on public.workspaces
  for delete to authenticated using (public.is_workspace_admin(id));

create policy users_select_self_or_workspace_peers on public.users
  for select to authenticated using (
    id = auth.uid()
    or exists (
      select 1
      from public.workspace_members mine
      join public.workspace_members theirs on theirs.workspace_id = mine.workspace_id
      where mine.user_id = auth.uid() and theirs.user_id = users.id
    )
  );
create policy users_update_self on public.users
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy workspace_members_select_peers on public.workspace_members
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy workspace_members_insert_admin_or_bootstrap on public.workspace_members
  for insert to authenticated with check (
    public.is_workspace_admin(workspace_id)
    or (
      user_id = auth.uid()
      and not exists (
        select 1 from public.workspace_members m
        where m.workspace_id = workspace_members.workspace_id
      )
    )
  );
create policy workspace_members_update_admins on public.workspace_members
  for update to authenticated using (public.is_workspace_admin(workspace_id)) with check (public.is_workspace_admin(workspace_id));
create policy workspace_members_delete_admins_or_self on public.workspace_members
  for delete to authenticated using (public.is_workspace_admin(workspace_id) or user_id = auth.uid());

create policy intake_documents_select_members on public.intake_documents
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy intake_documents_insert_members on public.intake_documents
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy intake_documents_update_members on public.intake_documents
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy intake_documents_delete_members on public.intake_documents
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy requirements_select_members on public.requirements
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy requirements_insert_members on public.requirements
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy requirements_update_members on public.requirements
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy requirements_delete_members on public.requirements
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy case_facts_select_members on public.case_facts
  for select to authenticated using (public.is_workspace_member(workspace_id));

create policy clarification_questions_select_members on public.clarification_questions
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy clarification_questions_insert_members on public.clarification_questions
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy clarification_questions_update_members on public.clarification_questions
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy clarification_questions_delete_members on public.clarification_questions
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy tasks_select_members on public.tasks
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy tasks_insert_members on public.tasks
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy tasks_update_members on public.tasks
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy tasks_delete_members on public.tasks
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy task_checklist_items_select_members on public.task_checklist_items
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy task_checklist_items_insert_members on public.task_checklist_items
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy task_checklist_items_update_members on public.task_checklist_items
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy task_checklist_items_delete_members on public.task_checklist_items
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy reminders_select_members on public.reminders
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy reminders_insert_members on public.reminders
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy reminders_update_members on public.reminders
  for update to authenticated using (public.is_workspace_member(workspace_id)) with check (public.is_workspace_member(workspace_id));
create policy reminders_delete_members on public.reminders
  for delete to authenticated using (public.is_workspace_member(workspace_id));

create policy notifications_select_recipient on public.notifications
  for select to authenticated using (user_id = auth.uid());
create policy notifications_insert_members on public.notifications
  for insert to authenticated with check (public.is_workspace_member(workspace_id));
create policy notifications_update_recipient on public.notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_delete_recipient on public.notifications
  for delete to authenticated using (user_id = auth.uid());

create policy notification_preferences_select_owner on public.notification_preferences
  for select to authenticated using (user_id = auth.uid());
create policy notification_preferences_insert_owner on public.notification_preferences
  for insert to authenticated with check (user_id = auth.uid() and public.is_workspace_member(workspace_id));
create policy notification_preferences_update_owner on public.notification_preferences
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notification_preferences_delete_owner on public.notification_preferences
  for delete to authenticated using (user_id = auth.uid());

-- ============================================================================
-- End of baseline. The only deployable change from Phase 2 is the migration
-- in supabase/migrations/ — production must never execute this file.
-- ============================================================================
