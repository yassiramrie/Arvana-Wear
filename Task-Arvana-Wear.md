# Task Arvana Wear — Panduan Infrastruktur AWS, CI/CD, dan GitOps

Panduan ini menjelaskan cara membawa Arvana Wear dari aplikasi lokal ke layanan AWS yang dapat diakses pengguna. Urutannya dibuat bertahap supaya setiap lapisan bisa diuji sebelum menambah kompleksitas berikutnya.

> **Jangan membuat semua layanan sekaligus.** EKS, ECS, RDS, load balancer, NAT Gateway, dan monitoring dapat menimbulkan biaya berkelanjutan. Mulai di development, aktifkan AWS Budget, dan verifikasi estimasi biaya sebelum `terraform apply`.

## 1. Tujuan akhir dan arsitektur

```text
Developer
  │ push / pull request
  ▼
GitHub Actions: test → build → Trivy scan → push image
  │                                      │
  │                                      ▼
  │                               Amazon ECR (registry)
  │                                      │
  └── usulkan perubahan repo GitOps      │ image tag immutable
                 │                       │
                 ▼                       ▼
              Argo CD ── sinkronisasi ──► EKS ── pull image dari ECR
                                          │
Internet ── NLB HTTP (development) ──────┤
                                          ├── frontend / Nginx
                                          └── API ──► Amazon RDS private

Terraform ──► VPC, IAM/OIDC, ECR, EKS, RDS, Secrets Manager
Terraform state ──► S3 versioned + native lockfile
CloudWatch Container Insights + OpenTelemetry ──► X-Ray
Prometheus ──► Grafana ◄── CloudWatch / X-Ray
```

EKS dipilih untuk environment development ini. Untuk dev, frontend diakses melalui HTTP pada DNS publik Network Load Balancer (NLB), bukan IP publik EC2. Worker EC2 EKS berada di subnet private dan tidak menjadi endpoint aplikasi. HTTP tidak mengenkripsi traffic; jangan kirim data atau kredensial sensitif dan siapkan domain/ACM/HTTPS sebelum production.

## 2. Kondisi repo saat ini

Repo ini sudah memiliki:

- API Node.js/Express di `server.js`.
- `Dockerfile` dan `.dockerignore`.
- `docker-compose.yml` untuk pengembangan dan layanan pendamping.
- Nginx, Prometheus, Grafana, dan konfigurasi monitoring.
- Workflow GitHub Actions di `.github/workflows/deploy.yml` untuk test, build, scan Trivy, dan publish image ke ECR.
- Fondasi Terraform development untuk VPC, EKS managed node group, RDS PostgreSQL, ECR, IAM OIDC, Secrets Manager, dan S3 remote state.
- Manifest Kustomize untuk frontend/API, HPA, PodDisruptionBudget, migrasi database, Argo CD, dan AWS Load Balancer Controller.
- OpenTelemetry pada API serta konfigurasi CloudWatch, Prometheus, dan Grafana.

Terraform dan GitOps adalah konfigurasi deployment yang harus selalu dijalankan memakai backend/state environment yang sama. Beberapa resource AWS development sudah dibuat selama release ini; jangan menginisialisasi state baru atau mengulang apply dari state lokal kosong.

Sebelum produksi, perhatikan beberapa hal:

