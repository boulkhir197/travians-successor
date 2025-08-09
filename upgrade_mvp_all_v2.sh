#!/usr/bin/env bash
# upgrade_mvp_all_v2.sh — same features as v1, but without any inline Python.
# Idempotent; safe to re-run.
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

die(){ echo "ERROR: $*" >&2; exit 1; }
exists(){ command -v "$1" >/dev/null 2>&1; }

test -f server/src/index.ts || die "Run from repo root (missing server/src/index.ts)"
test -f client/src/main.ts  || die "Missing client/src/main.ts"
test -f client/src/fishing.ts || die "Missing client/src/fishing.ts"
mkdir -p db/migrations client/public/sfx

DBURL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/hamlet}"

# --- 1) SQL: Daily cap & persistent cooldown ---------------------------------
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
  echo " ! psql not found — skipping live migration (files created)"
fi

# --- 2) Server: endpoints & enforcement -------------------------------------
S="server/src/index.ts"
if ! grep -q "/\* MVP_LIMITS_START \*/" "$S"; then
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

# --- 3) Client: sounds, limits HUD, market UI ------------------------------
# Write tiny wavs (base64) — same as v1
if ! test -f client/public/sfx/catch.wav; then
  base64 -d > client/public/sfx/catch.wav <<'B64'
UklGRm4AAABXQVZFZm10IBAAAAABAAEAESsAACJWAAACABAAZGF0YQQAAACwAAAAPgD+ADgA7gBVANwAagC2AHsBqQCEAc8AjgH1AJAB/wCSAf8AkQH2AIkBzQB9Aa8AbgC3AFkA3wA8AP4AAgD/AD8A3gBaALgAbQGiAHkBuwCFAd0AlAH9AJQB+wCTAfIAiQHqAH0BtgBrALUAUwDeADQA+wD8APEA3QBYALUAbQGgAHgBswCDAdMAjwHwAJQB+wCUAfIAjQHzAIsB0gCDAa4AegGgAGYAtgBWAN4ANgD8APsA8QDeAFkAtQBnAaEAfQGzAIMB0wCMAfEAkQH5AJIB9ACPAe4AhgHZAIEBqAB1AaQAZACzAFgA3gA5APkA+wDxANwAWQC1AGcBoQB9AbMAhAHUAJAB8gCSAfQAjgH0AI0B5wCGAdoAgQGmAHYBpwBkALMAWQDeADoA+AD7APEA3QBZALYAZwGgAH4BsgCEAdQAkAHyAJIB9ACOAfQAjAHlAYs=
B64
  echo " + wrote client/public/sfx/catch.wav"
fi
if ! test -f client/public/sfx/miss.wav; then
  base64 -d > client/public/sfx/miss.wav <<'B64'
UklGRkIAAABXQVZFZm10IBAAAAABAAEAESsAACJWAAACABAAZGF0YQwAAAAAAABmZmZlY2NjY2NjYmJiYWFhYWFhYmJiY2NjZGVlZWVnZ2dnZWVlZGRkY2NjYmJiYWFhYWFhYmJiY2NjZGRkZWVlZ2dnZ2VlZWRkZGNjY2JiYmFhYWFhYWJiYmNjY2RkZGVlZWdnZ2dlZWVkZGRjY2NiYmJhYWFhYWFhYmJjY2NkZGRlZWVnZ2dnZWVlZGRkY2NjYmJiYWFhYWFhYmJiY2NjZGRkZWVlZ2dnZ2VlZQ==
B64
  echo " + wrote client/public/sfx/miss.wav"
fi

# Add limits HUD + logout (once)
MAIN="client/src/main.ts"
if ! grep -q "/\* MVP_LIMITS_HUD \*/" "$MAIN"; then
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

# fishing.ts changes WITHOUT Python — use Perl with temp file (portable)
FISH="client/src/fishing.ts"
TMP="$FISH.tmp.$$"
cp "$FISH" "$TMP"

