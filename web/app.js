// Money app: Today, Accounts, Spending, Upcoming, Calendar, Funds. Reads everything through window.Money (data.js).
(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const usd = (n, cents = true) => n == null || isNaN(n) ? "—" :
    (n < 0 ? "−" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: cents ? 2 : 0 });
  const usd0 = (n) => usd(n, false);
  const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const parse = (s) => { const [y, m, d] = String(s).slice(0, 10).split("-").map(Number); return new Date(y, m - 1, d); };
  const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
  const dim = (y, m) => new Date(y, m + 1, 0).getDate();
  const day = (d) => d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  const short = (d) => d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const today = (() => { const t = new Date(); return new Date(t.getFullYear(), t.getMonth(), t.getDate()); })();
  const monthKey = (d) => ymd(new Date(d.getFullYear(), d.getMonth(), 1));
  const ord = (n) => n + (["th", "st", "nd", "rd"][((n % 100) - 20) % 10] || ["th", "st", "nd", "rd"][n % 100] || "th");

  let S = null;        // loaded data
  let me = null;       // session
  const ui = { spendAcct: null, spendPeriod: "statement", upDays: 45, side: "personal", calMonth: null, calDay: null, calKind: "subs" };
  try { if (localStorage.getItem("money.side") === "business") ui.side = "business"; } catch {}
  try { if (localStorage.getItem("money.calKind") === "all") ui.calKind = "all"; } catch {}
  const onSide = (a) => a && a.scope === ui.side;

  // ---------- derived data ----------
  const acct = (id) => S.accounts.find((a) => a.id === id);
  const isCash = (a) => a && (a.kind === "checking" || a.kind === "savings");
  const isCard = (a) => a && a.kind === "credit";
  const acctName = (a) => a ? `${a.name}${a.mask ? " ··" + a.mask : ""}` : "Not set";
  const cashOf = (a) => Number(a.available ?? a.balance ?? 0);

  function occurrences(b, from, to) {
    const out = [];
    if (b.active === false) return out;
    if (b.cadence === "monthly" && b.day) {
      for (let y = from.getFullYear(), m = from.getMonth(); new Date(y, m, 1) <= to; m++) {
        if (m > 11) { m = 0; y++; }
        const d = new Date(y, m, Math.min(b.day, dim(y, m)));
        if (d >= from && d <= to) out.push(d);
      }
    } else if (b.cadence === "yearly" && b.month && b.day) {
      for (let y = from.getFullYear(); y <= to.getFullYear(); y++) {
        const d = new Date(y, b.month - 1, Math.min(b.day, dim(y, b.month - 1)));
        if (d >= from && d <= to) out.push(d);
      }
    } else if (b.cadence === "weekly" && b.weekday != null) {
      let d = new Date(from);
      while (d.getDay() !== b.weekday) d = addDays(d, 1);
      for (; d <= to; d = addDays(d, 7)) out.push(new Date(d));
    } else if (b.cadence === "interval" && b.interval_days && b.start_date) {
      let d = parse(b.start_date);
      if (d < from) d = addDays(d, Math.ceil((from - d) / 864e5 / b.interval_days) * b.interval_days);
      for (; d <= to; d = addDays(d, b.interval_days)) out.push(new Date(d));
    } else if (b.cadence === "once" && b.start_date) {
      const d = parse(b.start_date);
      if (d >= from && d <= to) out.push(d);
    }
    return out;
  }

  // A bill counts as paid when its account shows a charge (posted or pending) near the due date
  // whose merchant matches (bill.match, else the bill's first word) and whose amount fits.
  function paidBy(b, d) {
    // A card minimum can be paid any time in the cycle before it's due, and editor pay sometimes goes out
    // up to two weeks early; everything else lands within 5 days.
    const [back, ahead] = b.kind === "card_minimum" ? [25, 3] : b.kind === "payroll" ? [15, 5] : [5, 5];
    // A date further out can't be paid yet, except editor pay or a card minimum that already went out early.
    if (!b.pay_from || d > addDays(today, b.kind === "payroll" || b.kind === "card_minimum" ? back : 3)) return null;
    const word = (b.match || b.name.split(/[\s(]/)[0]).toLowerCase();
    const near = S.transactions.filter((t) => t.account_id === b.pay_from && Number(t.amount) > 0
      && (parse(String(t.date).slice(0, 10)) - d) / 864e5 >= -back && (parse(String(t.date).slice(0, 10)) - d) / 864e5 <= ahead
      && String(t.merchant).toLowerCase().includes(word));
    if (!near.length) return null;
    const lo = b.amount != null ? Number(b.amount) * 0.8 : 0;
    // A card minimum is met by any payment at least that size.
    const hi = b.kind === "card_minimum" || b.amount == null ? Infinity : Number(b.amount_max ?? b.amount) * 1.2;
    const one = near.find((t) => Number(t.amount) >= lo && Number(t.amount) <= hi);
    if (one) return one;
    // Some arrive split (editor pay in several sends, a plan billed in two parts): add them up.
    const total = near.reduce((s, t) => s + Number(t.amount), 0);
    if (near.length > 1 && total >= lo && total <= hi) return { ...near[0], amount: total, pending: near.some((t) => t.pending), parts: near.length };
    return null;
  }

  function upcoming(days, scope = "all") {
    const to = addDays(today, days);
    const items = [];
    for (const b of S.bills) {
      const side = acct(b.pay_from)?.scope ?? b.scope; // the paying account decides the side
      if (scope !== "all" && side !== scope) continue;
      for (const d of occurrences(b, today, to)) items.push({ date: d, bill: b, from: acct(b.pay_from), paid: paidBy(b, d) });
    }
    return items.sort((x, y) => x.date - y.date || (y.bill.amount ?? 0) - (x.bill.amount ?? 0));
  }

  // What has to come out of checking/savings (a bill charged to a card adds to the card instead).
  function cashNeed(days, scope) {
    const items = upcoming(days, scope).filter((i) => !isCard(i.from) && !i.paid);
    const known = items.filter((i) => i.bill.amount != null);
    return {
      items,
      low: known.reduce((s, i) => s + Number(i.bill.amount), 0),
      high: known.reduce((s, i) => s + Number(i.bill.amount_max ?? i.bill.amount), 0),
      unknown: items.filter((i) => i.bill.amount == null),
    };
  }

  const monthsBetween = (a, b) => (b.getFullYear() - a.getFullYear()) * 12 + (b.getMonth() - a.getMonth()) + 1;
  // Months that should be paid by the end of this month (capped at the fund's last month).
  function monthsIn(fund, asOf = today) {
    const s = parse(fund.start_month);
    const end = fund.end_month && parse(fund.end_month) < asOf ? parse(fund.end_month) : asOf;
    return Math.max(0, monthsBetween(s, end));
  }
  // Every month of the fund: start to end, or start to this month when open-ended.
  function fundMonths(fund) {
    const s = parse(fund.start_month);
    const e = fund.end_month ? parse(fund.end_month) : today;
    const out = [];
    for (let i = 0; i < monthsBetween(s, e); i++) out.push(new Date(s.getFullYear(), s.getMonth() + i, 1));
    return out;
  }

  function fundState(f) {
    const members = S.members.filter((m) => m.fund_id === f.id).sort((a, b) => (a.sort ?? 100) - (b.sort ?? 100) || a.name.localeCompare(b.name));
    const entries = S.entries.filter((e) => e.fund_id === f.id);
    const deposits = entries.filter((e) => e.kind === "deposit");
    const out = entries.filter((e) => e.kind === "withdrawal").reduce((s, e) => s + Number(e.amount), 0);
    const months = monthsIn(f);
    const key = monthKey(today);
    const per = (m) => Number(m.monthly ?? f.monthly_per_person);
    const rows = members.map((m) => {
      const mine = deposits.filter((e) => e.member_id === m.id);
      const paid = mine.reduce((s, e) => s + Number(e.amount), 0);
      const thisMonth = mine.filter((e) => String(e.month).slice(0, 10) === key).reduce((s, e) => s + Number(e.amount), 0);
      const byMonth = new Map();
      for (const e of mine) { const k = String(e.month ?? e.on_date).slice(0, 7); byMonth.set(k, (byMonth.get(k) || 0) + Number(e.amount)); }
      return { m, per: per(m), paid, thisMonth, byMonth, owes: Math.max(0, per(m) * months - paid) };
    });
    const put = deposits.reduce((s, e) => s + Number(e.amount), 0);
    const expected = rows.reduce((s, r) => s + r.per * months, 0) - out;
    const all = fundMonths(f);
    const goal = f.goal ?? (f.end_month ? rows.reduce((s, r) => s + r.per, 0) * all.length : null);
    return { members, rows, entries, months, all, goal, key, expected, actual: put - out, out, monthlyTotal: rows.reduce((s, r) => s + r.per, 0) };
  }

  // ---------- views ----------
  function viewHome() {
    const side = ui.side, biz = side === "business";
    const cash = S.accounts.filter((a) => isCash(a) && onSide(a));
    const total = cash.reduce((s, a) => s + cashOf(a), 0);
    const need = cashNeed(14, side);
    const cards = S.accounts.filter((a) => isCard(a) && onSide(a));
    const owed = cards.reduce((s, a) => s + Number(a.balance ?? 0) + Number(a.pending ?? 0), 0);
    const limited = cards.filter((a) => a.credit_limit && a.balance != null);
    const limit = limited.reduce((s, a) => s + Number(a.credit_limit), 0);
    const usedOnLimited = limited.reduce((s, a) => s + Number(a.balance) + Number(a.pending ?? 0), 0);
    const known = cards.filter((a) => a.balance != null);
    const gap = total - need.high;
    const unk = need.unknown.length ? ` plus ${need.unknown.length} amount${need.unknown.length > 1 ? "s" : ""} not read yet` : "";
    const status = gap < 0 ? `<p class="status bad">Short by <span class="num">${usd(-gap)}</span> for the next 14 days${unk}.</p>`
      : need.unknown.length ? `<p class="status warn">Covered for now, with <span class="num">${usd(gap)}</span> left${unk}.</p>`
      : `<p class="status ok">Covered, with <span class="num">${usd(gap)}</span> left after the next 14 days.</p>`;
    const next = upcoming(10, side).slice(0, 8);
    const fundsHtml = biz ? "" : S.funds.map((f) => {
      const st = fundState(f);
      const behind = st.expected - st.actual;
      return `<li><span class="what"><b>${esc(f.name)}</b><small>${st.members.length} people · ${usd0(st.monthlyTotal)} a month</small></span>
        <span class="stack" style="text-align:right"><span class="amt">${usd0(st.actual)}</span>
        <small class="muted">${behind > 0 ? usd0(behind) + " behind" : st.months ? "on track" : "starts " + short(parse(f.start_month))}</small></span></li>`;
    }).join("");

    return `
    <section class="card wide" id="today-cash">
      <header><span class="label">${biz ? "Business" : "Personal"} cash</span><span class="muted" style="font-size:13px">${cash.length} account${cash.length === 1 ? "" : "s"}</span></header>
      <div class="big num">${usd(total)}</div>
      <div class="row"><span>Due from it in the next 14 days</span><span class="amt">${need.low === need.high ? usd(need.low) : usd(need.low) + "–" + usd(need.high).slice(1)}</span></div>
      ${status}
      ${need.unknown.length ? `<p class="note">Not read yet: ${need.unknown.map((i) => esc(i.bill.name) + " (" + short(i.date) + ")").join(", ")}.</p>` : ""}
    </section>

    <section class="card" id="today-next">
      <header><h2>Next 10 days</h2><a href="#upcoming" style="font-size:14px">All upcoming</a></header>
      <ul class="list">${next.map(itemLi).join("") || `<li class="muted">Nothing due.</li>`}</ul>
    </section>

    <section class="card" id="today-cards">
      <header><h2>Cards</h2><a href="#cards" style="font-size:14px">Details</a></header>
      ${cards.length ? `<div class="row"><span>Owed on ${known.length} of ${cards.length} card${cards.length === 1 ? "" : "s"}</span><span class="mid num">${usd0(owed)}</span></div>
      ${limit ? `<div class="meter ${usedOnLimited / limit > 0.9 ? "hot" : usedOnLimited / limit > 0.5 ? "mid" : ""}"><span style="width:${Math.min(100, (usedOnLimited / limit) * 100).toFixed(1)}%"></span></div>
      <small class="muted">${((usedOnLimited / limit) * 100).toFixed(0)}% used on the ${limited.length} card${limited.length > 1 ? "s" : ""} with a known limit (${usd0(limit)})</small>` : ""}
      <ul class="list">${cards.map((a) => `<li><span class="what"><span>${esc(acctName(a))}</span><small>${a.due_day ? "due the " + ord(a.due_day) : ""}${a.autopay ? " · " + esc(a.autopay) : ""}</small></span>
        <span class="amt">${a.balance == null ? `<span class="pill plain">not read</span>` : usd(Number(a.balance) + Number(a.pending ?? 0))}</span></li>`).join("")}</ul>` : `<p class="muted">No cards on this side.</p>`}
    </section>
    ${biz ? "" : `
    <section class="card" id="today-funds">
      <header><h2>Funds</h2><a href="#funds" style="font-size:14px">Open</a></header>
      <ul class="list">${fundsHtml || `<li class="muted">No funds yet.</li>`}</ul>
    </section>`}`;
  }

  function itemLi(i) {
    const b = i.bill;
    const amt = i.paid ? `<span class="pill ok">${i.paid.pending ? "pending" : "paid"} ${usd(Number(i.paid.amount))}</span>` :
      b.amount == null ? `<span class="pill warn">amount?</span>` :
      b.amount_max ? `${usd0(b.amount)}–${usd0(b.amount_max).slice(1)}` : usd(Number(b.amount));
    const where = i.from ? (isCard(i.from) ? "on " : "from ") + acctName(i.from) : "account not set";
    return `<li><span class="what"><span>${esc(b.name)}</span><small>${day(i.date)} · ${esc(where)}${b.note ? " · " + esc(b.note) : ""}</small></span><span class="amt">${amt}</span></li>`;
  }

  function viewCards() {
    const groups = [
      ["Cards", S.accounts.filter((a) => isCard(a) && onSide(a))],
      ["Cash", S.accounts.filter((a) => isCash(a) && onSide(a))],
    ];
    const card = (a) => {
      const bal = a.balance == null ? null : Number(a.balance);
      const pend = Number(a.pending ?? 0);
      const used = a.credit_limit && bal != null ? (bal + pend) / a.credit_limit : null;
      const auto = a.autopay ? S.accounts.find((x) => isCash(x) && a.autopay.includes(x.mask ?? "~")) : null;
      const warns = [];
      if (used != null && used >= 0.9) warns.push(`<span class="pill bad">${(used * 100).toFixed(0)}% of limit</span>`);
      if (auto && cashOf(auto) < 50) warns.push(`<span class="pill warn">AutoPay account has ${usd(cashOf(auto))}</span>`);
      if (bal == null && (isCard(a) || a.available == null)) warns.push(`<span class="pill plain">not read yet</span>`);
      return `<section class="card" id="acct-${esc(a.id)}">
        <header><h3>${esc(acctName(a))}</h3><span class="muted" style="font-size:13px">${esc(a.institution)}</span></header>
        ${warns.length ? `<div class="members">${warns.join("")}</div>` : ""}
        <div class="row"><span class="mid num">${bal == null ? "—" : usd(bal + pend)}</span>
          ${isCard(a) && pend ? `<small class="muted">${usd(bal)} posted + ${usd(pend)} pending</small>` : isCash(a) && a.available != null && a.available !== a.balance && a.balance != null ? `<small class="muted">${usd(a.balance)} balance</small>` : ""}</div>
        ${used != null ? `<div class="meter ${used > 0.9 ? "hot" : used > 0.5 ? "mid" : ""}"><span style="width:${Math.min(100, used * 100).toFixed(1)}%"></span></div>` : ""}
        <div class="grid2">
          ${a.credit_limit ? kv("Limit", usd0(a.credit_limit)) : ""}
          ${isCard(a) && a.credit_limit && bal != null ? kv("Available", usd(a.credit_limit - bal - pend)) : ""}
          ${a.statement_balance != null ? kv("Last statement", usd(a.statement_balance) + (a.statement_date ? ` <small class="muted">${short(parse(a.statement_date))}</small>` : "")) : ""}
          ${a.close_day ? kv("Statement closes", "the " + ord(a.close_day)) : ""}
          ${a.due_day ? kv("Payment due", "the " + ord(a.due_day)) : ""}
          ${a.autopay ? kv("AutoPay", esc(a.autopay)) : ""}
          ${a.rewards ? kv("Rewards", esc(a.rewards)) : ""}
        </div>
        ${a.note ? `<p class="note">${esc(a.note)}</p>` : ""}
        <small class="muted">${a.as_of ? "As of " + new Date(a.as_of).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : ""}</small>
      </section>`;
    };
    return groups.filter(([, l]) => l.length).map(([t, l]) => `<h2 class="wide" style="margin-top:6px">${t}</h2>${l.map(card).join("")}`).join("");
  }
  const kv = (k, v) => `<div class="kv"><small class="muted">${k}</small><b>${v}</b></div>`;

  function viewSpend() {
    const withTx = S.accounts.filter((a) => onSide(a) && S.transactions.some((t) => t.account_id === a.id));
    if (!withTx.length) return `<section class="card wide"><h2>Spending</h2><p class="muted">No ${ui.side} transactions yet. They arrive with the morning sync.</p></section>`;
    if (!ui.spendAcct || !withTx.some((a) => a.id === ui.spendAcct)) ui.spendAcct = (withTx.find(isCard) || withTx[0]).id;
    const a = acct(ui.spendAcct);
    let from, label;
    if (ui.spendPeriod === "statement" && a.statement_date) { from = addDays(parse(a.statement_date), 1); label = "since the " + short(parse(a.statement_date)) + " statement"; }
    else if (ui.spendPeriod === "30") { from = addDays(today, -29); label = "in the last 30 days"; }
    else { from = new Date(today.getFullYear(), today.getMonth(), 1); label = "this month"; }
    const tx = S.transactions.filter((t) => t.account_id === a.id && parse(t.date) >= from).sort((x, y) => (y.date > x.date ? 1 : -1));
    // Moving money between your own accounts, or paying a card from checking, isn't spending.
    const counts = (t) => !["Own transfer", "Card payment"].includes(t.category);
    const out = tx.filter((t) => Number(t.amount) > 0 && counts(t));
    const inn = tx.filter((t) => Number(t.amount) < 0 && counts(t));
    const spent = out.reduce((s, t) => s + Number(t.amount), 0);
    const paid = -inn.reduce((s, t) => s + Number(t.amount), 0);
    const pend = out.filter((t) => t.pending).reduce((s, t) => s + Number(t.amount), 0);
    const group = (key) => Object.entries(out.reduce((m, t) => { const k = key(t) || "Other"; m[k] = (m[k] || 0) + Number(t.amount); return m; }, {})).sort((x, y) => y[1] - x[1]);
    const cats = group((t) => t.category);
    const merch = group((t) => t.merchant.replace(/\s+(\*|#)\S*.*$/, "").replace(/\s+\d{2}\/\d{2}$/, "").trim()).slice(0, 10);
    const bars = (list) => { const max = list[0]?.[1] || 1; return `<div class="bars">${list.map(([k, v]) =>
      `<div class="b"><span class="nm" title="${esc(k)}">${esc(k)}</span><span class="t"><span style="width:${((v / max) * 100).toFixed(1)}%"></span></span><span class="amt">${usd0(v)}</span></div>`).join("")}</div>`; };
    return `
    <section class="card wide" id="spend-head">
      <div class="row" style="flex-wrap:wrap">
        <select id="spend-acct" aria-label="Account">${withTx.map((x) => `<option value="${esc(x.id)}" ${x.id === a.id ? "selected" : ""}>${esc(acctName(x))}</option>`).join("")}</select>
        <div class="seg" role="group" aria-label="Period">
          ${a.statement_date ? `<button data-period="statement" aria-pressed="${ui.spendPeriod === "statement"}">This cycle</button>` : ""}
          <button data-period="month" aria-pressed="${ui.spendPeriod === "month" || (ui.spendPeriod === "statement" && !a.statement_date)}">This month</button>
          <button data-period="30" aria-pressed="${ui.spendPeriod === "30"}">30 days</button>
        </div>
      </div>
      <span class="label">Spent ${esc(label)}</span>
      <div class="big num">${usd(spent)}</div>
      <small class="muted">${out.length} charges${pend ? ` · ${usd(pend)} still pending` : ""}${paid ? ` · ${usd(paid)} paid in` : ""}</small>
    </section>
    <section class="card" id="spend-cats"><h2>By category</h2>${cats.length ? bars(cats) : `<p class="muted">No charges.</p>`}</section>
    <section class="card" id="spend-merch"><h2>Top places</h2>${merch.length ? bars(merch) : `<p class="muted">No charges.</p>`}</section>
    <section class="card wide" id="spend-list"><h2>Transactions</h2>
      <ul class="list">${tx.slice(0, 80).map((t) => `<li><span class="what"><span>${esc(t.merchant)}</span><small>${short(parse(t.date))}${t.category ? " · " + esc(t.category) : ""}${t.pending ? " · pending" : ""}</small></span>
        <span class="amt ${Number(t.amount) < 0 ? "in" : ""}">${Number(t.amount) < 0 ? "+" + usd(-t.amount) : usd(Number(t.amount))}</span></li>`).join("")}</ul>
      ${tx.length > 80 ? `<p class="note">Showing the latest 80 of ${tx.length}.</p>` : ""}
    </section>`;
  }

  function viewUpcoming() {
    const items = upcoming(ui.upDays, ui.side);
    const byDay = new Map();
    for (const i of items) { const k = ymd(i.date); if (!byDay.has(k)) byDay.set(k, []); byDay.get(k).push(i); }
    const fromCash = items.filter((i) => !isCard(i.from) && !i.paid);
    const perAcct = new Map();
    for (const i of fromCash) { const k = i.from ? i.from.id : "_"; const v = perAcct.get(k) || { a: i.from, sum: 0, unk: 0 }; if (i.bill.amount == null) v.unk++; else v.sum += Number(i.bill.amount_max ?? i.bill.amount); perAcct.set(k, v); }
    return `
    <section class="card wide" id="up-head">
      <div class="row" style="flex-wrap:wrap">
        <div class="seg" role="group" aria-label="How far">
          ${[14, 45, 90].map((n) => `<button data-days="${n}" aria-pressed="${ui.upDays === n}">${n} days</button>`).join("")}
        </div>
      </div>
      <h2>Cash needed by account</h2>
      <ul class="list">${[...perAcct.values()].filter((v) => v.sum > 0 || v.unk).sort((x, y) => y.sum - x.sum).map((v) => `<li><span class="what"><span>${esc(v.a ? acctName(v.a) : "Account not set")}</span>
        <small>${v.a && isCash(v.a) ? "has " + usd(cashOf(v.a)) : ""}${v.unk ? ` · ${v.unk} amount${v.unk > 1 ? "s" : ""} not read` : ""}</small></span>
        <span class="amt">${usd(v.sum)}</span></li>`).join("") || `<li class="muted">Nothing due.</li>`}</ul>
      <p class="note">Charges that go on a card are listed below but add to that card's balance, not to cash needed.</p>
    </section>
    <section class="card wide" id="up-list"><h2>Next ${ui.upDays} days</h2>
      ${[...byDay.entries()].map(([k, l]) => `<div class="day">${day(parse(k))}</div><ul class="list">${l.map(itemLi).join("")}</ul>`).join("") || `<p class="muted">Nothing due.</p>`}
    </section>`;
  }

  // ---------- calendar: each bill and subscription on its day, one month at a time ----------
  // Status per charge: paid / pending (found in the paying account), due (still ahead),
  // not seen (date passed, nothing matching found), no data (before that account's first read).
  const kfmt = (n) => n >= 1000 ? "$" + (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, "") + "k" : usd0(n);
  const perMonth = (b) => {
    const a = Number(b.amount_max ?? b.amount ?? 0);
    return { monthly: a, yearly: a / 12, weekly: (a * 52) / 12, interval: b.interval_days ? (a * 365) / 12 / b.interval_days : 0 }[b.cadence] || 0;
  };
  function calItems(first, last) {
    const since = {};
    for (const t of S.transactions) if (!since[t.account_id] || t.date < since[t.account_id]) since[t.account_id] = t.date;
    const items = [];
    for (const b of S.bills) {
      if (ui.calKind === "subs" && b.kind !== "subscription") continue;
      const from = acct(b.pay_from);
      if ((from?.scope ?? b.scope) !== ui.side) continue;
      for (const d of occurrences(b, first, last)) {
        const paid = paidBy(b, d);
        const read = from && since[from.id] && since[from.id] <= ymd(d);
        const st = paid ? (paid.pending ? "pending" : "paid") : d >= today ? "due" : read ? "missed" : "unknown";
        items.push({ date: d, bill: b, from, paid, st, amt: paid ? Number(paid.amount) : b.amount == null ? null : Number(b.amount) });
      }
    }
    return items.sort((x, y) => x.date - y.date || (y.amt ?? 0) - (x.amt ?? 0));
  }
  function calLi(i) {
    const b = i.bill;
    const money = i.amt == null ? "" : usd(i.amt);
    const pill = { paid: `<span class="pill ok">paid ${money}</span>`, pending: `<span class="pill ok">pending ${money}</span>`,
      missed: `<span class="pill warn">not seen</span> <span class="muted">${money}</span>`, unknown: `<span class="muted">${money || "—"}</span>` }[i.st]
      ?? (i.amt == null ? `<span class="pill warn">amount?</span>` : money);
    const where = i.from ? (isCard(i.from) ? "on " : "from ") + acctName(i.from) : "account not set";
    const why = i.st === "unknown" ? " · before the first sync" : i.st === "missed" ? ` · no matching charge on ${esc(i.from?.name ?? "")} within 5 days`
      : i.paid?.parts ? ` · in ${i.paid.parts} payments` : "";
    return `<li><span class="what"><span>${esc(b.name)}</span><small>${day(i.date)} · ${esc(where)}${why}${b.note ? " · " + esc(b.note) : ""}</small></span><span class="amt">${pill}</span></li>`;
  }
  function viewCalendar() {
    const m0 = ui.calMonth || new Date(today.getFullYear(), today.getMonth(), 1);
    const y = m0.getFullYear(), mo = m0.getMonth();
    const first = new Date(y, mo, 1), last = new Date(y, mo, dim(y, mo));
    const items = calItems(first, last);
    const byDay = new Map();
    for (const i of items) { const k = ymd(i.date); if (!byDay.has(k)) byDay.set(k, []); byDay.get(k).push(i); }
    const sum = (l) => l.reduce((s, i) => s + (i.amt ?? 0), 0);
    const paid = items.filter((i) => i.paid), due = items.filter((i) => i.st === "due"), missed = items.filter((i) => i.st === "missed");
    const subsAvg = S.bills.filter((b) => b.active !== false && b.kind === "subscription" && ((acct(b.pay_from)?.scope ?? b.scope) === ui.side)).reduce((s, b) => s + perMonth(b), 0);
    const isNow = y === today.getFullYear() && mo === today.getMonth();
    const sel = ui.calDay && ui.calDay.slice(0, 7) === ymd(first).slice(0, 7) ? ui.calDay : null;
    const cells = [];
    for (let n = 0; n < first.getDay(); n++) cells.push(`<span class="cd blank" aria-hidden="true"></span>`);
    for (let n = 1; n <= last.getDate(); n++) {
      const d = new Date(y, mo, n), k = ymd(d), l = byDay.get(k) || [];
      const cls = ["cd", d < today ? "past" : "", +d === +today ? "today" : ""].filter(Boolean).join(" ");
      const label = `${day(d)}: ${l.length ? l.length + " charge" + (l.length > 1 ? "s" : "") + ", " + usd(sum(l)) : "nothing due"}`;
      cells.push(`<button type="button" class="${cls}" data-calday="${k}" aria-pressed="${k === sel}" aria-label="${esc(label)}">
        <span class="dn">${n}</span>
        <span class="ev">${l.slice(0, 4).map((i) => `<span class="e ${i.st}">${esc(i.bill.name.replace(/\s*\(.*\)$/, ""))}</span>`).join("")}${l.length > 4 ? `<span class="more">+${l.length - 4}</span>` : ""}</span>
        ${l.length ? `<span class="tot">${sum(l) > 0 ? kfmt(sum(l)) + (l.some((i) => i.amt == null) ? "+" : "") : l.some((i) => i.amt == null) ? "?" : "$0"}</span>` : ""}</button>`);
    }
    const shown = sel ? byDay.get(sel) || [] : items;
    const listDays = sel ? [[sel, shown]] : [...byDay.entries()];
    const what = ui.calKind === "subs" ? "Subscriptions" : "Bills and subscriptions";
    return `
    <section class="card wide" id="cal-head">
      <div class="calnav">
        <div class="mon">
          <button type="button" class="iconbtn" data-cal="-1" aria-label="Previous month">‹</button>
          <h2>${first.toLocaleDateString("en-US", { month: "long", year: "numeric" })}</h2>
          <button type="button" class="iconbtn" data-cal="1" aria-label="Next month">›</button>
          ${isNow ? "" : `<button type="button" class="btn ghost small" data-cal="0">Today</button>`}
        </div>
        <div class="seg" role="group" aria-label="Show">
          <button type="button" data-calkind="subs" aria-pressed="${ui.calKind === "subs"}">Subscriptions</button>
          <button type="button" data-calkind="all" aria-pressed="${ui.calKind !== "subs"}">Everything</button>
        </div>
      </div>
      <div class="grid2">
        ${kv(what + " this month", usd(sum(items)))}
        ${kv("Paid", usd(sum(paid)))}
        ${kv(isNow || first > today ? "Still to come" : "Was due, not seen", isNow || first > today ? usd(sum(due)) : usd(sum(missed)))}
        ${ui.calKind === "subs" ? kv("Subscriptions, average month", usd(subsAvg)) : ""}
      </div>
      <div class="calgrid" role="group" aria-label="Days">
        ${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((w) => `<span class="wd" aria-hidden="true">${w.slice(0, 1)}<span class="wd-rest">${w.slice(1)}</span></span>`).join("")}
        ${cells.join("")}
      </div>
      <div class="legend" aria-hidden="true"><span><i class="due"></i>due</span><span><i class="paid"></i>paid</span><span><i class="missed"></i>not seen</span><span><i class="unknown"></i>before first sync</span></div>
    </section>
    <section class="card wide" id="cal-list">
      <header><h2>${sel ? day(parse(sel)) : "All of " + first.toLocaleDateString("en-US", { month: "long" })}</h2>${sel ? `<button type="button" class="btn ghost small" data-calday="${sel}">Show the whole month</button>` : ""}</header>
      ${listDays.length && shown.length ? listDays.map(([k, l]) => `${sel ? "" : `<div class="day">${day(parse(k))}</div>`}<ul class="list">${l.map(calLi).join("")}</ul>`).join("")
        : `<p class="muted">${sel ? "Nothing due this day." : "Nothing due this month."}</p>`}
      ${missed.length ? `<p class="note">"Not seen" means no charge with that name and a close amount turned up in the paying account within 5 days. It may have been charged under another name, on another card, or been cancelled.</p>` : ""}
    </section>`;
  }

  function viewFunds() {
    if (!S.funds.length) return `<section class="card wide"><h2>Funds</h2><p class="muted">No funds yet.</p></section>`;
    const mon = (d) => d.toLocaleDateString("en-US", { month: "short" });
    return S.funds.map((f) => {
      const st = fundState(f);
      const behind = st.expected - st.actual;
      const started = st.months > 0;
      const endOfMonth = new Date(today.getFullYear(), today.getMonth() + 1, 0);
      const lastMonth = st.all[st.all.length - 1];
      const over = f.end_month && parse(f.end_month) < new Date(today.getFullYear(), today.getMonth(), 1);
      const nowKey = ymd(new Date(today.getFullYear(), today.getMonth(), 1)).slice(0, 7);
      // Who paid which month: one row per person, one cell per month. Tap an empty cell to mark it paid.
      const grid = `<div class="scroll"><table class="fundgrid">
        <thead><tr><th></th>${st.all.map((d) => `<th class="${ymd(d).slice(0, 7) === nowKey ? "now" : ""}">${mon(d)}</th>`).join("")}</tr></thead>
        <tbody>${st.rows.map((r) => `<tr><th scope="row">${esc(r.m.name)}</th>${st.all.map((d) => {
          const k = ymd(d).slice(0, 7), got = r.byMonth.get(k) || 0, due = d <= today;
          if (got >= r.per) return `<td><span class="cell paid" title="Paid ${usd0(got)}">✓</span></td>`;
          return `<td><button class="cell ${due ? "owed" : ""}" data-pay="${f.id}:${r.m.id}:${r.per - got}:${ymd(d)}" aria-label="Mark ${esc(r.m.name)} paid for ${d.toLocaleDateString("en-US", { month: "long" })}">${got ? usd0(got) : due ? "owes" : "·"}</button></td>`;
        }).join("")}</tr>`).join("")}</tbody></table></div>`;
      const hist = st.entries.slice().sort((x, y) => (y.on_date > x.on_date ? 1 : -1)).slice(0, 60);
      const who = (id) => st.members.find((m) => m.id === id)?.name ?? "";
      const owers = st.rows.filter((r) => r.owes > 0);
      return `<section class="card wide" id="fund-${f.id}">
        <header><h2>${esc(f.name)}</h2><span class="muted" style="font-size:13px">${usd0(f.monthly_per_person)} each a month${lastMonth ? `, ${mon(parse(f.start_month))}–${mon(lastMonth)} ${lastMonth.getFullYear()}` : ""}</span></header>
        <div class="grid2">
          ${kv("Has", `<span class="mid num">${usd0(st.actual)}</span>`)}
          ${started ? kv(over ? "Should have" : `Should have by ${short(endOfMonth)}`, `<span class="mid num">${usd0(st.expected)}</span>`) : kv("Starts", short(parse(f.start_month)))}
          ${st.goal ? kv(f.end_month ? `At the end (${mon(lastMonth)})` : "Goal", usd0(st.goal)) : ""}
        </div>
        ${st.goal ? `<div class="meter"><span style="width:${Math.min(100, (st.actual / st.goal) * 100).toFixed(1)}%"></span></div>` : ""}
        ${started ? (behind > 0 ? `<p class="status warn">${usd0(behind)} behind: ${owers.map((r) => `${esc(r.m.name)} ${usd0(r.owes)}`).join(", ")}.</p>` : `<p class="status ok">Everyone is up to date.</p>`) : `<p class="note">First deposits are due ${short(parse(f.start_month))}.</p>`}
        ${grid}
        <p class="note">Tap a month to mark it paid.${f.held_in ? ` Money sits in: ${esc(f.held_in)}.` : ""}</p>
        <details><summary>Take money out</summary>
          <form class="row" data-withdraw="${f.id}" style="margin-top:8px;flex-wrap:wrap">
            <input id="wd-amt-${f.id}" name="amount" type="number" min="1" step="0.01" placeholder="Amount" required style="width:120px">
            <input id="wd-note-${f.id}" name="note" placeholder="What for" style="flex:1;min-width:140px">
            <button class="btn small" type="submit">Record</button>
          </form></details>
        <details><summary>History (${st.entries.length})</summary>
          <ul class="list" style="margin-top:6px">${hist.map((e) => `<li><span class="what"><span>${e.kind === "deposit" ? esc(who(e.member_id)) + (e.month ? " · " + parse(e.month).toLocaleDateString("en-US", { month: "short", year: "numeric" }) : "") : "Taken out" + (e.note ? ": " + esc(e.note) : "")}</span>
            <small>${short(parse(e.on_date))}${e.kind === "deposit" && e.note ? " · " + esc(e.note) : ""}</small></span>
            <span class="row" style="gap:8px"><span class="amt ${e.kind === "deposit" ? "in" : ""}">${e.kind === "deposit" ? "+" : "−"}${usd0(e.amount)}</span>
            <button class="btn ghost small" data-del="${e.id}">Remove</button></span></li>`).join("") || `<li class="muted">Nothing yet.</li>`}</ul>
        </details>
      </section>`;
    }).join("");
  }

  // ---------- shell ----------
  const VIEWS = { home: viewHome, cards: viewCards, spend: viewSpend, upcoming: viewUpcoming, calendar: viewCalendar, funds: viewFunds };
  function route() {
    let tab = (location.hash || "#home").slice(1);
    if (!VIEWS[tab] || (tab === "funds" && ui.side === "business")) tab = "home";
    document.querySelectorAll("#side button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.side === ui.side)));
    document.querySelectorAll("#tabs a").forEach((a) => {
      a.hidden = a.dataset.tab === "funds" && ui.side === "business";
      if (a.dataset.tab === tab) { a.setAttribute("aria-current", "page"); a.scrollIntoView({ block: "nearest", inline: "nearest" }); } else a.removeAttribute("aria-current");
    });
    const main = $("#main");
    main.className = "main" + (tab === "home" || tab === "cards" || tab === "spend" ? " two" : "");
    try { main.innerHTML = VIEWS[tab](); } catch (e) { main.innerHTML = `<p class="err pad">This page failed to draw: ${esc(e.message)}</p>`; console.error(e); }
  }

  function header() {
    const s = S.syncs?.[0];
    $("#synced").textContent = s ? `Updated ${new Date(s.at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}${s.missing?.length ? " · not read: " + s.missing.join(", ") : ""}` : "Not synced yet";
    $("#foot").innerHTML = Money.local
      ? `Local preview with ${S.accounts.length} accounts and ${S.bills.length} bills. Nothing here saves.`
      : `Signed in as ${esc(me.user.email)} · <a href="#" id="signout">Sign out</a>`;
  }

  async function refresh() {
    S = await Money.load();
    header();
    route();
  }

  document.addEventListener("click", async (ev) => {
    const t = ev.target.closest("button, a");
    if (!t) return;
    if (t.id === "signout") { ev.preventDefault(); await Money.signOut(); location.reload(); return; }
    if (t.dataset.period) { ui.spendPeriod = t.dataset.period; route(); return; }
    if (t.dataset.side) {
      ui.side = t.dataset.side; ui.spendAcct = null;
      try { localStorage.setItem("money.side", ui.side); } catch {}
      if (ui.side === "business" && location.hash === "#funds") location.hash = "#home"; else route();
      return;
    }
    if (t.dataset.days) { ui.upDays = Number(t.dataset.days); route(); return; }
    if (t.dataset.cal) {
      const n = Number(t.dataset.cal), m0 = ui.calMonth || new Date(today.getFullYear(), today.getMonth(), 1);
      ui.calMonth = n === 0 ? null : new Date(m0.getFullYear(), m0.getMonth() + n, 1); ui.calDay = null; route(); return;
    }
    if (t.dataset.calday) {
      ui.calDay = ui.calDay === t.dataset.calday ? null : t.dataset.calday; route();
      if (ui.calDay) $("#cal-list")?.scrollIntoView({ block: "nearest", behavior: "smooth" });
      return;
    }
    if (t.dataset.calkind) { ui.calKind = t.dataset.calkind; try { localStorage.setItem("money.calKind", ui.calKind); } catch {} route(); return; }
    if (t.dataset.pay) {
      const [fid, mid, amt, month] = t.dataset.pay.split(":");
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Paid?"; return; }
      t.disabled = true;
      try { await Money.addEntry({ fund_id: Number(fid), member_id: Number(mid), kind: "deposit", month, amount: Number(amt), on_date: ymd(today) }); await refresh(); }
      catch (e) { t.disabled = false; t.textContent = e.message.startsWith("This is the local") ? "Preview only" : "Didn't save"; console.error(e); }
      return;
    }
    if (t.dataset.del) {
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Tap again to remove"; return; }
      try { await Money.deleteEntry(Number(t.dataset.del)); await refresh(); } catch (e) { t.textContent = "Didn't remove"; console.error(e); }
    }
  });
  document.addEventListener("change", (ev) => { if (ev.target.id === "spend-acct") { ui.spendAcct = ev.target.value; route(); } });
  document.addEventListener("submit", async (ev) => {
    const f = ev.target.closest("form[data-withdraw]");
    if (!f) return;
    ev.preventDefault();
    const btn = f.querySelector("button");
    try {
      await Money.addEntry({ fund_id: Number(f.dataset.withdraw), kind: "withdrawal", amount: Number(f.amount.value), note: f.note.value || null, on_date: ymd(today) });
      await refresh();
    } catch (e) { btn.textContent = e.message.startsWith("This is the local") ? "Preview only" : "Didn't save"; console.error(e); }
  });
  window.addEventListener("hashchange", route);

  function showOnly(id) {
    for (const x of ["#signin", "#mfa"]) $(x).hidden = x !== id;
    for (const x of ["#main", "#tabs", "#side", "#synced"]) $(x).hidden = !!id;
  }

  // Second step: a 6-digit code from an authenticator app. First time, scan the QR code to set it up.
  async function codeStep(st) {
    showOnly("#mfa");
    let factorId = st.factorId;
    if (st.need === "enroll") {
      const e = await Money.mfaEnroll();
      factorId = e.factorId;
      $("#mfa-title").textContent = "Set up your code";
      $("#mfa-help").textContent = "Scan this with an authenticator app (iPhone Passwords, Google Authenticator or 1Password), then type the 6-digit code it shows. Don't reload this page after scanning: a reload makes a new QR code. You'll need a code each time you sign in.";
      $("#mfa-qr").src = e.qr; $("#mfa-qr").hidden = false;
      $("#mfa-secret").textContent = "Can't scan? Enter this key by hand: " + e.secret; $("#mfa-secret").hidden = false;
    } else {
      $("#mfa-title").textContent = "Enter your code";
      $("#mfa-help").textContent = "Open your authenticator app and type the 6-digit code for Money.";
    }
    $("#mfa-code").focus();
    $("#mfa-form").onsubmit = async (ev) => {
      ev.preventDefault();
      $("#mfa-err").hidden = true;
      try { await Money.mfaVerify(factorId, $("#mfa-code").value.trim()); location.reload(); }
      catch (e) { $("#mfa-err").textContent = "That code didn't work. Codes change every 30 seconds; try the current one."; $("#mfa-err").hidden = false; $("#mfa-code").select(); }
    };
  }

  async function start() {
    me = await Money.session();
    if (!me) {
      showOnly("#signin");
      $("#signin-form").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const fm = ev.target; $("#si-err").hidden = true;
        try { await Money.signIn(fm.email.value.trim(), fm.password.value); location.reload(); }
        catch (e) { $("#si-err").textContent = "That email and password didn't match. Check them and try again."; $("#si-err").hidden = false; }
      });
      return;
    }
    try {
      const st = await Money.mfaState();
      if (st.need) { await codeStep(st); return; }
      await refresh();
    }
    catch (e) { $("#main").innerHTML = `<section class="card"><h2>Couldn't load</h2><p class="muted">${esc(e.message)}</p></section>`; console.error(e); }
  }
  start();
})();
