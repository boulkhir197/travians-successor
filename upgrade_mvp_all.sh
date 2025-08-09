#!/usr/bin/env bash
# upgrade_mvp_all.sh — Apply 6 features (cap, cooldown, sounds, market+, compose, QoL)
# Idempotent; safe to re-run. Expect repo layout with server/src and client/src.
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

# --- Helpers ---------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
exists() { command -v "$1" >/dev/null 2>&1; }

test -f server/src/index.ts || die "Run from repo root (server/src/index.ts not found)"
test -f client/src/main.ts  || die "client/src/main.ts not found"
test -f client/src/fishing.ts || die "client/src/fishing.ts not found"
mkdir -p db/migrations client/public/sfx

DBURL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hamlet}"

# --- 1) SQL: Daily cap & persistent cooldown ------------------------------
CAP_SQL="db/migrations/003_daily_cap.sql"
if ! grep -q "user_daily_caps" "$CAP_SQL" 2>/dev/null; then
  cat > "$CAP_SQL" <<'SQL'
-- 003_daily_cap.sql
create table if not exists user_daily_caps (
  user_id uuid not null references users(id) on delete cascade,
  day date not null default (current_date),
  awarded int not null default 0,
  primary key (user_id, day)
);
SQL
  echo " + wrote $CAP_SQL"
else
  echo " = $CAP_SQL exists"
fi

CD_SQL="db/migrations/004_action_cooldowns.sql"
if ! grep -q "action_cooldowns" "$CD_SQL" 2>/dev/null; then
  cat > "$CD_SQL" <<'SQL'
-- 004_action_cooldowns.sql
create table if not exists action_cooldowns (
  user_id uuid not null references users(id) on delete cascade,
  action  text not null,
  ready_at timestamptz not null,
  primary key (user_id, action)
);
SQL
  echo " + wrote $CD_SQL"
else
  echo " = $CD_SQL exists"
fi

if exists psql; then
  echo "Applying migrations to $DBURL (if reachable)…"
  psql "$DBURL" -v ON_ERROR_STOP=1 -f "$CAP_SQL" || true
  psql "$DBURL" -v ON_ERROR_STOP=1 -f "$CD_SQL" || true
else
  echo " ! psql not found — skip applying migrations (files created)."
fi

# --- 2) Server: endpoints & enforcement ----------------------------------
S="server/src/index.ts"
if ! grep -q "/* MVP_LIMITS_START */" "$S"; then
  cat >> "$S" <<'TS'

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
TS
  echo " + server: limits + cooldown + prices + catch"
else
  echo " = server block already present"
fi

# --- 3) Client: sounds, limits HUD, market UI enhancements ----------------
# Sounds (base64 -> client/public/sfx)
if ! test -f client/public/sfx/catch.wav; then
  base64 -d > client/public/sfx/catch.wav <<'B64'
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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
B64
  echo " + wrote client/public/sfx/catch.wav"
fi
if ! test -f client/public/sfx/miss.wav; then
  base64 -d > client/public/sfx/miss.wav <<'B64'
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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
B64
  echo " + wrote client/public/sfx/miss.wav"
fi

# main.ts: add limits HUD + logout + expose refreshLimits
MAIN="client/src/main.ts"
if ! grep -q "/* MVP_LIMITS_HUD */" "$MAIN"; then
  cat >> "$MAIN" <<'TS'

/* MVP_LIMITS_HUD */
async function fetchLimits() {
  try {
    // @ts-ignore
    const token = await (window as any).authReady;
    const r = await fetch('http://localhost:8787/limits', { headers: { Authorization: 'Bearer ' + token } });
    const j = await r.json();
    const log = document.getElementById('chat-log')!;
    const div = document.createElement('div');
    div.textContent = `[limits] Cap restant aujourd'hui: ${j.remainingToday ?? 'N/A'}`;
    log.appendChild(div);
  } catch {}
}
// @ts-ignore
(window as any).refreshLimits = fetchLimits;
fetchLimits();