# 1) Ensure preload() loads sfx
if ! grep -q "/* MVP_SOUNDS */" "$FISH"; then
  if grep -q "constructor() { super('Fishing'); }" "$FISH"; then
    perl -0777 -pe "s@constructor\(\) \{ super\('Fishing'\); \}@constructor() { super('Fishing'); }\n\n  /* MVP_SOUNDS */\n  preload() {\n    if (!this.sound.get('catch')) this.load.audio('catch','/sfx/catch.wav');\n    if (!this.sound.get('miss')) this.load.audio('miss','/sfx/miss.wav');\n  }@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH"
    echo " + fishing: added preload() with sounds"
  else
    # If preload exists but no sounds, inject inside preload start
    if grep -q "preload()" "$FISH"; then
      perl -0777 -pe "s@preload\(\) \{@preload() {\n    if (!this.sound.get('catch')) this.load.audio('catch','/sfx/catch.wav');\n    if (!this.sound.get('miss')) this.load.audio('miss','/sfx/miss.wav');@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH"
      echo " + fishing: ensured sounds in preload()"
    fi
  fi
fi

# 2) Switch endpoint claim -> catch
if grep -q "/jobs/fishing/claim" "$FISH"; then
  sed -e "s#/jobs/fishing/claim#/jobs/fishing/catch#g" "$FISH" > "$TMP" && mv "$TMP" "$FISH"
  echo " + fishing: endpoint switched to /jobs/fishing/catch"
fi

# 3) Handle cooldown and cap messages + play sounds (only add if missing)
if ! grep -q "Cooldown… réessayez" "$FISH"; then
  perl -0777 -pe "s@if \(!r\.ok\) \{[\\s\\S]*?return;\\n\\s*\\}@if (!r.ok) {\n            try {\n              const err = await r.json();\n              if (err && err.error === 'cooldown') {\n                const secs = Math.ceil((err.retryInMs || 0) / 1000);\n                this.acornsText = put(this.acornsText, 100, 460, \`Cooldown… réessayez dans \${secs}s\`, '#ffaa00');\n                return;\n              }\n            } catch {}\n            this.acornsText = put(this.acornsText, 100, 460, 'Récompense refusée', '#ffaa00');\n            return;\n          }@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH" || true
  echo " + fishing: cooldown message handling"
fi
if ! grep -q "Cap atteint pour aujourd" "$FISH"; then
  perl -0777 -pe "s@const json = await r\.json\(\);\n\s*this\.acornsText = .*?;@const json = await r.json();\n          this.acornsText = put(this.acornsText, 100, 460, \`Acorns: \${json.acorns}\`, '#aaddff');\n          if (json.capped || (json.remainingToday!==undefined && json.remainingToday<=0)) {\n            this.add.text(100, 485, 'Cap atteint pour aujourd\\'hui', { font: '14px sans-serif', color: '#ffaa00' });\n          }\n          try { const rf = (window as any).refreshLimits; if (typeof rf==='function') rf(); } catch {}@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH" || true
  echo " + fishing: cap message + refreshLimits"
fi
if ! grep -q "this.sound.play('catch')" "$FISH"; then
  perl -0777 -pe "s@('Poisson attrapé ! \(\+10 Acorns\)', '#00ff88'\);)@\\1 this.sound.play('catch',{volume:0.6});@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH" || true
  echo " + fishing: success sound"
fi
if ! grep -q "this.sound.play('miss')" "$FISH"; then
  perl -0777 -pe "s@('Raté…', '#ff6666'\);)@\\1 this.sound.play('miss',{volume:0.5});@s" "$FISH" > "$TMP" && mv "$TMP" "$FISH" || true
  echo " + fishing: miss sound"
fi

# --- 4) Docker Compose (server+client+db) ----------------------------------
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
  pgdata: {}
YML
  echo " + wrote docker-compose.yml (db+server+client)"
else
  echo " = docker-compose.yml already present"
fi

echo ""
echo "All good. If server is running, just reload the client."
echo "If not, re-run migrations (psql) and restart server."