1. Script `test` sudah tersedia. Tes mencakup health/readiness, validasi input, batas ukuran request, dan konfigurasi produksi. Script `build` belum diperlukan karena aplikasi tidak memiliki proses kompilasi.
2. Frontend Nginx dan API Express dibangun sebagai image/service terpisah. Nginx meneruskan path API ke Service Kubernetes `arvana-api`.
3. Nginx meneruskan `/health`, `/ready`, `/api/health`, `/register`, dan `/login` ke API.
4. Konfigurasi production API mewajibkan `JWT_SECRET` minimal 32 byte, origin CORS eksplisit, konfigurasi database, dan koneksi database `DB_SSL=verify-full` dengan CA certificate. Secret harus disediakan melalui AWS Secrets Manager atau mekanisme secret terkelola lainnya, bukan image atau Git.
5. API membatasi JSON request hingga 16 KB, memvalidasi field register/login, dan mengatur batas connection pool melalui `DB_POOL_MAX`. Tentukan ukuran pool berdasarkan jumlah replika dan kapasitas database.
6. Untuk produksi, gunakan Amazon RDS di private subnet alih-alih database container. Siapkan migration database yang terkendali; jangan mengandalkan script inisialisasi container untuk upgrade skema.
7. API sekarang memisahkan **liveness** (`/health`, hanya memeriksa proses) dan **readiness** (`/ready` atau `/api/health`, memeriksa koneksi database). Readiness mengembalikan HTTP 503 saat database belum tersedia; jangan gunakan readiness sebagai liveness agar gangguan DB sementara tidak memicu restart pod berulang.

## 3. Tahap pertama — persiapan akun dan aplikasi

### 3.1 Persiapan AWS

1. Pilih AWS account dan region untuk development.
2. Aktifkan MFA untuk pengguna manusia dan jangan gunakan root account untuk operasi harian.
3. Gunakan IAM Identity Center/SSO atau role dengan least privilege. Hindari access key permanen di laptop atau GitHub.
4. Buat AWS Budget dan alarm biaya.
5. Pastikan file `.env`, private key, Terraform state, password database, token, dan secret aplikasi diabaikan oleh Git.
6. Pasang AWS CLI, Terraform, Docker, `kubectl`, dan Helm. Verifikasi versi dan akses AWS sebelum provisioning.

### 3.2 Persiapan aplikasi

Sebelum membuat image cloud:

- Perluas unit test dan integration test untuk API, autentikasi, serta koneksi database. Tes saat ini masih berupa cakupan dasar readiness dan validasi input.
- Endpoint liveness/readiness dasar sudah tersedia; sebelum produksi, tentukan timeout, interval, dan ambang probe untuk platform runtime.
- Validasi input dan batasi ukuran request.
- Tulis log terstruktur ke stdout/stderr; jangan tulis password, token, atau data sensitif ke log.
- Tetapkan batas connection pool berdasarkan jumlah replika dan kapasitas database. Perkiraan koneksi maksimum adalah jumlah replika dikali ukuran pool per replika.
- Batasi CORS pada domain aplikasi di produksi; jangan gunakan `*` bila tidak diperlukan.
- Buat konfigurasi produksi gagal secara jelas jika secret wajib tidak tersedia.

Gerbang awal yang dituju:

```text
npm ci
npm test
npm audit --audit-level=high
```

Tes menggunakan test runner bawaan Node.js (`node --test`). Jalankan pada Node.js yang kompatibel dengan versi proyek. Tes saat ini mencakup liveness, readiness saat database tersedia/tidak tersedia, alias health API, dan input wajib register/login.

## 4. Tahap kedua — image Docker multi-stage dan Trivy

### 4.1 Bangun image runtime minimal

Dockerfile repo menggunakan multi-stage untuk memisahkan pemasangan dependency produksi dari runtime. Aplikasi tidak memerlukan proses compile/build.

Image API saat ini:

```dockerfile
FROM node:22-alpine AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000

COPY --from=dependencies --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./

USER node
EXPOSE 3000
CMD ["node", "server.js"]
```

Catatan:

- Node.js 22 dipakai sebagai versi runtime yang sama dengan CI. Base image dipin berdasarkan digest yang diuji; perbarui digest setelah build dan scan versi baru.
- Jangan copy `.env`, `.git`, `node_modules` lokal, credential, atau Terraform state ke dalam build context/image.
- Proses runtime berjalan sebagai user non-root `node`.
- Image runtime menghapus npm/Corepack bawaan yang tidak dipakai aplikasi.
- Tambahkan health check Docker bila sesuai. ECS/Kubernetes juga membutuhkan pemeriksaan health di level platform.
- Jika frontend tetap disajikan Nginx, bangun image frontend/Nginx terpisah dan tentukan routing ke API.
- Untuk production, set `NODE_ENV=production`, `CORS_ORIGIN` ke origin frontend, `DB_SSL=verify-full`, dan `DB_SSL_CA` ke path CA certificate yang dipasang dari secret/volume terkelola.
- `docker-compose.yml` dan `.env.docker` disiapkan untuk development lokal dengan database container tanpa TLS. Jangan gunakan profil itu sebagai production RDS deployment.

