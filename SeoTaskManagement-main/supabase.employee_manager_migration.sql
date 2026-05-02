-- Run this after the original schema. It upgrades Student terminology/workflow
-- to Admin -> Manager -> Employee with weekly task progress and payments.

-- Safety guard: abort early with a clear message if base schema hasn't been
-- applied (prevents the confusing "relation \"public.profiles\" does not
-- exist" runtime error). Run `supabase.schema.sql` first if you see this.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles'
  ) THEN
    RAISE NOTICE 'Table public.profiles not found. Profile-related changes will be skipped. Run supabase.schema.sql to apply the base schema if you want the full migration.';
  END IF;
END
$$;
-- Profile-related changes: run only when `public.profiles` exists.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
    EXECUTE 'alter table public.profiles drop constraint if exists profiles_role_check';
    EXECUTE 'alter table public.profiles add constraint profiles_role_check check (role in (''admin'', ''manager'', ''employee'', ''student''))';
    EXECUTE 'update public.profiles set role = ''employee'' where role = ''student''';
    EXECUTE 'alter table public.profiles drop constraint if exists profiles_status_check';
    EXECUTE 'alter table public.profiles add constraint profiles_status_check check (status in (''pending'', ''approved'', ''rejected'', ''inactive''))';
  ELSE
    RAISE NOTICE 'Skipping profile updates: public.profiles not present';
  END IF;
END
$$;

-- Tasks: add non-FK columns when `public.tasks` exists; add FK columns only if both `tasks` and `profiles` exist.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks') THEN
    EXECUTE '
      alter table public.tasks
        add column if not exists payment_amount numeric default 0,
        add column if not exists payment_status text default ''pending'',
        add column if not exists week_start date,
        add column if not exists week_end date,
        add column if not exists progress_percent numeric default 0,
        add column if not exists final_forwarded_to_admin boolean default false,
        add column if not exists manager_remarks text,
        add column if not exists manager_reviewed_at timestamp,
        add column if not exists admin_remarks text,
        add column if not exists admin_reviewed_at timestamp,
        add column if not exists revision_notes text,
        add column if not exists revision_due_at timestamp,
        add column if not exists revision_requested_at timestamp,
        add column if not exists manager_forward_summary text';
  ELSE
    RAISE NOTICE 'Skipping task column additions: public.tasks not present';
  END IF;
END
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks')
     AND EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
    EXECUTE '
      alter table public.tasks
        add column if not exists assigned_by uuid references public.profiles(id) on delete set null,
        add column if not exists manager_id uuid references public.profiles(id) on delete set null,
        add column if not exists revision_requested_by uuid references public.profiles(id) on delete set null';
  ELSE
    RAISE NOTICE 'Skipping task FK column additions: public.tasks or public.profiles not present';
  END IF;
END
$$;

-- Tasks payment status constraint
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks') THEN
    EXECUTE 'alter table public.tasks drop constraint if exists tasks_payment_status_check';
    EXECUTE 'alter table public.tasks add constraint tasks_payment_status_check check (payment_status in (''pending'', ''released''))';
  ELSE
    RAISE NOTICE 'Skipping tasks payment_status constraint: public.tasks not present';
  END IF;
END
$$;

-- Create task_progress_updates table
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'task_progress_updates') THEN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks')
       AND EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
      EXECUTE '
        create table if not exists public.task_progress_updates (
          id uuid primary key default gen_random_uuid(),
          task_id uuid references public.tasks(id) on delete cascade,
          employee_id uuid references public.profiles(id) on delete cascade,
          progress_percent numeric default 0 check (progress_percent >= 0 and progress_percent <= 100),
          notes text,
          update_date date default current_date,
          created_at timestamptz default now()
        )';
    ELSE
      RAISE NOTICE 'Skipping task_progress_updates: public.tasks or public.profiles not present';
    END IF;
  END IF;
END
$$;

-- Create payments table
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'payments') THEN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks')
       AND EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
      EXECUTE '
        create table if not exists public.payments (
          id uuid primary key default gen_random_uuid(),
          task_id uuid references public.tasks(id) on delete cascade,
          employee_id uuid references public.profiles(id) on delete cascade,
          released_by uuid references public.profiles(id) on delete set null,
          amount numeric default 0,
          method text,
          transaction_number text,
          screenshot_url text,
          status text default ''released'',
          released_at timestamptz default now()
        )';
    ELSE
      RAISE NOTICE 'Skipping payments: public.tasks or public.profiles not present';
    END IF;
  END IF;
END
$$;

-- Create attendance_records table
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'attendance_records') THEN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
      EXECUTE '
        create table if not exists public.attendance_records (
          id uuid primary key default gen_random_uuid(),
          employee_id uuid references public.profiles(id) on delete cascade,
          attendance_date date not null default current_date,
          check_in_at timestamptz,
          check_out_at timestamptz,
          work_minutes integer default 0 check (work_minutes >= 0),
          status text default ''present'' check (status in (''present'', ''late'', ''absent'')),
          notes text,
          created_at timestamptz default now(),
          updated_at timestamptz default now(),
          unique (employee_id, attendance_date)
        )';
    ELSE
      RAISE NOTICE 'Skipping attendance_records: public.profiles not present';
    END IF;
  END IF;
END
$$;

-- Enable RLS for new tables if they exist
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'task_progress_updates') THEN
    EXECUTE 'alter table public.task_progress_updates enable row level security';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'payments') THEN
    EXECUTE 'alter table public.payments enable row level security';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'attendance_records') THEN
    EXECUTE 'alter table public.attendance_records enable row level security';
  END IF;
END
$$;

