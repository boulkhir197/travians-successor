import 'dotenv/config'; import express from 'express'; import cors from 'cors'; import http from 'http';
import { setupWS } from './ws.js'; import { query } from './db.js';
const app = express(); app.use(cors()); app.use(express.json());

app.get('/health', (_req, res) => res.json({ ok: true }));

app.post('/auth/guest', async (_req, res) => {
  const handle = 'guest_' + Math.random().toString(36).slice(2, 8);
  const r = await query('insert into users(handle) values($1) returning id, handle', [handle]);
  res.json({ token: r.rows[0].id, user: r.rows[0] });
});

app.get('/me', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const r = await query('select id, handle from users where id=$1', [token]);
  if (!r.rows[0]) return res.status(401).json({ error: 'invalid token' });
  res.json({ user: r.rows[0] });
});

app.get('/chat/history', async (req, res) => {
  const channel = String(req.query.channel || 'global'); const limit = Number(req.query.limit || 50);
  const r = await query('select channel, user_id, text, created_at from chat_messages where channel=$1 order by id desc limit $2', [channel, limit]);
  res.json(r.rows.reverse());
});

app.post('/house', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { kind, x, y, rot } = req.body;
  const u = await query('select id from users where id=$1', [token]); if (!u.rows[0]) return res.status(401).json({ error: 'invalid token' });
  const h = await query('select id from houses where user_id=$1', [token]);
  const houseId = h.rows[0]?.id || (await query('insert into houses(user_id) values($1) returning id', [token])).rows[0].id;
  await query('insert into furniture(house_id,kind,x,y,rot) values($1,$2,$3,$4,$5)', [houseId, kind, x, y, rot ?? 0]);
  res.json({ ok: true });
});

app.get('/quests', async (_req, res) => {
  const genRow = await query('select gen from server_state where id=1'); const gen = genRow.rows[0]?.gen ?? 1;
  const r = await query('select id, code, data from quests where gen_min <= $1 order by id asc', [gen]);
  res.json(r.rows);
});

app.post('/quests/claim', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { code } = req.body || {}; if (!code) return res.status(400).json({ error: 'missing quest code' });
  const q = await query('select id from quests where code=$1', [code]); if (!q.rows[0]) return res.status(404).json({ error: 'quest not found' });
  const questId = q.rows[0].id;
  await query('insert into quest_progress(user_id,quest_id,step,completed) values($1,$2,1,true) on conflict (user_id,quest_id) do update set completed=true, step=1', [token, questId]);
  res.json({ ok: true, questId });
});

app.post('/admin/rollover', async (_req, res) => {
  await query('update server_state set gen = gen + 1, gen_ends_at = now() + interval \'90 days\' where id=1');
  res.json({ ok: true, message: 'Next generation started' });
});

const server = http.createServer(app); setupWS(server);
server.listen(process.env.PORT || 8787, () => console.log('Server on', process.env.PORT || 8787));

// --- Wallet ---
app.get('/wallet', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const r = await query('select acorns from user_wallets where user_id=$1', [token]);
  res.json({ acorns: r.rows[0]?.acorns ?? 0 });
});

// --- Fishing reward (MVP - no anti-abuse yet) ---
app.post('/jobs/fishing/claim', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { success } = req.body || {};
  const delta = success ? 10 : 0;
  await query('insert into user_wallets(user_id, acorns) values ($1, 0) on conflict (user_id) do nothing', [token]);
  if (delta > 0) {
    await query('update user_wallets set acorns = acorns + $1 where user_id=$2', [delta, token]);
  }
  const r = await query('select acorns from user_wallets where user_id=$1', [token]);
  res.json({ ok: true, gained: delta, acorns: r.rows[0]?.acorns ?? 0 });
});

// === Inventory & Market ===
app.get('/inventory', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const r = await query('select item, qty from user_inventory where user_id=$1 order by item asc', [token]);
  res.json(r.rows);
});

