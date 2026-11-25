-- Money: Santiago's finances app. Personal tables are owner-only; funds are read by their members.
-- Apply in the Supabase SQL editor of the Money project.

create table if not exists public.accounts (
  id               text primary key,                 -- e.g. 'vx-3195', 'chase-8677'
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
  autopay          text,                             -- e.g. 'minimum from Capital One ..4715'
  rewards          text,                             -- e.g. '118,433 miles'
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
  source      text,                                  -- 'capitalone', 'chase', 'plaid'
  seen_at     timestamptz not null default now(),
  unique (account_id, date, merchant, amount, pending)
);
create index if not exists transactions_account_date on public.transactions (account_id, date desc);

create table if not exists public.bills (
  id            bigserial primary key,
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name          text not null,
  amount        numeric,                             -- null = unknown (e.g. a card minimum not read yet)
  amount_max    numeric,                             -- for a range like AT&T ~$314-401
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
  missing   text[] not null default '{}',            -- e.g. '{discover,robinhood}' when not signed in
  note      text
);

-- Funds (Marriage Fund, Emergency Fund): everyone puts in a set amount each month.
create table if not exists public.funds (
  id                  bigserial primary key,
  owner               uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name                text not null,
  monthly_per_person  numeric not null default 100,
  start_month         date not null,                 -- first day of the first month
  goal                numeric,
  held_in             text,                          -- where the money sits, in words
  note                text
);

create table if not exists public.fund_members (
  id       bigserial primary key,
  fund_id  bigint not null references public.funds(id) on delete cascade,
  name     text not null,
  email    text,                                     -- lets that person sign in and see this fund
  monthly  numeric,                                  -- overrides the fund's amount for this person
  sort     int not null default 100,
  unique (fund_id, name)
);

create table if not exists public.fund_entries (
  id          bigserial primary key,
  fund_id     bigint not null references public.funds(id) on delete cascade,
  member_id   bigint references public.fund_members(id) on delete set null,
  kind        text not null default 'deposit' check (kind in ('deposit','withdrawal')),
  month       date,                                  -- which month a deposit counts for
  amount      numeric not null check (amount > 0),
  on_date     date not null default current_date,
  note        text,
  recorded_by uuid default auth.uid()
);

-- Row-level security
alter table public.accounts     enable row level security;
alter table public.transactions enable row level security;
alter table public.bills        enable row level security;
alter table public.syncs        enable row level security;
alter table public.funds        enable row level security;
alter table public.fund_members enable row level security;
alter table public.fund_entries enable row level security;

create policy own_accounts     on public.accounts     for all using (owner = auth.uid()) with check (owner = auth.uid());
create policy own_transactions on public.transactions for all using (owner = auth.uid()) with check (owner = auth.uid());
create policy own_bills        on public.bills        for all using (owner = auth.uid()) with check (owner = auth.uid());
create policy own_syncs        on public.syncs        for all using (owner = auth.uid()) with check (owner = auth.uid());

-- A fund is visible to its owner and to any member whose email matches the signed-in user.
create or replace function public.is_fund_member(f bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.fund_members m
    where m.fund_id = f and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) or exists (select 1 from public.funds x where x.id = f and x.owner = auth.uid());
$$;
revoke all on function public.is_fund_member(bigint) from public;
grant execute on function public.is_fund_member(bigint) to authenticated;

create policy read_funds   on public.funds        for select using (public.is_fund_member(id));
create policy write_funds  on public.funds        for all    using (owner = auth.uid()) with check (owner = auth.uid());
create policy read_members on public.fund_members for select using (public.is_fund_member(fund_id));
create policy write_members on public.fund_members for all
  using (exists (select 1 from public.funds x where x.id = fund_id and x.owner = auth.uid()))
  with check (exists (select 1 from public.funds x where x.id = fund_id and x.owner = auth.uid()));
create policy read_entries on public.fund_entries for select using (public.is_fund_member(fund_id));
create policy write_entries on public.fund_entries for all
  using (exists (select 1 from public.funds x where x.id = fund_id and x.owner = auth.uid()))
  with check (exists (select 1 from public.funds x where x.id = fund_id and x.owner = auth.uid()));
-- A member may record their own deposit (it shows as theirs; the owner can still fix or delete it).
create policy member_deposit on public.fund_entries for insert with check (
  kind = 'deposit' and exists (
    select 1 from public.fund_members m
    where m.id = member_id and m.fund_id = fund_entries.fund_id
      and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
);
