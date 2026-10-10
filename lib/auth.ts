import "server-only";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { createClient } from "@/lib/supabase/server";

export type CurrentUser = {
  id: string;
  firstName: string;
  lastName: string;
  role: string;
};

type Supabase = Awaited<ReturnType<typeof createClient>>;

// The access rule (docs/sprint-1/application-user-model.md, section 4): a valid
// session, linked to exactly one application user, whose status is ACTIVE.
// Returns that user, or null when the request is not authorized.
export async function findAuthorizedUser(supabase: Supabase): Promise<CurrentUser | null> {
  const { data: auth } = await supabase.auth.getClaims();
  if (!auth?.claims) return null;

  const { data: user } = await supabase
    .from("users")
    .select("id, first_name, last_name, role, status")
    .eq("auth_user_id", auth.claims.sub)
    .maybeSingle();
  if (!user || user.status !== "ACTIVE") return null;

  return { id: user.id, firstName: user.first_name, lastName: user.last_name, role: user.role };
}

// For protected pages: the current user, or a redirect to the login page.
export async function getCurrentUser(): Promise<CurrentUser> {
  // Access is decided per request (status changes apply immediately), never prerendered.
  await connection();
  const supabase = await createClient();
  const user = await findAuthorizedUser(supabase);
  if (!user) redirect("/login?error=no-access");
  return user;
}
