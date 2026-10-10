# Fuel ERP

Records, reconciliation, and reporting for fuel stations.

Stack (MVP): Next.js + React on Vercel, Supabase (Postgres + Auth).

Work is delivered sprint by sprint, story by story. Design notes live in [docs/](docs/).

## Running the app

Needs Node (see [.nvmrc](.nvmrc)). Install dependencies once:

```sh
npm install
```

The app reads its Supabase settings from env files (names in [.env.example](.env.example)). During `npm run dev`, `.env.development.local` overrides `.env.local`, so:

- `.env.local` holds the **hosted** project's settings (Dashboard → Project Settings → API).
- `.env.development.local`, when present, points `npm run dev` at the **local** Supabase.

### Option A: local Supabase (hosted database untouched)

Needs Docker running.

1. Start the local database and apply all migrations:

   ```sh
   npx supabase start
   npx supabase db reset
   npx supabase status       # shows the API URL and the publishable key
   ```

2. Create `.env.development.local`:

   ```
   NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=<publishable key from supabase status>
   ```

3. Create a test administrator in Studio (http://127.0.0.1:54323):
   - **Authentication → Users → Add user → Create new user**: e.g. `admin@example.com`, any password, tick **Auto Confirm User**.
   - **SQL Editor**: link that login to an application user:

     ```sql
     insert into public.users (email, first_name, last_name, role, status, auth_user_id)
     select email, 'Test', 'Admin', 'ADMINISTRATOR', 'ACTIVE', id
     from auth.users where email = 'admin@example.com';
     ```

   `db reset` wipes this user, so repeat this step after every reset.

4. Start the app:

   ```sh
   npm run dev               # http://localhost:3000
   ```

When done: `npx supabase stop`. Delete `.env.development.local` to switch `npm run dev` back to the hosted project.

### Option B: hosted Supabase

1. Fill in `.env.local` from `.env.example` with the hosted project's settings, and make sure `.env.development.local` does not exist.

2. Apply any pending migrations to the hosted database:

   ```sh
   npx supabase link --project-ref <ref>   # once per machine
   npx supabase db push
   ```

3. Start the app and sign in with a hosted administrator account:

   ```sh
   npm run dev               # http://localhost:3000
   ```

## Database

Schema changes are versioned SQL migrations in [supabase/migrations/](supabase/migrations/), applied with the Supabase CLI (`npx supabase`).

```sh
npx supabase db start     # local Postgres (needs Docker)
npx supabase db reset     # re-apply all migrations locally
npx supabase test db      # run the tests in supabase/tests/
npx supabase link --project-ref <ref>
npx supabase db push      # apply pending migrations to the hosted database
```
