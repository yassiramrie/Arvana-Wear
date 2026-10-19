/**
 * server.js — Arvana Wear API
 * ─────────────────────────────────────────────────────────────────────────────
 * Endpoints:
 *   POST /register  → Buat akun baru
 *   POST /login     → Login & validasi password
 *
 * Stack: Express + pg (PostgreSQL) + bcrypt + dotenv
 * ─────────────────────────────────────────────────────────────────────────────
 */

'use strict';

const shutdownTelemetry = require('./telemetry');

// ── DEPENDENCIES ──────────────────────────────────────────────────────────────
const express = require('express');
const { Pool } = require('pg');          // Official PostgreSQL driver for Node.js
const bcrypt  = require('bcryptjs');     // Password hashing (never store plain text!)
const jwt     = require('jsonwebtoken'); // JSON Web Token for authentication state
const cors    = require('cors');
const fs      = require('node:fs');

/**
 * WHY dotenv?
 * ───────────
 * Kredensial database (host, user, password) TIDAK BOLEH ditulis langsung di
 * kode (hardcoded). Alasannya:
 *
 *   1. SECURITY — Jika repo ini public di GitHub, siapapun bisa mencuri
 *      kredensial DB kamu dan mengakses / menghapus data.
 *
 *   2. FLEXIBILITY — Nilai .env bisa berbeda per environment:
 *      development (localhost) vs production (AWS RDS) tanpa ubah kode.
 *
 *   3. BEST PRACTICE — OWASP, CIS, dan AWS Well-Architected Framework
 *      semuanya melarang hardcoded secrets.
 *
 * File .env HARUS ada di .gitignore sehingga tidak pernah ter-commit ke Git.
 */
require('dotenv').config();

// ── APP SETUP ─────────────────────────────────────────────────────────────────
const app  = express();
const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET;

function validateRuntimeConfig(env = process.env) {
  const errors = [];

  if (!env.JWT_SECRET || Buffer.byteLength(env.JWT_SECRET) < 32) {
    errors.push('JWT_SECRET harus berisi minimal 32 byte.');
  }

  if (env.NODE_ENV === 'production') {
    for (const key of ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD']) {
      if (!env[key]?.trim()) errors.push(`${key} wajib diatur pada production.`);
    }

    const origins = (env.CORS_ORIGIN || '').split(',').map(origin => origin.trim()).filter(Boolean);
    if (!origins.length || origins.includes('*')) {
      errors.push('CORS_ORIGIN wajib berisi origin aplikasi yang eksplisit pada production.');
    } else {
      for (const origin of origins) {
        try {
          const parsed = new URL(origin);
          if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin) {
            errors.push(`CORS_ORIGIN berisi origin tidak valid: ${origin}`);
          }
        } catch {
          errors.push(`CORS_ORIGIN berisi origin tidak valid: ${origin}`);
        }
      }
    }

    if (env.DB_SSL !== 'verify-full') {
      errors.push('DB_SSL harus bernilai verify-full pada production.');
    }
    if (!env.DB_SSL_CA?.trim()) {
      errors.push('DB_SSL_CA wajib menunjuk CA certificate database pada production.');
    }
  }

  const port = Number(env.DB_PORT || 5432);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    errors.push('DB_PORT harus berupa port TCP yang valid.');
  }

  const poolMax = Number(env.DB_POOL_MAX || 10);
  if (!Number.isInteger(poolMax) || poolMax < 1) {
    errors.push('DB_POOL_MAX harus berupa bilangan bulat positif.');
  }

  const appPort = Number(env.PORT || 3000);
  if (!Number.isInteger(appPort) || appPort < 1 || appPort > 65535) {
    errors.push('PORT harus berupa port TCP yang valid.');
  }

  if (errors.length) {
    throw new Error(`Konfigurasi aplikasi tidak valid: ${errors.join(' ')}`);
  }
}

function databaseSslConfig(env = process.env) {
  if (env.DB_SSL !== 'verify-full') return false;
  if (!env.DB_SSL_CA?.trim()) {
    throw new Error('DB_SSL_CA wajib menunjuk CA certificate database.');
  }

  return {
    rejectUnauthorized: true,
    ca: fs.readFileSync(env.DB_SSL_CA, 'utf8'),
  };
}

const allowedOrigins = (process.env.CORS_ORIGIN || 'http://localhost')
  .split(',')
  .map(origin => origin.trim())
  .filter(Boolean);

app.use(cors({
  origin: allowedOrigins,
}));
app.use(express.json({ limit: '16kb' }));

// ── DATABASE CONNECTION ───────────────────────────────────────────────────────
/**
 * Pool vs single Client:
 *   Pool otomatis mengelola banyak koneksi. Jauh lebih efisien untuk web server
 *   yang melayani banyak request sekaligus.
 *
 * Semua nilai dibaca dari .env — TIDAK ada satu pun kredensial di sini.
 */
const db = new Pool({
  host:     process.env.DB_HOST,       // RDS Endpoint, e.g. mydb.xxxx.rds.amazonaws.com
  port:     process.env.DB_PORT || 5432,
  database: process.env.DB_NAME,       // Database name, e.g. arvana_wear
  user:     process.env.DB_USER,       // DB master username
  password: process.env.DB_PASSWORD,   // DB master password — paling sensitif!
  ssl: databaseSslConfig(),
  max: Number(process.env.DB_POOL_MAX || 10),
  connectionTimeoutMillis: 5000,
});

const logError = (event, err) => {
  console.error(JSON.stringify({
    level: 'error',
    event,
    message: err.message,
  }));
};

// ── HEALTH CHECK ──────────────────────────────────────────────────────────────
// Useful for load balancers and CI/CD to verify the server is running.
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

