# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile — Arvana Wear API
# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage? No — app ini kecil, single stage sudah cukup.
# Base image: node:20-alpine (kecil ~50MB, cocok untuk production)
# ─────────────────────────────────────────────────────────────────────────────

FROM node:20-alpine

# Set working directory di dalam container
WORKDIR /app

# ── INSTALL SYSTEM DEPENDENCIES ───────────────────────────────────────────────
RUN apk add --no-cache curl

# ── INSTALL DEPENDENCIES ──────────────────────────────────────────────────────
# Copy package.json & package-lock.json dulu (bukan seluruh kode).
# Trik ini memanfaatkan Docker layer caching:
#   - Kalau kode berubah tapi package.json tidak → layer npm install di-cache,
#     build jadi jauh lebih cepat.
COPY package*.json ./
RUN npm install --omit=dev

# ── COPY SOURCE CODE ──────────────────────────────────────────────────────────
# Copy setelah npm install supaya cache layer di atas tidak invalid tiap kode berubah.
COPY . .

# ── EXPOSE & START ────────────────────────────────────────────────────────────
# Expose port yang digunakan app (sama dengan PORT di .env)
EXPOSE 3000

# Jalankan server saat container start
CMD ["node", "server.js"]
