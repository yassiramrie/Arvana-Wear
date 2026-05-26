#  Arvana Wear — Panduan Deployment dengan Docker

> **Untuk siapa?** Developer yang sudah paham dasar-dasar DevSecOps dan ingin
> belajar containerization: menggantikan RDS, PM2, dan systemd dengan Docker.

---

## Apa yang Berubah dari Versi Sebelumnya?

| Sebelumnya (Non-Docker) | Sekarang (Docker) |
|------------------------|-------------------|
| PostgreSQL di AWS RDS | PostgreSQL container |
| Node.js dijalankan PM2 | App container |
| Nginx diinstall manual | Nginx container |
| Prometheus via systemd | Prometheus container |
| Node Exporter via systemd | Node Exporter container |
| Grafana via apt + systemd | Grafana container |
| 6 langkah setup manual | `docker compose up -d` |

---

## Gambaran Arsitektur

```
[Browser]
    │ (port 8888)
    ▼
[Nginx container :8888]  ← Serve index.html + proxy API request
    │
    ▼
[App container :3000]    ← Node.js / Express (server.js)
    │
    ▼
[PostgreSQL container :5432]  ← Database (ganti AWS RDS)


[Node Exporter :9100] ──→ [Prometheus :9090] ──→ [Grafana :3001]
     Metrics OS                  Storage              Dashboard
```

**Alur request login:**
1. Browser `fetch POST /login` → Nginx (port 8888)
2. Nginx proxy → App container (port 3000)
3. App query ke PostgreSQL container
4. Response kembali ke browser

**Kenapa semua service bisa saling komunikasi?**
Docker Compose membuat **internal network** otomatis. Setiap container bisa
resolve nama service lain seperti DNS. Contoh: app cukup tulis `DB_HOST=postgres`
dan Docker tahu harus ke container mana.

---

## Yang Kamu Butuhkan

- Docker Desktop (Windows/Mac) atau Docker Engine (Linux)
- Git

Verifikasi Docker terinstall:
```bash
docker --version          # Docker version 27.x.x
docker compose version    # Docker Compose version v2.x.x
```

> Tidak perlu install Node.js, PostgreSQL, Nginx, Prometheus, atau Grafana secara
> manual. Semua sudah dikemas dalam image Docker.

---

## Langkah 1 — Clone & Jalankan Lokal

### 1.1 Clone Repository

```bash
git clone https://github.com/USERNAME/arvana-wear.git
cd arvana-wear
```

### 1.2 Siapkan File Environment

```bash
cp .env.docker .env
```

File `.env` berisi password yang akan dibaca `docker-compose.yml`:

```env
DB_PASSWORD=arvana_secret            # Password PostgreSQL
GRAFANA_PASSWORD=admin123            # Password Grafana
```

> **Security Note:** File `.env` sudah ada di `.gitignore` — tidak akan pernah
> ter-commit ke GitHub. Jangan hardcode password langsung di kode.

### 1.3 Jalankan Semua Container

```bash
docker compose up -d
```

Flag `-d` = detached mode, container jalan di background.

Docker akan:
1. Pull image PostgreSQL, Nginx, Prometheus, Grafana, Node Exporter dari Docker Hub
2. Build image app Node.js dari `Dockerfile`
3. Start semua 6 container sekaligus
4. Jalankan `init.sql` otomatis untuk membuat tabel `users`

Cek status semua container:
```bash
docker compose ps
```

Output yang benar:
```
NAME                  STATUS          PORTS
vespa-app             Up              0.0.0.0:3000->3000/tcp
vespa-nginx           Up              0.0.0.0:8080->80/tcp
vespa-postgres        Up (healthy)    0.0.0.0:5432->5432/tcp
vespa-node-exporter   Up              0.0.0.0:9100->9100/tcp
vespa-prometheus      Up              0.0.0.0:9090->9090/tcp
vespa-grafana         Up              0.0.0.0:3001->3000/tcp
```

### 1.4 Verifikasi Aplikasi Berjalan

```bash
# Health check app (via Nginx)
curl http://localhost:8080/health
# Response: {"status":"ok"}

# Test register
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Test User","email":"test@email.com","password":"password123"}'
# Response: {"message":"Akun berhasil dibuat."}

# Test login
curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@email.com","password":"password123"}'
# Response: {"message":"Login berhasil.","name":"Test User","email":"test@email.com"}
```

Buka browser:
- `http://localhost:8080` → Frontend Vespa Catalog
- `http://localhost:9090` → Prometheus
- `http://localhost:3001` → Grafana (admin / admin123)

---

## Langkah 2 — Memahami Struktur File Docker