// Logout button (QoL)
(() => {
  let btn = document.getElementById('btn-logout');
  if (!btn) {
    const host = document.getElementById('controls') || document.body;
    btn = document.createElement('button');
    btn.id = 'btn-logout';
    btn.textContent = 'Déconnexion';
    (btn as HTMLButtonElement).style.margin = '4px';
    host.appendChild(btn);
  }
  btn!.addEventListener('click', () => {
    localStorage.removeItem('token');
    location.reload();
  });
})();
TS
  echo " + client: limits HUD + logout"
else
  echo " = limits HUD already present"
fi

# fishing.ts: ensure sounds preload & catch endpoint & cap/cooldown messages
FISH="client/src/fishing.ts"
if ! grep -q "/* MVP_SOUNDS */" "$FISH"; then
  # Add preload at top of class if absent
  python3 - <<'PY' "$FISH"
import sys,re
p=sys.argv[1]
s=open(p,'r',encoding='utf-8').read()
if 'preload()' not in s:
    s=s.replace("constructor() { super('Fishing'); }",
                "constructor() { super('Fishing'); }\\n\\n  /* MVP_SOUNDS */\\n  preload() {\\n    if (!this.sound.get('catch')) this.load.audio('catch','/sfx/catch.wav');\\n    if (!this.sound.get('miss')) this.load.audio('miss','/sfx/miss.wav');\\n  }")
else:
    if 'catch.wav' not in s:
        s=s.replace('preload() {','preload() {\\n    if (!this.sound.get(\\'catch\\')) this.load.audio(\\'catch\\',\\'/sfx/catch.wav\\');\\n    if (!this.sound.get(\\'miss\\')) this.load.audio(\\'miss\\',\\'/sfx/miss.wav\\');')
open(p,'w',encoding='utf-8').write(s)
PY
  echo " + fishing: preload sounds"
fi

# Replace claim endpoint with catch; add cap/cooldown handling and play sounds.
python3 - <<'PY' "$FISH"
import sys,re
p=sys.argv[1]
s=open(p,'r',encoding='utf-8').read()
s=re.sub(r"/jobs/fishing/claim","/jobs/fishing/catch",s)
# Show messages for cooldown & cap if not present
if 'Cooldown… réessayez' not in s or 'Cap atteint' not in s:
    s=re.sub(r"const json = await r\\.json\\(\\);\\n\\s*this\\.acornsText = .*?;\\n",
             "const json = await r.json();\\n          this.acornsText = put(this.acornsText, 100, 460, `Acorns: ${json.acorns}`, '#aaddff');\\n          if (json.capped || (json.remainingToday!==undefined && json.remainingToday<=0)) {\\n            this.add.text(100, 485, 'Cap atteint pour aujourd\\'hui', { font: '14px sans-serif', color: '#ffaa00' });\\n          }\\n          try { const rf = (window as any).refreshLimits; if (typeof rf==='function') rf(); } catch {}\\n", flags=re.S)
    s=re.sub(r"if \\(!r\\.ok\\) \\{[\\s\\S]*?return;\\n\\s*\\}",
             "if (!r.ok) {\\n            try { const err = await r.json(); if (err && err.error==='cooldown') { const secs=Math.ceil((err.retryInMs||0)/1000); this.acornsText = put(this.acornsText, 100, 460, `Cooldown… réessayez dans ${secs}s`, '#ffaa00'); return; } } catch {}\\n            this.acornsText = put(this.acornsText, 100, 460, 'Récompense refusée', '#ffaa00');\\n            return;\\n          }", flags=re.S)
# Play sounds on success/fail
if "this.sound.play('catch')" not in s:
    s=s.replace("this.statusOk = put(this.statusOk, 100, 400, 'Poisson attrapé ! (+10 Acorns)', '#00ff88');",
                "this.statusOk = put(this.statusOk, 100, 400, 'Poisson attrapé ! (+10 Acorns)', '#00ff88'); this.sound.play('catch',{volume:0.6});")
if "this.sound.play('miss')" not in s:
    s=s.replace("this.statusFail = put(this.statusFail, 100, 430, 'Raté…', '#ff6666');",
                "this.statusFail = put(this.statusFail, 100, 430, 'Raté…', '#ff6666'); this.sound.play('miss',{volume:0.5});")
