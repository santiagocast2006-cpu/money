-- Money: one person's finances. Every row belongs to its owner, and every read or write
-- also needs a two-step (authenticator app) session. Apply in the Supabase SQL editor.

create table if not exists public.accounts (
  id               text primary key,                 -- e.g. 'card-1234'
  owner            uuid not null default auth.uid() references auth.users(id) on delete cascade,
  institution      text not null,
  name             text not null,
  mask             text,
  kind             text not null check (kind in ('checking','savings','credit','loan','investment')),
  scope            text not null default 'personal' check (scope in ('personal','business')),
  balance          numeric,                          -- current balance (cards: amount owed)
  available        numeric,                          -- cash available / credit available
  credit_limit     numeric,
  pending          numeric not null default 0,       -- pending charges not in balance
  statement_balance numeric,
  statement_date   date,
  close_day        int check (close_day between 1 and 31),
  due_day          int check (due_day between 1 and 31),
  autopay          text,
  rewards          text,
  as_of            timestamptz,
  note             text,
  sort             int not null default 100
);

create table if not exists public.transactions (
  id          bigserial primary key,
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  account_id  text not null references public.accounts(id) on delete cascade,
  date        date not null,
  merchant    text not null,
  category    text,
  amount      numeric not null,                      -- positive = money out, negative = payment/refund in
  pending     boolean not null default false,
  source      text,
  seen_at     timestamptz not null default now(),
  unique (account_id, date, merchant, amount, pending)
);
create index if not exists transactions_account_date on public.transactions (account_id, date desc);

create table if not exists public.bills (
  id            bigserial primary key,
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name          text not null,
  amount        numeric,                             -- null = unknown (e.g. a card minimum not read yet)
  amount_max    numeric,                             -- for a range
  cadence       text not null check (cadence in ('monthly','yearly','weekly','interval','once')),
  day           int,                                 -- monthly/yearly: day of month
  month         int,                                 -- yearly: month 1-12
  weekday       int,                                 -- weekly: 0 = Sunday
  interval_days int,                                 -- interval: every N days from start_date
  start_date    date,                                -- interval / once
  pay_from      text references public.accounts(id) on delete set null,
  scope         text not null default 'personal' check (scope in ('personal','business')),
  kind          text not null default 'subscription'
                check (kind in ('subscription','bill','card_minimum','transfer','insurance','loan','payroll')),
  active        boolean not null default true,
  match         text,                                -- merchant text that marks it paid (default: first word of name)
  note          text
);

create table if not exists public.syncs (
  id        bigserial primary key,
  owner     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  at        timestamptz not null default now(),
  sources   text[] not null default '{}',
  missing   text[] not null default '{}',            -- banks not read (not signed in)
  note      text
);

-- Group savings funds: each member puts in a set amount every month, start_month to end_month.
create table if not exists public.funds (
  id                  bigserial primary key,
  owner               uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name                text not null,
  monthly_per_person  numeric not null default 100,
  start_month         date not null,                 -- first day of the first month
  end_month           date,                          -- first day of the last month (null = open-ended)
  goal                numeric,
  held_in             text,                          -- where the money sits, in words
  note                text
);

create table if not exists public.fund_members (
  id       bigserial primary key,
  owner    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fund_id  bigint not null references public.funds(id) on delete cascade,
  name     text not null,
  monthly  numeric,                                  -- overrides the fund's amount for this person
  sort     int not null default 100,
  unique (fund_id, name)
);

create table if not exists public.fund_entries (
  id          bigserial primary key,
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fund_id     bigint not null references public.funds(id) on delete cascade,
  member_id   bigint references public.fund_members(id) on delete set null,
  kind        text not null default 'deposit' check (kind in ('deposit','withdrawal')),
  month       date,                                  -- which month a deposit counts for
  amount      numeric not null check (amount > 0),
  on_date     date not null default current_date,
  note        text
);

-- Lock-down: signed out, nothing is reachable; signed in, you see only your own rows,
-- and only after the authenticator-app step (aal2).
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;

do $$
declare t text;
begin
  foreach t in array array['accounts','transactions','bills','syncs','funds','fund_members','fund_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists own_%s on public.%I', t, t);
    execute format('create policy own_%s on public.%I for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid())', t, t);
    execute format('drop policy if exists mfa_%s on public.%I', t, t);
    execute format($p$create policy mfa_%s on public.%I as restrictive for all to authenticated using ((auth.jwt() ->> 'aal') = 'aal2') with check ((auth.jwt() ->> 'aal') = 'aal2')$p$, t, t);
  end loop;
end $$;