Build dan uji lokal melalui PowerShell:

```powershell
docker build -t arvana-api:dev .
docker run --rm -p 3000:3000 --env-file .env arvana-api:dev
```

Lalu periksa endpoint health, API, log, user proses, dan bahwa secret tidak ada di layer image.

### 4.2 Scan image dengan Trivy

```powershell
trivy image --severity HIGH,CRITICAL --exit-code 1 arvana-api:dev
```

Jika scan menemukan kerentanan:

1. Tentukan apakah paket bermasalah berasal dari OS image atau dependency Node.
2. Upgrade base image atau dependency ke versi aman yang kompatibel.
3. Rebuild dan jalankan scan ulang.
4. Jangan mengabaikan temuan hanya supaya pipeline hijau. Pengecualian harus punya justifikasi, pemilik, dan tanggal review.

ECR juga menyediakan pemindaian image; enhanced scanning terintegrasi dengan Amazon Inspector dan dapat memperbarui hasil saat temuan baru muncul. Trivy dapat tetap menjadi gerbang CI. Lihat [dokumentasi pemindaian image ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html).

## 5. Tahap ketiga — Terraform dan remote state

### 5.1 Buat backend state terlebih dahulu

Buat bucket S3 khusus Terraform state dengan:

- Block Public Access.
- Versioning aktif.
- Enkripsi aktif.
- Hak akses IAM yang dibatasi.
- Key state terpisah per environment, misalnya `dev/arvana/terraform.tfstate` dan `prod/arvana/terraform.tfstate`.

Bootstrap bucket dilakukan terpisah dari stack yang memakai bucket tersebut. Simpan konfigurasi bootstrap dan ownership-nya dengan jelas agar bucket state tidak terhapus tanpa sengaja.

#### Mekanisme locking

Terraform backend S3 versi modern mendukung native S3 lockfile dengan `use_lockfile = true`. DynamoDB locking tersedia di versi tertentu tetapi sudah deprecated di dokumentasi Terraform terkini. Karena permintaan awal menyebut DynamoDB:

- Konfirmasi versi Terraform yang akan dipakai dan kebijakan tim.
- Jika memilih mekanisme modern, gunakan S3 lockfile.
- Jika organisasi mewajibkan DynamoDB, ikuti dokumentasi versi Terraform yang dipin dan siapkan tabel DynamoDB dengan partition key `LockID` bertipe string.
- Jangan menganggap DynamoDB dan S3 lockfile harus selalu digunakan bersama.

Contoh backend S3 dengan lockfile:

```hcl
terraform {
  backend "s3" {
    bucket       = "nama-bucket-state-khusus"
    key          = "dev/arvana/terraform.tfstate"
    region       = "ap-southeast-3"
    encrypt      = true
    use_lockfile = true
  }
}
```

Jangan menaruh kredensial AWS dalam konfigurasi backend. Gunakan AWS SSO/profile secara lokal dan role saat CI. Terraform state dapat mengandung data sensitif meskipun output CLI menyamarkannya.

Perintah dasar di direktori environment:

```powershell
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
```

Tinjau plan sebelum `terraform apply`. Jika memindahkan state lokal yang sudah ada, backup state dan ikuti prosedur migrasi backend Terraform; jangan menimpa state secara tebakan.

### 5.2 Struktur repo

```text
infra/
  bootstrap-state/
  terraform/
    main.tf
    variables.tf
    outputs.tf
    backend.hcl.example
    dev.tfvars.example
gitops/
  bootstrap/
  applications/
  apps/
    arvana/
      dev/
      staging/
      prod/
```

