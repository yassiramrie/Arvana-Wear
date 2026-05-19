### 3.2 Security Group untuk EC2 (`arvana-wear-sg`)

| Tipe | Protokol | Port | Source | Keterangan |
|------|----------|------|--------|------------|
| SSH | TCP | 22 | IP Laptop kamu | Untuk remote server |
| HTTP | TCP | 80 | 0.0.0.0/0 | Web publik |
| Custom TCP | TCP | 3000 | 0.0.0.0/0 | Node.js API |

> **DevSecOps Note:** Port 22 (SSH) hanya buka dari IP kamu sendiri.
> Jika IP kamu dinamis (berubah-ubah), pertimbangkan AWS Systems Manager Session Manager
> sebagai alternatif SSH yang lebih aman (tidak perlu port 22 sama sekali).

### 3.3 Kenapa ini penting?

```
Internet → EC2 (port 80, 3000) ✅ boleh
Internet → RDS (port 5432)     ❌ TIDAK boleh
EC2      → RDS (port 5432)     ✅ boleh (EC2 SG sebagai source)
```

---

## Langkah 4 — Setup GitHub Secrets (Untuk CI/CD)

GitHub Secrets adalah tempat menyimpan kredensial sensitif yang dipakai GitHub Actions.
Tersimpan terenkripsi dan tidak pernah muncul di log.

### 4.1 Secret yang Diperlukan

| Secret Name | Nilai | Cara Mendapatkan |
...

```
Developer push ke branch main
        ↓
GitHub Actions aktif (deploy.yml)
        ↓
[Step 1] actions/checkout → ambil kode terbaru
        ↓
[Step 2] appleboy/scp-action → copy file ke EC2 via SCP
        ↓
[Step 3] appleboy/ssh-action → SSH ke EC2, jalankan commands:
          - Install Nginx (jika belum)
          - Copy index.html ke /var/www/html/
          - Restart Nginx
          - npm install & pm2 restart backend
```

> **DevSecOps Note:** Prinsip ini disebut **GitOps** — Git sebagai single source of truth.
> Setiap perubahan code otomatis terdeploy. Tidak ada deploy manual yang bisa lupa dicatat.

...
| Tipe | Protokol | Port | Source | Keterangan |
|------|----------|------|--------|------------|
| Custom TCP | TCP | 3001 | 0.0.0.0/0 | Grafana Dashboard |

> Port `9090` dan `9100` **JANGAN dibuka** ke internet — hanya Grafana yang perlu publik.

---

### 6.2 Buat System Users

Setiap service monitoring dijalankan sebagai user tersendiri (bukan root).
Ini adalah prinsip **Least Privilege** — service hanya punya akses yang benar-benar dibutuhkan.

```bash
# SSH ke EC2 dulu
ssh -i my-ec2-key.pem ubuntu@IP_EC2_KAMU

# Buat dedicated user untuk Prometheus (tanpa home directory, tanpa shell login)
sudo useradd --system --no-create-home --shell /bin/false prometheus

# Buat dedicated user untuk Node Exporter
sudo useradd --system --no-create-home --shell /bin/false node_exporter
```

---

### 6.3 Buat Direktori Data

```bash
# Direktori konfigurasi
...
| **Least Privilege** | Prometheus & Node Exporter bind ke `127.0.0.1` — tidak bisa diakses dari luar |
| **Dedicated Service Users** | Setiap service monitoring jalan sebagai user non-root tersendiri |

---

*Dibuat untuk tujuan pembelajaran DevSecOps. Happy hacking! 🧕*