```
arvana-wear/
│
├── Dockerfile              ← Instruksi build image Node.js app
├── docker-compose.yml      ← Orkestrasi semua 6 container
├── .dockerignore           ← File yang tidak ikut masuk image
├── .env.docker             ← Template environment (copy ke .env)
│
├── nginx/
│   └── nginx.conf          ← Config Nginx: serve HTML + proxy API
│
└── monitoring/
    └── prometheus.yml      ← Config scrape targets Prometheus
    └── grafana/
        └── provisioning/
            ├── datasources/
            │   └── datasources.yml   ← Auto-register Prometheus ke Grafana
            └── dashboards/
                └── dashboards.yml   ← Auto-load dashboard
```

### Bagaimana `Dockerfile` Bekerja?

```dockerfile
FROM node:20-alpine       # Base image: Node.js 20 ukuran kecil (~50MB)

WORKDIR /app              # Set direktori kerja di dalam container

COPY package*.json ./     # Copy package.json DULU (bukan semua kode)
RUN npm install           # Install dependency

COPY . .                  # Baru copy seluruh kode

EXPOSE 3000               # Declare port yang dipakai
CMD ["node", "server.js"] # Perintah yang dijalankan saat container start
```

> **Kenapa `package.json` di-copy dulu?** Docker punya layer cache. Selama
> `package.json` tidak berubah, layer `npm install` di-cache dan build
> jadi jauh lebih cepat. Kalau semua file di-copy sekaligus, setiap perubahan
> kode kecil akan trigger `npm install` ulang.

### Bagaimana `docker-compose.yml` Bekerja?

Setiap service di `docker-compose.yml` adalah satu container. Contoh service `app`:

```yaml
app:
  build: .                  # Build image dari Dockerfile di folder ini
  environment:
    DB_HOST: postgres        # Nama service lain = hostname di Docker network
    DB_PASSWORD: ${DB_PASSWORD}  # Baca dari file .env
  depends_on:
    postgres:
      condition: service_healthy  # Tunggu postgres ready sebelum app start
```

---

## Langkah 3 — Setup GitHub Secrets untuk CI/CD

GitHub Secrets adalah tempat menyimpan kredensial sensitif. Pipeline CI/CD
membaca secrets ini untuk deploy ke EC2 tanpa menyimpan password di kode.

### 3.1 Secret yang Diperlukan

| Secret Name | Nilai | Cara Mendapatkan |
|-------------|-------|-----------------|
| `EC2_HOST` | IP publik EC2 | EC2 Console → instance → Public IPv4 |
| `EC2_USER` | `ubuntu` | Default untuk AMI Ubuntu |
| `EC2_SSH_KEY` | Isi file `.pem` | Paste seluruh isi file key pair |
| `DB_PASSWORD` | Password PostgreSQL | Bebas, minimal 12 karakter |
| `GRAFANA_PASSWORD` | Password Grafana | Bebas, minimal 12 karakter |

Hanya 5 secret — jauh lebih sedikit dari versi non-Docker yang butuh 9 secret.

### 3.2 Cara Menambah Secret

1. Buka repo GitHub kamu
2. **Settings** → **Secrets and variables** → **Actions**
3. Klik **New repository secret**
4. Isi **Name** dan **Value** → **Add secret**

Untuk `EC2_SSH_KEY`:
```bash
# Tampilkan isi file .pem di terminal
cat my-ec2-key.pem
# Copy SEMUA outputnya termasuk baris -----BEGIN RSA PRIVATE KEY-----
```

### 3.3 Security Group EC2

Buka port berikut di Security Group EC2:

| Port | Keterangan |
|------|------------|
| 22 | SSH (dari IP laptop kamu saja) |
| 8888 | Frontend + API via Nginx |
| 3001 | Grafana Dashboard |
| 9090 | Prometheus (opsional, bisa tutup) |

> **Security Note:** Port `9100` (Node Exporter) **jangan dibuka** ke internet.
> Node Exporter hanya diakses oleh Prometheus dari dalam Docker network.

---

## Langkah 4 — CI/CD Pipeline (deploy.yml)

Pipeline berjalan otomatis setiap kamu push ke branch `main`.

```
Push ke main
      │
      ▼
[JOB 1: test]  ← Jalan di GitHub cloud runner
  ├── node --check server.js    (syntax check)
  ├── node -e "require('./package.json')"  (validasi JSON)
  └── npm audit --audit-level=high  (security scan)
      │
      │  (hanya lanjut kalau test PASS)
      ▼
[JOB 2: deploy]  ← Jalan di GitHub cloud runner, tapi SSH ke EC2 kamu
  ├── SCP semua file ke EC2 (~/arvana-wear/)
  ├── SSH: install Docker jika belum ada
  ├── SSH: tulis .env dari GitHub Secrets
  ├── SSH: docker compose up -d --build
  └── SSH: curl health check ke localhost:8888/health
```