app.post('/inventory/add', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { item, qty } = req.body || {};
  if (!item || !Number.isInteger(qty)) return res.status(400).json({ error: 'bad params' });
  await query(`insert into user_inventory(user_id, item, qty) values ($1,$2,$3)
               on conflict (user_id, item) do update set qty = user_inventory.qty + EXCLUDED.qty`,
               [token, item, qty]);
  const r = await query('select item, qty from user_inventory where user_id=$1 and item=$2', [token, item]);
  res.json({ ok: true, item: r.rows[0] || { item, qty: 0 } });
});

// Price list (very static for now)
const PRICE_SELL: Record<string, number> = { fish: 10 };

app.post('/market/sell', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { item, qty } = req.body || {};
  if (!item || !Number.isInteger(qty) || qty <= 0) return res.status(400).json({ error: 'bad params' });

  // check inv
  const inv = await query('select qty from user_inventory where user_id=$1 and item=$2', [token, item]);
  const have = inv.rows[0]?.qty ?? 0;
  if (have < qty) return res.status(400).json({ error: 'not_enough', have });

  // remove from inv
  await query('update user_inventory set qty = qty - $1 where user_id=$2 and item=$3', [qty, token, item]);

  // credit wallet
  const price = PRICE_SELL[item] ?? 0;
  const delta = price * qty;
  await query('insert into user_wallets(user_id, acorns) values ($1, 0) on conflict (user_id) do nothing', [token]);
  if (delta > 0) await query('update user_wallets set acorns = acorns + $1 where user_id=$2', [delta, token]);

  const w = await query('select acorns from user_wallets where user_id=$1', [token]);
  const r2 = await query('select item, qty from user_inventory where user_id=$1 and item=$2', [token, item]);
  res.json({ ok: true, gained: delta, acorns: w.rows[0]?.acorns ?? 0, item: r2.rows[0] || { item, qty: 0 } });
});

// New catch endpoint that gives fish + acorns in one go
app.post('/jobs/fishing/catch', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { success } = req.body || {};
  if (!success) return res.json({ ok: true, gained: 0, acorns: 0, item: { item: 'fish', qty: 0 } });

  // +1 fish
  await query(`insert into user_inventory(user_id, item, qty) values ($1,'fish',1)
               on conflict (user_id, item) do update set qty = user_inventory.qty + 1`, [token]);

  // +10 acorns
  await query('insert into user_wallets(user_id, acorns) values ($1, 0) on conflict (user_id) do nothing', [token]);
  await query('update user_wallets set acorns = acorns + 10 where user_id=$1', [token]);

  const w = await query('select acorns from user_wallets where user_id=$1', [token]);
  const inv = await query('select qty from user_inventory where user_id=$1 and item=$2', [token, 'fish']);
  res.json({ ok: true, gained: 10, acorns: w.rows[0]?.acorns ?? 0, item: { item: 'fish', qty: inv.rows[0]?.qty ?? 0 } });
});

/* MVP_LIMITS_START */
const DAILY_CAP = 300;

// helper: get remaining cap today, and clamp delta
async function awardWithinCap(userId: string, delta: number): Promise<{gained:number, remaining:number}> {
  if (delta <= 0) return { gained: 0, remaining: DAILY_CAP };
  const today = new Date().toISOString().slice(0,10); // yyyy-mm-dd
  // ensure row
  await query(
    "insert into user_daily_caps(user_id, day, awarded) values ($1, $2, 0) on conflict (user_id,day) do nothing",
    [userId, today]
  );
  const cur = await query("select awarded from user_daily_caps where user_id=$1 and day=$2", [userId, today]);
  const awarded = cur.rows[0]?.awarded ?? 0;
  const remaining = Math.max(0, DAILY_CAP - awarded);
  const gained = Math.min(remaining, delta);
  if (gained > 0) {
    await query("update user_daily_caps set awarded = awarded + $1 where user_id=$2 and day=$3", [gained, userId, today]);
  }
  return { gained, remaining: Math.max(0, remaining - gained) };
}