Saat ini stack Terraform disimpan dalam satu root per environment. Pisahkan state dan salin konfigurasi environment sebelum membuat staging/production; jangan gunakan state development bersama.

### 5.3 Provision jaringan dan database

Infrastruktur inti umumnya mencakup:

- VPC dengan Availability Zones yang memadai.
- Public subnet untuk ALB; private subnet untuk aplikasi, node, dan database.
- NAT Gateway atau VPC endpoints berdasarkan kebutuhan konektivitas dan anggaran. NAT Gateway menambah biaya.
- Security Groups dengan akses minimum:
  - Internet ke NLB development: HTTP 80.
  - NLB ke service frontend: hanya port target yang diperlukan.
  - Aplikasi ke RDS: hanya port database dari security group aplikasi.
  - Tidak ada akses publik langsung ke RDS.
- Amazon RDS dengan enkripsi, backup, retensi, pemantauan, dan Multi-AZ sesuai target ketersediaan.
- ECR repository, IAM roles, logging, dan alarm.

Security Group bersifat stateful; Network ACL bersifat stateless dan diterapkan pada subnet. Mulai dengan security groups yang ketat. Tambahkan NACL bila ada kebutuhan spesifik, bukan sebagai pengganti kontrol lainnya.

Alur kerja:

```powershell
terraform plan
# Tinjau perubahan resource, network exposure, IAM, dan biaya.
terraform apply
```

Untuk staging/production, gunakan pull request dan review plan sebelum apply.

### 5.4 Provision development pertama kali

Perintah berikut hanya dijalankan setelah memilih akun AWS, memeriksa budget, dan menetapkan CIDR IP tepercaya. NAT Gateway, EKS control plane/node, RDS, load balancer, CloudWatch, serta penyimpanan telemetry menimbulkan biaya.

1. Bootstrap bucket state dengan AWS SSO/profile yang sudah aktif:

   ```bash
   cd infra/bootstrap-state
   terraform init
   terraform apply
   terraform output -raw state_bucket
   ```

   Simpan nama bucket dari output. Bucket memiliki versioning, enkripsi, Block Public Access, kebijakan TLS, dan perlindungan `prevent_destroy`.

2. Konfigurasikan backend dan variable development:

   ```bash
   cd ../terraform
   cp backend.hcl.example backend.hcl
   cp dev.tfvars.example dev.tfvars
   ```

   Edit `backend.hcl` dengan nama bucket bootstrap. Pada `dev.tfvars`, isi `cluster_endpoint_public_access_cidrs` dengan IP publik statis yang dipercaya, misalnya `["203.0.113.10/32"]` sebagai format saja. Untuk awal, `application_origin` memakai `http://localhost`; jangan membuka endpoint EKS ke `0.0.0.0/0`.

3. Tinjau plan sebelum membuat resource:

   ```bash
   terraform init -backend-config=backend.hcl
   terraform fmt -check -recursive
   terraform validate
   terraform plan -var-file=dev.tfvars
   ```

   Bila plan sudah direview dan biaya disetujui, barulah jalankan `terraform apply -var-file=dev.tfvars`. Development default menonaktifkan automated RDS backup agar kompatibel dengan akun free-tier; data database tidak bisa dipulihkan lewat point-in-time restore. Untuk environment yang perlu pemulihan, set `database_backup_retention_period` ke 1-35 hari setelah memastikan batas akun dan biaya. Password RDS admin, password user aplikasi terbatas, dan JWT dibuat acak dan dikirim ke Secrets Manager. Hanya migration Job yang menerima secret admin; API memakai user aplikasi. State Terraform tetap mengandung nilai sensitif; lindungi bucket dan IAM.

