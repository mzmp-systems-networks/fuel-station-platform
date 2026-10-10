"use client";

import { Suspense, useActionState } from "react";
import { useSearchParams } from "next/navigation";
import { signIn, type SignInState } from "./actions";

export function LoginForm() {
  const [state, formAction, pending] = useActionState<SignInState, FormData>(signIn, {});

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <label className="flex flex-col gap-1 text-sm font-medium">
        Email
        <input
          name="email"
          type="email"
          autoComplete="email"
          required
          className="rounded-md border border-foreground/20 bg-transparent px-3 py-2 font-normal"
        />
      </label>
      <label className="flex flex-col gap-1 text-sm font-medium">
        Password
        <input
          name="password"
          type="password"
          autoComplete="current-password"
          required
          className="rounded-md border border-foreground/20 bg-transparent px-3 py-2 font-normal"
        />
      </label>
      {state.error ? (
        <ErrorMessage text={state.error} />
      ) : (
        <Suspense>
          <NoAccessMessage />
        </Suspense>
      )}
      <button
        type="submit"
        disabled={pending}
        className="rounded-md bg-foreground px-3 py-2 font-medium text-background disabled:opacity-60"
      >
        {pending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}

// Shown after a protected page turned the person away (see lib/auth.ts).
function NoAccessMessage() {
  const noAccess = useSearchParams().get("error") === "no-access";
  return noAccess ? (
    <ErrorMessage text="Your session has ended or you do not have access. Sign in again." />
  ) : null;
}

function ErrorMessage({ text }: { text: string }) {
  return (
    <p role="alert" className="text-sm text-red-600">
      {text}
    </p>
  );
}
