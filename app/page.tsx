import { Suspense } from "react";
import { getCurrentUser } from "@/lib/auth";
import { signOut } from "./actions";

const ROLE_LABELS: Record<string, string> = {
  ADMINISTRATOR: "Administrator",
  MANAGER: "Manager",
  ATTENDANT: "Attendant",
};

export default function HomePage() {
  return (
    <main className="mx-auto flex w-full max-w-3xl flex-1 flex-col gap-6 px-4 py-8">
      <header className="flex items-center justify-between gap-4">
        <h1 className="text-xl font-semibold">Fuel ERP</h1>
        <Suspense>
          <SignedInAs />
        </Suspense>
      </header>
    </main>
  );
}

async function SignedInAs() {
  const user = await getCurrentUser();
  return (
    <div className="flex items-center gap-4 text-sm">
      <span>
        Signed in as {user.firstName} {user.lastName}, {ROLE_LABELS[user.role] ?? user.role}
      </span>
      <form action={signOut}>
        <button type="submit" className="rounded-md border border-foreground/20 px-3 py-1.5">
          Sign out
        </button>
      </form>
    </div>
  );
}