4. Catat output `github_actions_role_arn`, `external_secrets_role_arn`, `cluster_autoscaler_role_arn`, `otel_collector_role_arn`, `grafana_role_arn`, dan `vpc_id`. Ganti placeholder role ARN yang sesuai di `gitops/applications/*.yaml` serta VPC ID pada `gitops/applications/aws-load-balancer-controller.yaml`. Terraform membuat Pod Identity association dan kebijakan IAM resmi untuk AWS Load Balancer Controller; ExternalSecret mengambil nama secret `arvana/dev/application` dan `arvana/dev/database-admin`. Secret database admin hanya dipasang ke migration Job, sementara API memakai user database dengan izin terbatas.

5. Di GitHub repository, buat Actions Variables `AWS_ROLE_ARN` dan `AWS_REGION=ap-southeast-3`. `AWS_ROLE_ARN` harus memakai output Terraform. Pipeline memakai OIDC; jangan buat access key AWS permanen. Workflow membuat PR image-tag menggunakan `GITHUB_TOKEN` dengan izin terbatas ke job publish, lalu merender ulang seluruh root Kustomize sebelum membuka PR. Karena GitHub tidak memicu workflow lain untuk PR yang dibuat memakai `GITHUB_TOKEN`, validasi manifest tersebut dilakukan langsung di job publish; workflow validasi biasa tetap berjalan pada push dan PR yang dibuat pengguna.

6. Buat kubeconfig, pasang Argo CD, lalu daftarkan repository:

   ```bash
   aws eks update-kubeconfig --region ap-southeast-3 --name arvana-wear-dev
   bash gitops/bootstrap/install-argocd.sh
   kubectl apply -f gitops/applications/external-secrets.yaml
   kubectl -n external-secrets rollout status deployment/external-secrets
   kubectl apply -f gitops/bootstrap/root-application.yaml
   kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=10m
   ```

   Argo CD dipasang dengan manifest non-HA untuk ukuran cluster development. Ganti nama cluster jika `name_prefix` atau `environment` diubah. Jika repository GitHub private, tambahkan credential read-only Argo CD sebagai Secret Kubernetes—jangan simpan token di manifest.

7. Setelah pipeline publish image dan membuat pull request perubahan GitOps, review lalu merge PR tersebut. Argo CD akan menyinkronkan tag commit yang immutable.

Repo ini menggunakan `Service type=LoadBalancer` yang membuat NLB publik untuk endpoint HTTP development. Setelah Argo CD menerapkan frontend, tunggu alamat NLB tersedia lalu ambil hostname:

```bash
kubectl -n arvana get service arvana-frontend -w
kubectl -n arvana get service arvana-frontend \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

Buka `http://<hostname-NLB>` di browser; alamat yang ditampilkan adalah DNS NLB, bukan IP publik EC2. Agar origin API cocok, masukkan `application_origin = "http://<hostname-NLB>"` (tanpa tanda `< >`) ke `dev.tfvars`, lalu jalankan `terraform plan -var-file=dev.tfvars` dan tinjau sebelum `terraform apply -var-file=dev.tfvars`. Setelah External Secrets memperbarui secret (interval maksimum satu jam), restart API agar environment variable baru dimuat:

```bash
kubectl -n arvana rollout restart deployment/arvana-api
kubectl -n arvana rollout status deployment/arvana-api
```

Endpoint HTTP ini hanya untuk development; traffic tidak dienkripsi. DNS domain, HTTPS/ACM, dan AWS Load Balancer Controller untuk HTTPS belum dikonfigurasi; jangan gunakan endpoint sementara ini sebagai konfigurasi production.

## 6. Tahap keempat — Amazon EKS (jalur yang dipilih)

Stack Terraform menyediakan EKS control plane, managed node group pada private subnet, endpoint API publik yang dibatasi CIDR, log audit/control plane, ECR, RDS private, Secrets Manager, dan role IAM/OIDC. Nilai min/desired/max node dan node autoscaler dapat disesuaikan sebelum apply.

Manifest GitOps memasang Metrics Server dan Cluster Autoscaler, menjalankan dua replika awal API/frontend, HPA, PodDisruptionBudget, probes, serta batas CPU/memory. External Secrets Operator mengambil konfigurasi runtime dari AWS Secrets Manager. Jangan masukkan secret Kubernetes plaintext ke repo.

