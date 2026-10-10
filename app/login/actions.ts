"use server";

import { redirect } from "next/navigation";
import { findAuthorizedUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export type SignInState = { error?: string };

export async function signIn(_prev: SignInState, formData: FormData): Promise<SignInState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "Enter your email and password." };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) return { error: "Invalid email or password." };

  // A valid login is not enough: it must belong to an active Fuel ERP user.
  if (!(await findAuthorizedUser(supabase))) {
    await supabase.auth.signOut();
    return { error: "This account does not have access to Fuel ERP." };
  }

  redirect("/");
}
