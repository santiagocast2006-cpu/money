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

  const rows = (p) => p.then(({ data, error }) => { if (error) throw error; return data || []; });

  async function load() {
    if (!sb) {
      const r = await fetch("seed.local.json", { cache: "no-store" });
      if (!r.ok) throw new Error("No data yet. Run the first sync.");
      return r.json();
    }
    const since = new Date(Date.now() - 120 * 864e5).toISOString().slice(0, 10);
    const [accounts, transactions, bills, syncs, funds, members, entries] = await Promise.all([
      rows(sb.from("accounts").select("*")),
      rows(sb.from("transactions").select("*").gte("date", since).order("date", { ascending: false }).limit(5000)),
      rows(sb.from("bills").select("*")),
      rows(sb.from("syncs").select("*").order("at", { ascending: false }).limit(1)),
      rows(sb.from("funds").select("*")),
      rows(sb.from("fund_members").select("*")),
      rows(sb.from("fund_entries").select("*").order("on_date", { ascending: false })),
    ]);
    return { accounts, transactions, bills, syncs, funds, members, entries };
  }

  function needServer() { if (!sb) throw new Error("This is the local preview. Saving works once the server is connected."); }
  async function addEntry(e) { needServer(); await rows(sb.from("fund_entries").insert(e).select()); }
  async function deleteEntry(id) { needServer(); await rows(sb.from("fund_entries").delete().eq("id", id).select()); }

  // The morning sync calls this from a Chrome tab where Santiago is signed in to the app.
  // payload: {accounts:[{id,...}], transactions:[{account_id,date,merchant,amount,pending,category}], sync:{sources,missing,note}}
  async function importSync(payload) {
    needServer();
    const accts = payload.accounts || [];
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
    if (payload.bills) await rows(sb.from("bills").upsert(payload.bills).select("id"));
    await rows(sb.from("syncs").insert(payload.sync || { sources: [], note: "manual import" }).select("id"));
    return { accounts: accts.length, transactions: tx.length };
  }

  return { local: !sb, session, signIn, signOut, load, addEntry, deleteEntry, importSync };
})();