Load balancer starter hanya HTTP untuk development. Untuk production, tambahkan AWS Load Balancer Controller, listener HTTPS/ACM, DNS, kebijakan ingress yang diperlukan, dan pertimbangkan node/database Multi-AZ. Rencanakan upgrade Kubernetes, node, add-on, dan biaya sebelum menggunakan environment production. Jangan kirim password atau data pengguna melalui endpoint HTTP.

AWS EKS Best Practices Guide mencakup keamanan, keandalan, jaringan, autoscaling, upgrade, dan biaya: [EKS Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html).

**Urutan yang aman:** mulai di development, verifikasi endpoint dan health, lalu lakukan uji HPA/node scaling sebelum menambah beban atau beralih ke production.

## 7. Tahap kelima — GitHub Actions, ECR, dan Argo CD

### 7.1 CI untuk Pull Request

Workflow mengikuti pola di `dhoclo.md`—validasi sebelum publikasi, image di ECR, lalu GitOps/Argo CD—dengan pemeriksaan yang disesuaikan untuk aplikasi Arvana Wear. Arvana menggunakan Node.js, frontend Nginx, dan PostgreSQL, bukan Task API Go; karena itu CI menjalankan unit test dan `npm audit`, Trivy memindai kedua image, dan OWASP ZAP Baseline menjalankan DAST terhadap stack sementara di runner. Tidak digunakan `gosec` atau aplikasi Go dari contoh.

Workflow aplikasi memeriksa setiap PR dengan izin baca saja; job publikasi terpisah dan hanya berjalan pada push `main` setelah verifikasi serta DAST sukses. Kredensial AWS OIDC baru diminta setelah image selesai dibangun dan dipindai. Workflow GitOps terpisah memvalidasi YAML dan merender Kustomize. Wajibkan status check **Test and scan images**, **DAST with OWASP ZAP**, serta **Validate GitOps YAML and Kustomize** pada branch protection.

Workflow PR aplikasi memeriksa:

1. Checkout source dan setup Node.js 22.
2. `npm ci`, jalankan tes aplikasi, pemeriksaan sintaks, dan audit dependency.
3. Validasi Terraform dan render manifest Kubernetes.
4. Build image API dan frontend; gagalkan build untuk temuan Trivy HIGH/CRITICAL.
5. Jalankan PostgreSQL, API, dan frontend sementara di runner, lalu lakukan ZAP Baseline scan. Environment dan database tersebut hanya untuk CI, bukan data production.
6. PR tidak mendapat izin OIDC dan tidak mengakses/deploy ke AWS.

### 7.2 Rilis image setelah merge

Setelah merge ke branch utama:

1. Semua pemeriksaan source, image, dan DAST harus lulus sebelum job publikasi mulai.
2. Job publikasi membangun dan memindai ulang image API/frontend sebelum push.
3. Tag image dengan commit SHA; hindari memakai `latest` sebagai identitas deployment.
4. Job publikasi memakai OIDC untuk login dan push image ke ECR.
5. Workflow membuka PR GitOps dengan tag SHA; pemeriksaan CI berjalan sebelum review/merge. Ini sengaja memakai PR, bukan commit langsung oleh workflow ke `main`, agar versi yang dirilis dapat ditinjau.
6. Argo CD mendeteksi perubahan Git yang sudah di-merge dan menyelaraskan cluster.

Gunakan GitHub Actions OIDC untuk memperoleh AWS role sementara. Hindari access key jangka panjang di GitHub Secrets. Trust policy role harus dibatasi ke repo, branch/environment, dan workflow yang diizinkan. Role CI cukup diberi izin ECR push serta akses terbatas untuk mengajukan perubahan GitOps—bukan hak administrator AWS.

Alur ringkas:

```text
PR: test → build → Trivy scan
Merge: test → build → scan → push ECR dengan tag SHA
                                 └── PR update manifest GitOps
GitOps merge → Argo CD sync → workload di EKS diperbarui
```

