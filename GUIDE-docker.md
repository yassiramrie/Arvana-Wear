#  Arvana Wear — Panduan Deployment dengan Docker

> **Catatan:** Panduan ini tetap mencakup Docker Compose untuk development dan
> latihan EC2. CI/CD aktif repository menggunakan OIDC, ECR, EKS, dan Argo CD;
> ikuti [Task-Arvana-Wear.md](./Task-Arvana-Wear.md) untuk deployment tersebut.

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
    │ (port 80)
    ▼
[Nginx container :80]  ← Serve index.html + proxy API request
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
1. Browser `fetch POST /login` → Nginx (port 80)
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
>
> Compose ini untuk development/lab. Untuk production gunakan database terkelola
> dengan TLS terverifikasi dan konfigurasi deployment sesuai `Task-Arvana-Wear.md`.

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
arvana-nginx          Up              0.0.0.0:80->80/tcp
vespa-postgres        Up (healthy)    0.0.0.0:5432->5432/tcp
vespa-node-exporter   Up              0.0.0.0:9100->9100/tcp
vespa-prometheus      Up              0.0.0.0:9090->9090/tcp
vespa-grafana         Up              0.0.0.0:3001->3000/tcp
```

### 1.4 Verifikasi Aplikasi Berjalan

```bash
# Health check app (via Nginx)
curl http://localhost/health
# Response: {"status":"ok"}

# Test register
curl -X POST http://localhost/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Test User","email":"test@email.com","password":"password123"}'
# Response: {"message":"Akun berhasil dibuat."}

# Test login
curl -X POST http://localhost/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@email.com","password":"password123"}'
# Response: {"message":"Login berhasil.","name":"Test User","email":"test@email.com"}
```

Buka browser:
- `http://localhost` → Frontend Arvana Wear
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
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
COPY --from=dependencies --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./
USER node
EXPOSE 3000
CMD ["node", "server.js"]
```

Build memakai dua stage: dependency produksi dipasang dengan lockfile, lalu
hanya dependency dan file runtime yang disalin ke image akhir. Proses berjalan
sebagai user non-root `node`; `.dockerignore` mencegah file lokal dan secret
ikut masuk build context.

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

## Langkah 3 — GitHub Actions dan GitOps

Workflow aktif tidak deploy melalui SSH ke EC2 dan tidak memerlukan access key
AWS statis atau secret deployment EC2. GitHub Actions memakai OIDC untuk
mendapatkan kredensial sementara, mengunggah image ke ECR, lalu membuat pull
request untuk memperbarui tag image di GitOps.

Setelah Terraform diterapkan, atur Actions Variables berikut di repository
(**Settings → Secrets and variables → Actions → Variables**):

- `AWS_ROLE_ARN`: output Terraform `github_actions_role_arn`.
- `AWS_REGION`: region deployment, default `ap-southeast-3`.

Aktifkan branch protection agar PR image-tag ditinjau sebelum merge. Argo CD
menyinkronkan perubahan setelah merge; secret aplikasi disimpan di AWS Secrets
Manager, bukan di GitHub. Lihat [panduan deployment utama](./Task-Arvana-Wear.md)
untuk langkah bootstrap, IAM, EKS, dan konfigurasi Argo CD.

### 3.4 Security Group EC2 untuk latihan

Buka port berikut di Security Group EC2:

| Port | Keterangan |
|------|------------|
| 22 | SSH (dari IP laptop kamu saja) |
| 80 | HTTP (redirect ke HTTPS setelah TLS diaktifkan) |
| 443 | HTTPS setelah domain dan sertifikat valid disiapkan |

> **Security Note:** Port `3001`, `9090`, dan `9100` tidak perlu dibuka ke internet.
> Grafana hanya bind ke localhost EC2. Akses dengan SSH tunnel:
> `ssh -i my-ec2-key.pem -L 3001:localhost:3001 ubuntu@IP_EC2_KAMU`

### Persiapan HTTPS untuk latihan EC2

Nginx lokal tetap memakai HTTP agar bisa dijalankan tanpa domain. Jangan kirim
kredensial atau token sungguhan melalui HTTP publik. Setelah domain diarahkan ke
EC2 dan sertifikat TLS valid tersedia:

1. Pasang `fullchain.pem` dan `privkey.pem` di direktori `certs/` pada host EC2.
   Jangan commit direktori atau private key tersebut.
2. Salin `nginx/nginx.tls.conf.example` menjadi konfigurasi yang dipakai
   Nginx (`nginx/nginx.conf`).
3. Pada service `nginx` di `docker-compose.yml`, publish port `443:443` dan
   mount `./certs:/etc/nginx/certs:ro`.
4. Jalankan ulang Nginx dan verifikasi HTTPS serta redirect dari HTTP sebelum
   menerima login atau registrasi publik.

Konfigurasi contoh mengalihkan seluruh HTTP ke HTTPS dan hanya menerima TLS
1.2/1.3. Jangan aktifkan sebelum sertifikat valid tersedia karena Nginx akan
gagal start tanpa file sertifikat.

---

## Langkah 4 — Alur workflow aktif (`deploy.yml`)

Pipeline berjalan pada pull request dan push ke branch `main`.

```
Push/PR → test, audit, validasi Terraform/Kubernetes
       → build dan Trivy scan image API/frontend
       → (push main) OIDC, push image immutable ke ECR
       → buat PR tag GitOps
       → (setelah merge) Argo CD sync ke EKS

