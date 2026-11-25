#!/usr/bin/env python3
"""Turn data/starter.local.json into SQL for the Supabase SQL editor (runs as postgres).
Every row is owned by the project's only user. Output: data/seed.local.sql (gitignored)."""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
d = json.loads((root / "data/starter.local.json").read_text())

COLS = {
    "accounts": ["id", "institution", "name", "mask", "kind", "scope", "balance", "available", "credit_limit", "pending",
                 "statement_balance", "statement_date", "close_day", "due_day", "autopay", "rewards", "as_of", "note", "sort"],
    "transactions": ["account_id", "date", "merchant", "category", "amount", "pending", "source"],
    "bills": ["name", "amount", "amount_max", "cadence", "day", "month", "weekday", "interval_days", "start_date",
              "pay_from", "scope", "kind", "match", "note"],
    "syncs": ["at", "sources", "missing", "note"],
    "funds": ["id", "name", "monthly_per_person", "start_month", "end_month", "goal", "held_in", "note"],
    "fund_members": ["id", "fund_id", "name", "monthly", "sort"],
    "fund_entries": ["id", "fund_id", "member_id", "kind", "month", "amount", "on_date", "note"],
}
SRC = {"fund_members": "members", "fund_entries": "entries"}

def lit(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, list): return "array[" + ",".join(lit(x) for x in v) + "]::text[]" if v else "'{}'::text[]"
    return "'" + str(v).replace("'", "''") + "'"

out = ["-- Starter data. Run once in the SQL editor after the owner's account exists.",
       "do $$ begin if (select count(*) from auth.users) <> 1 then raise exception 'expected exactly one user'; end if; end $$;",
       "begin;", "create temp table me on commit drop as select id from auth.users;"]
for table, cols in COLS.items():
    rows = d.get(SRC.get(table, table), [])
    if not rows: continue
    if table == "accounts":
        sorted_ids = None
    vals = []
    for r in rows:
        vals.append("(" + ",".join([lit(r.get(c)) for c in cols] + ["(select id from me)"]) + ")")
    out.append(f"insert into public.{table} ({','.join(cols)},owner) values\n  " + ",\n  ".join(vals) + ";")
for t in ("funds", "fund_members", "fund_entries"):
    out.append(f"select setval(pg_get_serial_sequence('public.{t}','id'), (select max(id) from public.{t}));")
out.append("commit;")
out.append("select (select count(*) from public.accounts) accounts, (select count(*) from public.bills) bills, "
           "(select count(*) from public.fund_entries) fund_entries, (select count(distinct owner) from public.bills) owners;")
p = root / "data/seed.local.sql"
p.write_text("\n".join(out) + "\n")
print(p, len(p.read_text()), "chars")