### 7.3 GitOps dengan Argo CD

- Pasang Argo CD pada EKS melalui prosedur bootstrap yang terdokumentasi.
- Simpan Deployment, Service, Ingress, autoscaling, dan konfigurasi environment di repo GitOps.
- Berikan Argo CD akses read-only ke repo melalui mekanisme credential yang aman.
- Mulai dengan manual sync di development; aktifkan automated sync setelah alur teruji.
- Lindungi UI/API Argo CD dengan autentikasi dan kontrol akses. Jangan membukanya ke internet secara langsung tanpa perlindungan.
- Rollback dilakukan dengan revert perubahan manifest/tag di Git; Argo CD mengembalikan cluster ke versi yang dideklarasikan.

## 8. Tahap keenam — observability dan alert

### 8.1 CloudWatch

EKS add-on CloudWatch Observability dan role node mengirim log/metric container ke CloudWatch. Pantau:

- CPU/memory ECS task atau node EKS.
- ALB: request, latency, target health, dan error response.
- RDS: CPU, jumlah koneksi, storage, dan event/failover.
- Log aplikasi dan error deployment.
- Alarm untuk kapasitas atau error yang melampaui ambang.

Metrik disk OS tidak selalu tersedia otomatis untuk semua compute; gunakan CloudWatch Agent atau collector yang sesuai jika dibutuhkan.

### 8.2 Prometheus, Grafana, dan OpenTelemetry

1. API mengaktifkan auto-instrumentation OpenTelemetry bila `OTEL_EXPORTER_OTLP_ENDPOINT` diatur.
2. OpenTelemetry Collector menerima OTLP; trace diteruskan ke AWS X-Ray dan metrik diekspos untuk Prometheus.
3. Kube Prometheus Stack mengumpulkan metrik Kubernetes dan metrik Collector, dengan retention awal tujuh hari.
4. Grafana menambahkan Prometheus dan CloudWatch sebagai data source; CloudWatch diakses lewat IAM role, tanpa access key di Grafana.
5. Buat dashboard untuk request rate, error rate, latency, CPU/memory, restart pod, dan koneksi DB.
6. Atur alert dengan periode evaluasi dan ambang berdasarkan baseline/SLO, bukan satu lonjakan sesaat.

Contoh sinyal/alarm:

- Error rate melewati ambang selama beberapa menit.
- P95 latency melampaui SLO.
- Memory container/pod mendekati limit dalam durasi tertentu.
- Pod sering restart atau target ALB tidak sehat.
- Koneksi database mendekati kapasitas pool atau limit RDS.

Untuk notifikasi Gmail, konfigurasi Grafana Alerting dengan SMTP yang sesuai. Untuk penggunaan yang lebih terkelola, pertimbangkan Amazon SES serta verifikasi sender/recipient sesuai aturan AWS. Jangan menyimpan password Gmail atau SMTP di Git, image, atau manifest plaintext.

## 9. Tahap ketujuh — buka aplikasi ke pengguna

1. Buat domain dan arahkan DNS melalui Route 53.
2. Buat sertifikat TLS melalui AWS Certificate Manager.
3. Konfigurasikan AWS Load Balancer Controller/ALB pada HTTPS 443. Starter saat ini belum membuat listener HTTPS.
4. Atur routing:
   - `/` menuju frontend/Nginx.
   - path API menuju service API.
5. Security Group ALB hanya menerima traffic publik yang diperlukan.
6. Security Group aplikasi hanya menerima traffic dari ALB.
7. RDS tetap berada di private subnet dan hanya menerima koneksi dari aplikasi.
8. Uji dari luar AWS:
   - buka domain HTTPS;
   - pastikan frontend dan gambar tampil;
   - uji register/login;
   - uji health/readiness;
   - pastikan respons/log tidak membocorkan secret atau stack trace.