---

## Langkah 5 — Setup Monitoring (Grafana)

Monitoring sudah jalan otomatis setelah `docker compose up -d`.
Kamu hanya perlu import dashboard di Grafana.

### 5.1 Import Dashboard Node Exporter

1. Buat SSH tunnel, lalu buka `http://localhost:3001` di laptop
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
| `curl: Connection refused` port 80 | Nginx container tidak jalan | `docker compose logs nginx` |
| App error `ECONNREFUSED 5432` | PostgreSQL belum ready | `docker compose logs postgres`, tunggu healthcheck |
| `relation "users" does not exist` | init.sql tidak jalan | `docker compose down -v` lalu `up -d` lagi |
| Container restart terus (restart loop) | Error di app/config | `docker compose logs app` |
| Grafana tidak bisa akses Prometheus | Network issue | `docker compose restart grafana` |
| `.env` tidak terbaca | File tidak ada | `cp .env.docker .env` |
| Workflow gagal mengambil kredensial AWS | `AWS_ROLE_ARN`, region, atau trust policy OIDC salah | Cocokkan Actions Variables dengan output Terraform dan repository/branch pada trust policy |

---

## Ringkasan Konsep DevSecOps yang Dipelajari

| Konsep | Implementasi |
|--------|-------------|
| **Containerization** | Semua service dikemas dalam Docker image — portable, reproducible |
| **Secrets Management** | Local Compose memakai `.env` yang tidak di-commit; EKS mengambil secret dari AWS Secrets Manager |
| **Service Discovery** | Docker DNS: container komunikasi via nama service, bukan IP |
| **Infrastructure as Code** | Seluruh stack terdefinisi di `docker-compose.yml` |
| **Health Check** | `depends_on + healthcheck` pastikan service start dalam urutan yang benar |
| **Data Persistence** | Docker volumes: data tidak hilang saat container restart |
| **Least Privilege** | Node Exporter hanya bisa diakses dari dalam Docker network |
| **Idempotency** | `docker compose up -d` aman dijalankan berkali-kali |
| **Observability** | Local Compose menyediakan Prometheus + Grafana; EKS memakai CloudWatch, Prometheus/Grafana, OpenTelemetry, dan X-Ray |


*Dibuat untuk tujuan pembelajaran DevSecOps. Happy hacking! 🧕*
