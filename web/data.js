// Data layer. With web/config.js (window.MONEY_CONFIG = {url, key}) it talks to the Supabase project;
// without it (local preview) it reads web/seed.local.json and cannot save.
window.Money = (() => {
  const cfg = window.MONEY_CONFIG;
  const sb = cfg && window.supabase
    ? window.supabase.createClient(cfg.url, cfg.key, { auth: { persistSession: true, autoRefreshToken: true } })
    : null;

  async function session() {
    if (!sb) return { user: { id: "local", email: "local preview" }, local: true };
    const { data } = await sb.auth.getSession();
    return data.session;
  }
  async function signIn(email, password) {
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
  }
  async function signOut() { if (sb) await sb.auth.signOut(); }

  // Two-step sign-in with an authenticator app (TOTP). Every table requires it (aal2).
  const ok = ({ data, error }) => { if (error) throw error; return data; };
  async function mfaState() {
    if (!sb) return { need: null };
    const a = ok(await sb.auth.mfa.getAuthenticatorAssuranceLevel());
    if (a.currentLevel === "aal2") return { need: null };
    const f = ok(await sb.auth.mfa.listFactors());
    const verified = (f.totp || []).find((x) => x.status === "verified");
    return verified ? { need: "code", factorId: verified.id } : { need: "enroll" };
  }
  async function mfaEnroll() {
    const f = ok(await sb.auth.mfa.listFactors());
    for (const x of f.all || []) if (x.status !== "verified") await sb.auth.mfa.unenroll({ factorId: x.id });
    const e = ok(await sb.auth.mfa.enroll({ factorType: "totp", friendlyName: "Money", issuer: "Money" }));
    return { factorId: e.id, qr: e.totp.qr_code, secret: e.totp.secret };
  }
  async function mfaVerify(factorId, code) { ok(await sb.auth.mfa.challengeAndVerify({ factorId, code })); }

  const rows = (p) => p.then(({ data, error }) => { if (error) throw error; return data || []; });
  // The server returns at most 1000 rows per request, so read long tables in pages.
  async function all(query) {
    const out = [];
    for (let from = 0; ; from += 1000) {
      const page = await rows(query().range(from, from + 999));
      out.push(...page);
      if (page.length < 1000) return out;
    }
  }

  async function load() {
    if (!sb) {
      const r = await fetch("seed.local.json", { cache: "no-store" });
      if (!r.ok) throw new Error("No data yet. Run the first sync.");
      return r.json();
    }
    const since = new Date(Date.now() - 120 * 864e5).toISOString().slice(0, 10);
    const [accounts, transactions, bills, syncs, funds, members, entries] = await Promise.all([
      rows(sb.from("accounts").select("*")),
      all(() => sb.from("transactions").select("*").gte("date", since).order("date", { ascending: false }).order("id", { ascending: false })),
      rows(sb.from("bills").select("*")),
      rows(sb.from("syncs").select("*").order("at", { ascending: false }).limit(1)),
      rows(sb.from("funds").select("*")),
      rows(sb.from("fund_members").select("*")),
      all(() => sb.from("fund_entries").select("*").order("on_date", { ascending: false }).order("id", { ascending: false })),
    ]);
    return { accounts, transactions, bills, syncs, funds, members, entries };
  }

  function needServer() { if (!sb) throw new Error("This is the local preview. Saving works once the server is connected."); }
  async function addEntry(e) { needServer(); await rows(sb.from("fund_entries").insert(e).select()); }
  async function deleteEntry(id) { needServer(); await rows(sb.from("fund_entries").delete().eq("id", id).select()); }

  // The morning sync calls this from a browser tab where the owner is signed in (with the code step).
  // payload: {accounts:[{id,...}], transactions:[{account_id,date,merchant,amount,pending,category}], sync:{sources,missing,note}}
  // Rows in one upsert must share the same keys, or the missing ones are written as null.
  // So: start from what is stored, lay the new fields over it, and fill any gap with the column default.
  const DEFAULTS = { pending: 0, sort: 100, scope: "personal", active: true, kind: "subscription" };
  function sameKeys(list) {
    const keys = [...new Set(list.flatMap((r) => Object.keys(r)))].filter((k) => k !== "owner");
    return list.map((r) => Object.fromEntries(keys.map((k) => [k, k in r ? r[k] : (DEFAULTS[k] ?? null)])));
  }

  async function importSync(payload) {
    needServer();
    const given = payload.accounts || [];
    const stored = given.length ? await rows(sb.from("accounts").select("*").in("id", given.map((a) => a.id))) : [];
    const accts = sameKeys(given.map((a) => ({ ...(stored.find((s) => s.id === a.id) || {}), ...a })));
    if (accts.length) await rows(sb.from("accounts").upsert(accts, { onConflict: "id" }).select("id"));
    const tx = payload.transactions || [];
    const synced = [...new Set(tx.map((t) => t.account_id))];
    // Pending rows change from day to day: clear the old ones for every account that was read.
    for (const id of synced) await rows(sb.from("transactions").delete().eq("account_id", id).eq("pending", true).select("id"));
    for (let i = 0; i < tx.length; i += 500) {
      await rows(sb.from("transactions").upsert(tx.slice(i, i + 500), {
        onConflict: "account_id,date,merchant,amount,pending", ignoreDuplicates: true,
      }).select("id"));
    }
    // Bills: rows with an id update that bill (merged over what is stored); rows without one are new.
    const bills = payload.bills || [];
    const old = bills.filter((b) => b.id != null);
    if (old.length) {
      const have = await rows(sb.from("bills").select("*").in("id", old.map((b) => b.id)));
      await rows(sb.from("bills").upsert(sameKeys(old.map((b) => ({ ...(have.find((h) => h.id === b.id) || {}), ...b }))), { onConflict: "id" }).select("id"));
    }
    const fresh = bills.filter((b) => b.id == null).map(({ id, ...b }) => b);
    if (fresh.length) await rows(sb.from("bills").insert(sameKeys(fresh)).select("id"));
    await rows(sb.from("syncs").insert(payload.sync || { sources: [], note: "manual import" }).select("id"));
    return { accounts: accts.length, transactions: tx.length, bills: bills.length };
  }

  return { local: !sb, session, signIn, signOut, mfaState, mfaEnroll, mfaVerify, load, addEntry, deleteEntry, importSync };
})();