-- Create/replace functions that reference profiles
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
    EXECUTE '
      create or replace function public.is_admin()
      returns boolean
      language sql
      security definer
      set search_path = public
      as $$
        select exists (
          select 1 from public.profiles
          where id = auth.uid() and role = ''admin'' and status = ''approved''
        );
      $$';

    EXECUTE '
      create or replace function public.is_manager()
      returns boolean
      language sql
      security definer
      set search_path = public
      as $$
        select exists (
          select 1 from public.profiles
          where id = auth.uid() and role = ''manager'' and status = ''approved''
        );
      $$';
  ELSE
    RAISE NOTICE 'Skipping function creation: public.profiles not present';
  END IF;
END
$$;

-- Policies for profiles table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
    EXECUTE 'drop policy if exists "profiles read own or admin" on public.profiles';
    EXECUTE 'create policy "profiles read own admin manager" on public.profiles for select using (id = auth.uid() or public.is_admin() or public.is_manager())';
    EXECUTE 'drop policy if exists "profiles update own basic or admin" on public.profiles';
    EXECUTE 'create policy "profiles update own admin manager" on public.profiles for update using (id = auth.uid() or public.is_admin() or public.is_manager()) with check (id = auth.uid() or public.is_admin() or public.is_manager())';
  END IF;
END
$$;

-- Policies for projects table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'projects') THEN
    EXECUTE 'drop policy if exists "projects read approved or admin" on public.projects';
    EXECUTE 'create policy "projects read approved users" on public.projects for select using (public.is_admin() or public.is_manager() or exists (select 1 from public.profiles where id = auth.uid() and status = ''approved''))';
    EXECUTE 'drop policy if exists "projects admin write" on public.projects';
    EXECUTE 'create policy "projects admin write" on public.projects for all using (public.is_admin()) with check (public.is_admin())';
  END IF;
END
$$;

-- Policies for tasks table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'tasks') THEN
    EXECUTE 'drop policy if exists "tasks read own or admin" on public.tasks';
    EXECUTE 'create policy "tasks read assigned chain" on public.tasks for select using (public.is_admin() or manager_id = auth.uid() or student_id = auth.uid())';
    EXECUTE 'drop policy if exists "tasks admin write" on public.tasks';
    EXECUTE 'create policy "tasks admin manager insert update" on public.tasks for all using (public.is_admin() or (public.is_manager() and assigned_by = auth.uid()) or (public.is_manager() and manager_id = auth.uid())) with check (public.is_admin() or (public.is_manager() and assigned_by = auth.uid() and manager_id = auth.uid() and student_id is not null))';
    EXECUTE 'drop policy if exists "tasks student start own" on public.tasks';
    EXECUTE 'create policy "tasks employee update own progress" on public.tasks for update using (student_id = auth.uid()) with check (student_id = auth.uid())';
  END IF;
END
$$;

-- Policies for task_progress_updates table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'task_progress_updates') THEN
    EXECUTE 'drop policy if exists "progress read assigned chain" on public.task_progress_updates';
    EXECUTE 'create policy "progress read assigned chain" on public.task_progress_updates for select using (public.is_admin() or employee_id = auth.uid() or exists (select 1 from public.tasks where tasks.id = task_progress_updates.task_id and tasks.manager_id = auth.uid()))';
    EXECUTE 'drop policy if exists "progress employee insert own" on public.task_progress_updates';
    EXECUTE 'create policy "progress employee insert own" on public.task_progress_updates for insert with check (employee_id = auth.uid())';
  END IF;
END
$$;

-- Policies for payments table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'payments') THEN
    EXECUTE 'drop policy if exists "payments read assigned chain" on public.payments';
    EXECUTE 'create policy "payments read assigned chain" on public.payments for select using (public.is_admin() or employee_id = auth.uid() or exists (select 1 from public.tasks where tasks.id = payments.task_id and tasks.manager_id = auth.uid()))';
    EXECUTE 'drop policy if exists "payments admin write" on public.payments';
    EXECUTE 'create policy "payments admin write" on public.payments for all using (public.is_admin()) with check (public.is_admin())';
  END IF;
END
$$;

-- Policies for attendance_records table
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'attendance_records') THEN
    EXECUTE 'drop policy if exists "attendance read assigned chain" on public.attendance_records';
    EXECUTE 'create policy "attendance read assigned chain" on public.attendance_records for select using (public.is_admin() or employee_id = auth.uid() or exists (select 1 from public.tasks where tasks.student_id = attendance_records.employee_id and (tasks.manager_id = auth.uid() or tasks.assigned_by = auth.uid())))';
    EXECUTE 'drop policy if exists "attendance employee insert own" on public.attendance_records';
    EXECUTE 'create policy "attendance employee insert own" on public.attendance_records for insert with check (employee_id = auth.uid() or public.is_admin())';
    EXECUTE 'drop policy if exists "attendance employee update own" on public.attendance_records';
    EXECUTE 'create policy "attendance employee update own" on public.attendance_records for update using (employee_id = auth.uid() or public.is_admin()) with check (employee_id = auth.uid() or public.is_admin())';
  END IF;
END
$$;

-- Storage bucket and policies
DO $$
BEGIN
  EXECUTE 'insert into storage.buckets (id, name, public, file_size_limit) values (''payment-proofs'', ''payment-proofs'', true, 102400) on conflict (id) do update set file_size_limit = 102400, public = true';
  EXECUTE 'drop policy if exists "payment proofs admin upload" on storage.objects';
  EXECUTE 'create policy "payment proofs admin upload" on storage.objects for insert with check (bucket_id = ''payment-proofs'' and public.is_admin())';
  EXECUTE 'drop policy if exists "payment proofs public read" on storage.objects';
  EXECUTE 'create policy "payment proofs public read" on storage.objects for select using (bucket_id = ''payment-proofs'')';
END
$$;
