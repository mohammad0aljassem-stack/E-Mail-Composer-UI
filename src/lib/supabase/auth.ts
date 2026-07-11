/**
 * Session boundary for API routes.
 *
 * Identity comes exclusively from the verified Supabase session: getClaims()
 * validates the JWT (signature-checked) instead of trusting an unvalidated
 * getSession() payload or any client-supplied user ID.
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import { createSupabaseServerClient } from "./server";
import type { Database } from "./database.types";

export interface AuthenticatedContext {
  supabase: SupabaseClient<Database>;
  userId: string;
}

export type AuthResult =
  | { ok: true; context: AuthenticatedContext }
  | { ok: false; status: 401; code: "unauthorized"; message: string };

export async function requireAuthenticatedUser(): Promise<AuthResult> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.auth.getClaims();
  const sub = data?.claims?.sub;
  if (error || typeof sub !== "string" || sub.length === 0) {
    return {
      ok: false,
      status: 401,
      code: "unauthorized",
      message: "A valid session is required.",
    };
  }
  return {
    ok: true,
    context: { supabase: supabase as SupabaseClient<Database>, userId: sub },
  };
}
