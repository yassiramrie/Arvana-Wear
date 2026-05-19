/**
 * server.js — Vespabrok Catalog API
 * ─────────────────────────────────────────────────────────────────────────────
 * Endpoints:
 *   POST /register  → Buat akun baru
 *   POST /login     → Login & validasi password
 *
 * Stack: Express + pg (PostgreSQL) + bcrypt + dotenv
 * ─────────────────────────────────────────────────────────────────────────────
 */

'use strict';

// ── DEPENDENCIES ──────────────────────────────────────────────────────────────
const express = require('express');
const { Pool } = require('pg');          // Official PostgreSQL driver for Node.js
const bcrypt  = require('bcryptjs');     // Password hashing (never store plain text!)
const cors    = require('cors');

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

app.use(cors());                         // Allow requests from the frontend origin
app.use(express.json());                 // Parse incoming JSON request body

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
  database: process.env.DB_NAME,       // Database name, e.g. vespa_catalog
  user:     process.env.DB_USER,       // DB master username
  password: process.env.DB_PASSWORD,   // DB master password — paling sensitif!
  ssl: process.env.DB_SSL === 'false' ? false : {rejectUnauthorized: false},
});

// ── HEALTH CHECK ──────────────────────────────────────────────────────────────
// Useful for load balancers and CI/CD to verify the server is running.
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

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
  const { name, email, password } = req.body;

  // Basic input validation
  if (!name || !email || !password) {
    return res.status(400).json({ message: 'Nama, email, dan password wajib diisi.' });
  }
  if (password.length < 8) {
    return res.status(400).json({ message: 'Password minimal 8 karakter.' });
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
      [name, email, hashedPassword]
      // $1, $2, $3 = parameterized query → mencegah SQL Injection
    );

    return res.status(201).json({ message: 'Akun berhasil dibuat.' });

  } catch (err) {
    // PostgreSQL unique violation code: 23505
    if (err.code === '23505') {
      return res.status(409).json({ message: 'Email sudah terdaftar.' });
    }
    console.error('[REGISTER ERROR]', err.message);
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
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ message: 'Email dan password wajib diisi.' });
  }

  try {
    const result = await db.query(
      'SELECT id, name, email, password_hash FROM users WHERE email = $1',
      [email]
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

    // Return user info — JANGAN sertakan password_hash!
    return res.json({ message: 'Login berhasil.', name: user.name, email: user.email });

  } catch (err) {
    console.error('[LOGIN ERROR]', err.message);
    return res.status(500).json({ message: 'Terjadi kesalahan server.' });
  }
});

// ── START SERVER ──────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`✅ Server running on port ${PORT}`);
  console.log(`   Environment : ${process.env.NODE_ENV || 'development'}`);
  console.log(`   DB Host     : ${process.env.DB_HOST || '(not set)'}`);
});
