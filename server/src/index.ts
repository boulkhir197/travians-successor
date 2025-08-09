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
