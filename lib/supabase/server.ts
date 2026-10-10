import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

// Supabase client for Server Components, Server Actions and Route Handlers.
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // Server Components cannot set cookies. The proxy refreshes the
            // session on every request, so this is safe to ignore.
          }
        },
      },
    },
  );
}