const readinessHandler = async (_req, res) => {
  try {
    await db.query('SELECT 1');
    return res.json({ status: 'ok', db: 'ok' });
  } catch (err) {
    logError('readiness_failed', err);
    return res.status(503).json({ status: 'not_ready', db: 'down' });
  }
};

app.get('/ready', readinessHandler);
app.get('/api/health', readinessHandler);

// ── ROUTE: POST /register ─────────────────────────────────────────────────────
/**
 * Alur:
 *   1. Terima { name, email, password } dari body.
 *   2. Validasi input dasar.
 *   3. Hash password dengan bcrypt (cost factor 10).
 *   4. Simpan ke tabel users.
 *   5. Return 201 jika sukses.
 */
app.post('/register', async (req, res) => {
  const { name, email, password } = req.body || {};

  // Basic input validation
  if (![name, email, password].every(value => typeof value === 'string' && value.trim())) {
    return res.status(400).json({ message: 'Nama, email, dan password wajib diisi.' });
  }
  if (name.trim().length > 100 || email.trim().length > 255) {
    return res.status(400).json({ message: 'Nama atau email terlalu panjang.' });
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
    return res.status(400).json({ message: 'Format email tidak valid.' });
  }
  if (password.length < 8) {
    return res.status(400).json({ message: 'Password minimal 8 karakter.' });
  }
  if (Buffer.byteLength(password, 'utf8') > 72) {
    return res.status(400).json({ message: 'Password maksimal 72 byte.' });
  }

  try {
    /**
     * WHY bcrypt?
     * ───────────
     * bcrypt.hash() mengubah password plain menjadi hash yang:
     *   - Tidak bisa di-reverse (one-way)
     *   - Unik setiap kali di-hash (salt otomatis)
     *   - Sengaja lambat (cost factor 10) untuk mencegah brute-force
     *
     * JANGAN gunakan MD5 atau SHA256 untuk password — mereka terlalu cepat.
     */
    const hashedPassword = await bcrypt.hash(password, 10);

    await db.query(
      'INSERT INTO users (name, email, password_hash) VALUES ($1, $2, $3)',
      [name.trim(), email.trim(), hashedPassword]
      // $1, $2, $3 = parameterized query → mencegah SQL Injection
    );

    return res.status(201).json({ message: 'Akun berhasil dibuat.' });

  } catch (err) {
    // PostgreSQL unique violation code: 23505
    if (err.code === '23505') {
      return res.status(409).json({ message: 'Email sudah terdaftar.' });
    }
    logError('register_failed', err);
    return res.status(500).json({ message: 'Terjadi kesalahan server.' });
  }
});

// ── ROUTE: POST /login ────────────────────────────────────────────────────────
/**
 * Alur:
 *   1. Terima { email, password } dari body.
 *   2. Cari user berdasarkan email di database.
 *   3. Bandingkan password dengan hash menggunakan bcrypt.compare().
 *   4. Return data user (TANPA password_hash) jika valid.
 *
 * Catatan Keamanan:
 *   - Pesan error sengaja dibuat generik ("Email atau password salah")
 *     agar attacker tidak tahu apakah email terdaftar atau tidak.
 *     Ini disebut "security through obscurity on error messages".
 */
app.post('/login', async (req, res) => {
  const { email, password } = req.body || {};

  if (![email, password].every(value => typeof value === 'string' && value.trim())) {
    return res.status(400).json({ message: 'Email dan password wajib diisi.' });
  }
  if (email.trim().length > 255 || Buffer.byteLength(password, 'utf8') > 72) {
    return res.status(400).json({ message: 'Email atau password tidak valid.' });
  }

  try {
    const result = await db.query(
      'SELECT id, name, email, password_hash FROM users WHERE email = $1',
      [email.trim()]
    );

    const user = result.rows[0];

    // Pesan error yang sama untuk "user not found" dan "wrong password"
    // mencegah user enumeration attack
    if (!user) {
      return res.status(401).json({ message: 'Email atau password salah.' });
    }

    const isMatch = await bcrypt.compare(password, user.password_hash);
    if (!isMatch) {
      return res.status(401).json({ message: 'Email atau password salah.' });
    }

    // Generate JWT Token agar frontend bisa menyimpan state login (misal di localStorage)
    const token = jwt.sign(
      { id: user.id, email: user.email, name: user.name },
      JWT_SECRET,
      { expiresIn: '24h' }
    );

    // Return user info beserta token — JANGAN sertakan password_hash!
    return res.json({ message: 'Login berhasil.', name: user.name, email: user.email, token });

  } catch (err) {
    logError('login_failed', err);
    return res.status(500).json({ message: 'Terjadi kesalahan server.' });
  }
});

if (require.main === module) {
  validateRuntimeConfig();

  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(`✅ Server running on port ${PORT}`);
    console.log(`   Environment : ${process.env.NODE_ENV || 'development'}`);
    console.log(`   DB Host     : ${process.env.DB_HOST || '(not set)'}`);
  });

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => {
      server.close(error => {
        if (error) {
          logError('server_shutdown_failed', error);
          process.exitCode = 1;
        }
        Promise.all([db.end(), shutdownTelemetry()]).catch(shutdownError => {
          logError('resource_shutdown_failed', shutdownError);
          process.exitCode = 1;
        });
      });
    });
  }
}

app.use((err, _req, res, _next) => {
  if (err.status === 413) {
    return res.status(413).json({ message: 'Ukuran request maksimal 16 KB.' });
  }
  if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
    return res.status(400).json({ message: 'Format JSON tidak valid.' });
  }
  logError('request_failed', err);
  return res.status(500).json({ message: 'Terjadi kesalahan server.' });
});

module.exports = { app, db, validateRuntimeConfig, databaseSslConfig };
