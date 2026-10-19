> **Catatan:** Panduan ini adalah latihan deployment EC2 manual, bukan workflow
> aktif repository. CI/CD sekarang menggunakan GitHub Actions OIDC, ECR, EKS, dan
> Argo CD. Lihat [Task-Arvana-Wear.md](./Task-Arvana-Wear.md) untuk panduan aktif.

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

## Langkah 4 — GitHub Actions dan GitOps (Deployment aktif)

Workflow aktif tidak memakai SSH/EC2 atau access key AWS statis. GitHub Actions
mendapatkan kredensial sementara melalui OIDC, membangun dan memindai image,
mengunggahnya ke ECR, lalu membuka pull request untuk memperbarui tag image GitOps.
Argo CD menerapkan perubahan setelah pull request tersebut di-merge.

Atur Actions Variables `AWS_ROLE_ARN` ke output Terraform
`github_actions_role_arn` dan `AWS_REGION` ke region deployment. Kredensial AWS
diberikan melalui OIDC; jangan menambahkan access key AWS atau private key EC2
sebagai GitHub Secret untuk workflow ini.

```
Developer push ke branch main
        ↓
GitHub Actions aktif (.github/workflows/deploy.yml)
        ↓
[Step 1] Test, audit dependency, validasi Terraform dan Kubernetes
        ↓
[Step 2] Build image API dan frontend; scan dengan Trivy
        ↓
[Step 3] OIDC → push image ke ECR dengan tag commit
        ↓
[Step 4] Buka PR perubahan tag GitOps; Argo CD sync setelah merge
```

Atur Actions Variables `AWS_ROLE_ARN` (output `github_actions_role_arn`) dan
`AWS_REGION` setelah Terraform diterapkan. Lihat
[panduan deployment utama](./Task-Arvana-Wear.md) untuk bootstrap, izin IAM,
konfigurasi Argo CD, dan secret aplikasi. Perubahan tag deployment tetap melalui
review dan merge PR GitOps.

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