open(p,'w',encoding='utf-8').write(s)
PY
echo " + fishing: catch endpoint + cap/cooldown messages + sounds"

# market.ts: prices + sell x5
MARK="client/src/market.ts"
if test -f "$MARK" && ! grep -q "/market/prices" "$MARK"; then
  python3 - <<'PY' "$MARK"
import sys
p=sys.argv[1]
s=open(p,'r',encoding='utf-8').read()
s=s.replace("this.add.text(10, 80, 'Vendre 1 poisson (+10 Acorns)'",
            "const priceList = await (await fetch('http://localhost:8787/market/prices')).json();\\n      const price = priceList['fish'] ?? 10;\\n      this.add.text(10, 80, `Vendre 1 poisson (+${{price}} Acorns)`")
s=s.replace("JSON.stringify({ item: 'fish', qty: 1 })",
            "JSON.stringify({ item: 'fish', qty: 1 })")
if 'Vendre 5 poissons' not in s:
    s += \"\"\"\n      this.add.text(10, 140, 'Vendre 5 poissons (+50 Acorns)', { font: '16px sans-serif', color: '#00ffaa' })\\\n        .setInteractive({ useHandCursor: true })\\\n        .on('pointerdown', async () => {\\\n          try {\\\n            # @ts-ignore\\\n            const token = await (window as any).authReady;\\\n            const r = await fetch('http://localhost:8787/market/sell', {\\\n              method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },\\\n              body: JSON.stringify({ item: 'fish', qty: 5 })\\\n            });\\\n            const json = await r.json();\\\n            if (!r.ok) {{ this.result?.destroy(); this.result = this.add.text(10, 170, 'Vente refusée', {{ font: '14px sans-serif', color: '#ff6666' }}); return; }}\\\n            this.result?.destroy();\\\n            this.result = this.add.text(10, 170, `Vendu x5 ! Acorns: ${{json.acorns}}`, {{ font: '14px sans-serif', color: '#aaddff' }});\\\n            this.info?.setText(`Poissons: ${{json.item?.qty or 0}}`);\\\n            try {{ const refresh = (window as any).refreshWallet; if (typeof refresh === 'function') refresh(); }} catch {{}}\\\n          } catch {{ this.result?.destroy(); this.result = this.add.text(10, 170, 'Erreur réseau', {{ font: '14px sans-serif', color: '#ff6666' }}); }}\\\n        });\n\"\"\"
open(p,'w',encoding='utf-8').write(s)
PY
  echo " + market: prices + sell x5"
else
  echo " = market already enhanced or missing"
fi

# --- 4) Docker Compose (server+client+db) ---------------------------------
DC="docker-compose.yml"
if ! grep -q "services:" "$DC" 2>/dev/null; then
  cat > "$DC" <<'YML'
version: "3.9"
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: hamlet
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
  server:
    image: node:18
    working_dir: /app
    volumes: ["./:/app"]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@db:5432/hamlet
      PORT: 8787
    command: bash -lc "cd server && npm ci && npm run start"
    ports: ["8787:8787"]
    depends_on: ["db"]
  client:
    image: node:18
    working_dir: /app/client
    volumes: ["./client:/app/client"]
    command: bash -lc "npm ci && npm run build && npx http-server dist -p 8080 -a 0.0.0.0"
    ports: ["8080:8080"]
    depends_on: ["server"]
volumes:
  pgdata: {{}}
YML
  echo " + wrote docker-compose.yml (db+server+client)"
else
  echo " = docker-compose.yml already present"
fi

# --- 5) Final messages -----------------------------------------------------
echo ""
echo "Upgrade complete."
echo "Next:"
echo " - Apply migrations if not already applied:"
echo "     psql \\"$DBURL\\" -f db/migrations/003_daily_cap.sql"
echo "     psql \\"$DBURL\\" -f db/migrations/004_action_cooldowns.sql"
echo " - Restart server (and client will auto-reload)."
echo " - Try: fishing success repeatedly -> cooldown 3s + cap visible in chat."
echo " - Market: /market/prices shown, Sell x1/x5 updates wallet and inventory."
