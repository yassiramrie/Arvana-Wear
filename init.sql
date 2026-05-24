-- ─────────────────────────────────────────────────────────────────────────────
-- init.sql — Inisialisasi Tabel Arvana Wear
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Mode Docker:
--   File ini di-mount ke /docker-entrypoint-initdb.d/init.sql
--   PostgreSQL container otomatis menjalankan file ini saat database pertama
--   kali dibuat (hanya sekali). Database 'arvana_wear' sudah dibuat otomatis
--   oleh POSTGRES_DB di docker-compose.yml, jadi kita hanya perlu buat tabel.
--
-- Mode Manual (psql):
--   psql -h <HOST> -U postgres -d arvana_wear -f init.sql
-- ─────────────────────────────────────────────────────────────────────────────

-- ── TABEL USERS ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id            SERIAL        PRIMARY KEY,
  name          VARCHAR(100)  NOT NULL,
  email         VARCHAR(255)  NOT NULL UNIQUE,  -- UNIQUE mencegah duplikat email
  password_hash VARCHAR(255)  NOT NULL,          -- Selalu simpan hash, BUKAN plain text!
  created_at    TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- Index pada email mempercepat query WHERE email = $1 saat login
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);

-- ─────────────────────────────────────────────────────────────────────────────
-- Catatan DevSecOps:
--
--   1. password_hash — bcrypt output, bukan password asli. Jika DB bocor,
--      attacker butuh jutaan tahun untuk crack bcrypt (cost 10).
--
--   2. UNIQUE constraint pada email — enforce di level DB, lapisan kedua
--      setelah validasi di aplikasi.
--
--   3. IF NOT EXISTS — aman dijalankan berkali-kali, tidak akan error.
-- ─────────────────────────────────────────────────────────────────────────────