**Kenapa `env` + `envs` di pipeline?**

```yaml
- name: Deploy via Docker Compose
  uses: appleboy/ssh-action@v1.0.3
  env:
    DB_PASSWORD: ${{ secrets.DB_PASSWORD }}   # ← declare di level action
  with:
    envs: DB_PASSWORD                         # ← kirim ke dalam shell SSH
    script: |
      echo "${DB_PASSWORD}" > .env            # ← aman, tidak muncul di log
```

Secret tidak bisa langsung ditulis di `script` karena akan muncul di log GitHub.
Dengan `env` + `envs`, secret dikirim sebagai environment variable ke SSH session.

---

## Langkah 5 — Setup Monitoring (Grafana)

Monitoring sudah jalan otomatis setelah `docker compose up -d`.
Kamu hanya perlu import dashboard di Grafana.

### 5.1 Import Dashboard Node Exporter

1. Buka `http://localhost:3001` (atau `http://IP_EC2:3001`)
2. Login: **admin** / password yang kamu set
3. Klik **Dashboards** → **New** → **Import**
4. Isi **Dashboard ID:** `1860` → klik **Load**
5. Pilih datasource: **Prometheus** → klik **Import**

Kamu sekarang punya dashboard dengan:
- CPU usage per core
- Memory usage (RAM & swap)
- Disk I/O & available space
- Network throughput

### 5.2 Kenapa Grafana Langsung Terhubung ke Prometheus?

Karena ada file `monitoring/grafana/provisioning/datasources/datasources.yml`:

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090   # ← nama service Docker, bukan IP
    isDefault: true
```

Grafana membaca file ini saat startup → Prometheus otomatis terdaftar sebagai
datasource tanpa perlu setting manual di UI.

---

## Perintah Docker yang Sering Dipakai

```bash
# Jalankan semua container
docker compose up -d

# Stop semua container (data tetap tersimpan di volume)
docker compose down

# Stop + hapus semua data (volume ikut terhapus)
docker compose down -v

# Rebuild image app setelah ada perubahan kode
docker compose up -d --build app

# Lihat log container tertentu (real-time)
docker compose logs -f app
docker compose logs -f postgres

# Masuk ke dalam container (seperti SSH)
docker compose exec app sh
docker compose exec postgres psql -U postgres -d arvana_wear

# Lihat status semua container
docker compose ps

# Restart satu container
docker compose restart app
```

---

## Troubleshooting Cepat

| Masalah | Kemungkinan Penyebab | Solusi |
|---------|---------------------|--------|
| `curl: Connection refused` port 8888 | Nginx container tidak jalan | `docker compose logs nginx` |
| App error `ECONNREFUSED 5432` | PostgreSQL belum ready | `docker compose logs postgres`, tunggu healthcheck |
| `relation "users" does not exist` | init.sql tidak jalan | `docker compose down -v` lalu `up -d` lagi |
| Container restart terus (restart loop) | Error di app/config | `docker compose logs app` |
| Grafana tidak bisa akses Prometheus | Network issue | `docker compose restart grafana` |
| `.env` tidak terbaca | File tidak ada | `cp .env.docker .env` |
| Pipeline gagal di step SCP | File `.dockerignore` terlalu agresif | Pastikan semua file ter-copy |

---

## Ringkasan Konsep DevSecOps yang Dipelajari

| Konsep | Implementasi |
|--------|-------------|
| **Containerization** | Semua service dikemas dalam Docker image — portable, reproducible |
| **Secrets Management** | `.env` tidak di-commit, CI/CD inject dari GitHub Secrets |
| **Service Discovery** | Docker DNS: container komunikasi via nama service, bukan IP |
| **Infrastructure as Code** | Seluruh stack terdefinisi di `docker-compose.yml` |
| **Health Check** | `depends_on + healthcheck` pastikan service start dalam urutan yang benar |
| **Data Persistence** | Docker volumes: data tidak hilang saat container restart |
| **Least Privilege** | Node Exporter hanya bisa diakses dari dalam Docker network |
| **Idempotency** | `docker compose up -d` aman dijalankan berkali-kali |
| **Observability** | Prometheus + Grafana jalan otomatis dalam satu stack yang sama |


*Dibuat untuk tujuan pembelajaran DevSecOps. Happy hacking! 🧕*
