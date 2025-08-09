-- 001_wallet.sql — simple wallet for Acorns
create table if not exists user_wallets (
  user_id uuid primary key references users(id) on delete cascade,
  acorns int not null default 0
);

-- Optional seed for quick testing: start everyone with 100
-- insert into user_wallets(user_id, acorns)
--   select id, 100 from users
-- on conflict (user_id) do nothing;