Jangan membuka port 3000, 5432, 9090, 9100, atau UI Argo CD ke seluruh internet hanya untuk memudahkan pengujian.

## 10. Tahap kedelapan — incident response dan runbook

Gunakan STAR untuk menulis pengalaman insiden:

- **Situation:** latency meningkat atau aplikasi kehilangan konektivitas database sehingga pengguna terdampak.
- **Task:** lakukan analisis lini pertama, pulihkan layanan, dan identifikasi root cause.
- **Action:** periksa Grafana/CloudWatch, error rate, latency, pod/task health, ALB target health, log aplikasi, jumlah koneksi/pool RDS, dan perubahan deployment terbaru. Bandingkan kebutuhan koneksi total dengan kapasitas DB. Rollback atau ubah konfigurasi secara terkendali; koordinasikan perubahan security group/load balancer dengan tim.
- **Result:** verifikasi error dan latency kembali normal, catat waktu pemulihan, dokumentasikan root cause, dan buat tindakan pencegahan/runbook.

Jangan langsung menghapus pod yang menggantung tanpa memeriksa penyebab. Pastikan koneksi database, batas resource, probes, dan jumlah replika tidak saling memperburuk masalah.

Runbook minimal harus memuat:

- Cara menemukan dashboard/log yang relevan.
- Cara melihat status deployment dan rollback.
- Cara memeriksa koneksi database dan kapasitas.
- Cara menghubungi pemilik sistem dan eskalasi.
- Cara menguji pemulihan setelah perubahan.
- Tautan ke postmortem serta tindakan pencegahan.

## 11. Checklist selesai

- [ ] Tes aplikasi berjalan di CI dan gagal jika ada regresi.
- [ ] Image multi-stage/minimal, non-root, tidak berisi secret, dan lolos Trivy policy.
- [ ] Image punya tag immutable dan disimpan di ECR.
- [ ] GitHub Actions menggunakan OIDC dan role dengan izin minimum.
- [ ] Terraform state remote di S3; locking, versioning, encryption, dan IAM diuji.
- [ ] Environment memiliki state dan konfigurasi yang terpisah.
- [ ] RDS private, terenkripsi, memiliki backup, dan hanya dapat diakses oleh workload yang diizinkan.
- [ ] Development tersedia lewat DNS publik NLB HTTP; sebelum production, HTTPS dengan DNS/ACM sudah dikonfigurasi dan diuji.
- [ ] CPU/memory requests/limits, health checks, dan autoscaling telah diuji.
- [ ] Deploy Kubernetes berasal dari GitOps dan dapat di-rollback melalui Git.
- [ ] Log, metrik, trace, dashboard, dan alarm telah diuji.
- [ ] Backup/restore database dan rollback pernah dicoba di staging.
- [ ] Runbook insiden tersedia dan prosedur penghentian resource nonproduksi terdokumentasi.

## 12. Urutan implementasi yang direkomendasikan

1. Rapikan konfigurasi aplikasi, secret, health endpoints, migration, dan tes.
2. Bangun serta uji image Docker lokal; tambahkan Trivy scan.
3. Buat ECR dan pipeline GitHub Actions menggunakan OIDC.
4. Buat S3 remote state serta mekanisme locking Terraform.
5. Provision VPC, security groups, RDS, ECR, dan load balancer dengan Terraform.
6. Provision EKS development dan review semua output, konfigurasi IAM, serta biaya sebelum apply.
7. Bootstrap Argo CD dan External Secrets; review PR perubahan manifest sebelum Argo CD deploy image.
8. Uji dashboard, traces, autoscaling, restore database, dan rollback sebelum menyiapkan production.
9. Tambahkan domain/TLS, Multi-AZ, backup/restore teruji, alert SLO, dan runbook sebelum melayani trafik production.
10. Sebelum menghapus environment, pastikan data penting sudah dicadangkan. `terraform destroy` bersifat destruktif dan harus direview.

## Referensi resmi

- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Amazon EKS Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html)
- [Amazon ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html)
- [Amazon ECR image scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html)