// helper: persistent cooldowns
async function checkAndSetCooldown(userId: string, action: string, ms: number): Promise<{ok:boolean, retryInMs:number}> {
  const r = await query("select ready_at from action_cooldowns where user_id=$1 and action=$2", [userId, action]);
  const now = Date.now();
  const readyAt = r.rows[0]?.ready_at ? new Date(r.rows[0].ready_at).getTime() : 0;
  if (readyAt > now) return { ok: false, retryInMs: readyAt - now };
  const next = new Date(now + ms).toISOString();
  await query(
    "insert into action_cooldowns(user_id,action,ready_at) values ($1,$2,$3) on conflict (user_id,action) do update set ready_at=$3",
    [userId, action, next]
  );
  return { ok: true, retryInMs: 0 };
}

// limits HUD
app.get('/limits', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const today = new Date().toISOString().slice(0,10);
  const cur = await query("select awarded from user_daily_caps where user_id=$1 and day=$2", [token, today]);
  const awarded = cur.rows[0]?.awarded ?? 0;
  res.json({ dailyCap: DAILY_CAP, awardedToday: awarded, remainingToday: Math.max(0, DAILY_CAP - awarded) });
});

// price list
const PRICE_SELL: Record<string, number> = { fish: 10, algae: 3 };

app.get('/market/prices', (_req, res) => {
  res.json(PRICE_SELL);
});

// enhanced sell: any qty
app.post('/market/sell', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { item, qty } = req.body || {};
  const n = Number(qty);
  if (!item || !Number.isFinite(n) || n <= 0) return res.status(400).json({ error: 'bad params' });

  const inv = await query('select qty from user_inventory where user_id=$1 and item=$2', [token, item]);
  const have = inv.rows[0]?.qty ?? 0;
  if (have < n) return res.status(400).json({ error: 'not_enough', have });

  await query('update user_inventory set qty = qty - $1 where user_id=$2 and item=$3', [n, token, item]);

  const price = PRICE_SELL[item] ?? 0;
  const delta = price * n;
  await query('insert into user_wallets(user_id, acorns) values ($1, 0) on conflict (user_id) do nothing', [token]);
  if (delta > 0) await query('update user_wallets set acorns = acorns + $1 where user_id=$2', [delta, token]);
  const w = await query('select acorns from user_wallets where user_id=$1', [token]);
  const r2 = await query('select item, qty from user_inventory where user_id=$1 and item=$2', [token, item]);
  res.json({ ok: true, gained: delta, acorns: w.rows[0]?.acorns ?? 0, item: r2.rows[0] || { item, qty: 0 } });
});

// unified catch endpoint: +1 fish, +10 acorns, cap+cooldown enforced
app.post('/jobs/fishing/catch', async (req, res) => {
  const token = String(req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'no token' });
  const { success } = req.body || {};
  if (!success) return res.json({ ok: true, gained: 0, acorns: 0, item: { item: 'fish', qty: 0 }, remainingToday: DAILY_CAP });

  // cooldown 3s
  const cd = await checkAndSetCooldown(token, 'fishing', 3000);
  if (!cd.ok) return res.status(429).json({ error: 'cooldown', retryInMs: cd.retryInMs });

  // +1 fish (no cap)
  await query(`insert into user_inventory(user_id, item, qty) values ($1,'fish',1)
               on conflict (user_id, item) do update set qty = user_inventory.qty + 1`, [token]);

  // cap for acorns
  const { gained, remaining } = await awardWithinCap(token, 10);
  await query('insert into user_wallets(user_id, acorns) values ($1, 0) on conflict (user_id) do nothing', [token]);
  if (gained > 0) await query('update user_wallets set acorns = acorns + $1 where user_id=$2', [gained, token]);

  const w = await query('select acorns from user_wallets where user_id=$1', [token]);
  const inv = await query('select qty from user_inventory where user_id=$1 and item=$2', [token, 'fish']);
  res.json({ ok: true, gained, acorns: w.rows[0]?.acorns ?? 0, item: { item: 'fish', qty: inv.rows[0]?.qty ?? 0 }, remainingToday: remaining, capped: gained < 10 });
});
/* MVP_LIMITS_END */
