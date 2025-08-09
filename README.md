# Hearth of the Hamlet — Full Starter (with UI buttons)
- Express/Socket.IO server (TypeScript)
- Phaser client **with buttons** to switch scenes (Plaza ↔ Fishing)
- Postgres schema + seed, Docker Compose
- Quests endpoints + chat history

## Quickstart
```bash
docker compose up -d
psql postgresql://postgres:postgres@localhost:5432/hamlet -f db/schema.sql
psql postgresql://postgres:postgres@localhost:5432/hamlet -f db/seed.sql

cd server && cp .env.example .env && npm i && npm run dev
# in another terminal:
cd ../client && npm i && npm run dev
```
Open the client URL (usually http://localhost:5173).
