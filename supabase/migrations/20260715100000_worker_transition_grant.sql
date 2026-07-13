-- ============================================================================
-- Phase 3A transport — worker transition-validator EXECUTE grant
--
-- Additive, idempotent, corrective migration. Applied AFTER the Phase 2 chain
-- and the Phase 3A transport foundation (20260713100000) + contract hardening
-- (20260714100000). Timestamp sorts strictly after 20260714100000.
--
-- WHY THIS GRANT IS REQUIRED
-- --------------------------
-- `transport_worker` is the least-privilege system role that drives the
-- outbound state machine by issuing `UPDATE public.send_attempts` (it has
-- exactly SELECT,UPDATE on that table — see the foundation). Every such UPDATE
-- fires the BEFORE UPDATE trigger `public.phase3_send_attempts_before_update()`,
-- which is declared `SECURITY INVOKER`. An INVOKER trigger executes with the
-- privileges of the CALLING role — here, `transport_worker` — not the trigger
-- owner. Inside that trigger the guard calls the authoritative transition-table
-- validator `public.phase3_send_attempt_transition_ok(text, text)` to decide
-- whether the state change is legal.
--
-- The foundation migration (20260713100000) REVOKED EXECUTE on that validator
-- from public/anon/authenticated and granted it ONLY to `service_role`. So a
-- least-privilege production `transport_worker` can UPDATE send_attempts, but
-- the INVOKER trigger's call to the validator fails with `permission denied for
-- function phase3_send_attempt_transition_ok` — every legal worker transition
-- is blocked. This migration closes that gap in the CANONICAL schema by
-- granting the worker EXECUTE on exactly that one validator, additively.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * It does NOT grant EXECUTE to public/anon/authenticated (browser roles
--     never touch send_attempts; their revoke from the foundation stands).
--   * It does NOT add any table or schema privilege, and does NOT grant broad
--     EXECUTE on all functions.
--   * It does NOT create/alter any role and adds no login/password.
--   * It does NOT convert the validator or the trigger to SECURITY DEFINER.
--     The trigger stays SECURITY INVOKER with an empty search_path and
--     fully-qualified calls; the authoritative transition table, terminal-state
--     protection, version-rollback protection, and workspace/intent
--     immutability all remain exactly as the foundation defined them. The ONLY
--     change is that the calling worker role may now execute the validator the
--     INVOKER trigger already invokes on its behalf.
--
-- Idempotent: GRANT (and the defensive REVOKE below) are naturally
-- re-runnable, so re-applying this migration is a harmless no-op.
-- ============================================================================

-- Defense in depth: ensure no inherited / default-ACL EXECUTE leaked to the
-- browser roles. The foundation already revoked these; this re-revoke keeps the
-- migration self-contained and strengthens the least-privilege guarantee
-- without ever re-granting to public/anon/authenticated. (revoke-then-grant
-- style, matching the rest of the transport schema.)
revoke execute on function public.phase3_send_attempt_transition_ok(text, text)
  from public, anon, authenticated;

-- The one privilege this migration exists to grant: the least-privilege worker
-- role may execute the transition-table validator that its own SECURITY INVOKER
-- BEFORE UPDATE trigger on public.send_attempts calls.
grant execute on function public.phase3_send_attempt_transition_ok(text, text)
  to transport_worker;

comment on function public.phase3_send_attempt_transition_ok(text, text) is
  'Phase 3A: authoritative send_attempts transition table. completed/needs_human_review/cancelled are terminal for the automated path. EXECUTE is held by service_role and transport_worker only: the send_attempts BEFORE UPDATE trigger is SECURITY INVOKER, so it calls this validator as the worker role that issued the UPDATE (grant added in 20260715100000_worker_transition_grant).';
