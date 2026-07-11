/**
 * Server-side Supabase client (current official @supabase/ssr pattern).
 *
 * Only the public URL and publishable key are used here (no admin credentials).
 * All data access runs through RLS as the authenticated user (see ADR 0002).
 */

import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import type { Database } from "./database.types";

export async function createSupabaseServerClient() {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    requireEnv("NEXT_PUBLIC_SUPABASE_URL"),
    requireEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component where cookies are read-only;
            // session refresh is handled by the route handlers.
          }
        },
      },
    },
  );
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}
