# Deploy Task API ke AWS Jakarta

Panduan ini untuk Yassir dan Moskop menjalankan satu aplikasi kecil di **AWS Region Jakarta (`ap-southeast-3`)**. Aplikasinya adalah API daftar tugas: bisa menambah, melihat, dan menghapus tugas. Aplikasi berjalan di Amazon EKS. Docker image disimpan di Amazon ECR.

Mulai dari bagian **1** dan ikuti urutannya. Semua perintah dijalankan dari folder proyek yang berisi `README.md`. Perintah dalam panduan ini memakai shell Linux/macOS. Jika memakai Windows, gunakan WSL2.

> **Biaya:** Terraform membuat EKS, dua EC2 node, NAT Gateway, dan resource jaringan. Biaya berjalan sejak resource dibuat. Siapkan akun AWS untuk latihan, periksa Billing, lalu jalankan langkah penghapusan di akhir saat selesai.

## Urutan kerja: apa yang dibuat lebih dulu?

Ada dua jenis pekerjaan. **Persiapan AWS** dijalankan satu kali dari terminal oleh satu orang. **Pipeline aplikasi** berjalan di GitHub Actions setiap kali ada perubahan kode.

| Urutan | Pelaksana | Yang dikerjakan | Hasil |
|---|---|---|---|
| 1 | Terraform di terminal | Membuat VPC dan subnet, lalu EKS dan dua node EC2; juga membuat ECR serta role IAM untuk GitHub Actions | Tempat aplikasi dan tempat image sudah ada di Jakarta |
| 2 | GitHub Actions, tiga job pemeriksaan | `terraform-validate`, test Go + SAST gosec, dan DAST ZAP | Perubahan lolos pemeriksaan; **belum ada aplikasi yang dipasang ke EKS** |
| 3 | GitHub Actions, job `release` | Masuk ke AWS memakai role OIDC, membuat Docker image, mengirim image bertag commit SHA ke ECR | Image baru tersedia di ECR Jakarta |
| 4 | GitHub Actions, masih job `release` | Mengubah alamat dan tag image di `k8s/overlays/prod/kustomization.yaml`, lalu commit ke GitHub | Git mencatat versi yang harus berjalan |
| 5, pertama kali | Kita di terminal | Memasang Argo CD di EKS dan membuat Argo CD Application | Argo CD membaca Git dan memasang Task API ke EKS |
| 5, rilis berikutnya | Argo CD | Membaca perubahan tag di Git dan menyamakan Deployment di EKS | Versi aplikasi di EKS diperbarui otomatis |

Terraform menentukan urutan resource AWS dari hubungan antarresource. VPC dan subnet harus tersedia sebelum EKS memakai subnet tersebut. ECR dan role IAM dapat dibuat bersamaan dengan bagian lain. **Pipeline GitHub tidak menjalankan `terraform apply`; job `terraform-validate` hanya memeriksa file Terraform.** Ini menghindari kebutuhan memberi izin membuat seluruh infrastruktur AWS kepada workflow rilis aplikasi.

```text
Persiapan satu kali:
  Terraform → VPC/subnet → EKS + EC2 nodes
            └──────────→ ECR + role GitHub OIDC

Setiap rilis:
  GitHub → [validasi Terraform | test + SAST | DAST] → build image → ECR
                                                        ↓
                                               ubah tag image di Git
                                                        ↓
                                                  Argo CD → EKS
```

## Struktur folder proyek

```text
.
├── README.md                         Panduan yang sedang dibaca
├── main.go                           Kode Task API
├── main_test.go                      Test aplikasi Go
├── go.mod                            Nama modul dan versi Go
├── Dockerfile                        Cara membuat image aplikasi
├── .dockerignore                     File yang tidak dikirim saat Docker build
├── .gitignore                        File lokal yang tidak boleh ikut ke Git
├── .github/workflows/ci.yaml         Pipeline GitHub Actions
├── infra/terraform/
│   ├── versions.tf                   Versi Terraform/provider dan Region AWS
│   ├── variables.tf                  Nilai yang bisa diisi; Region dikunci ke Jakarta
│   ├── main.tf                       VPC, EKS, ECR, dan role IAM GitHub
│   ├── outputs.tf                    Nama cluster, alamat ECR, dan ARN role
│   ├── terraform.tfvars.example      Contoh input; disalin menjadi terraform.tfvars
│   └── .terraform.lock.hcl           Versi provider yang sudah dipilih Terraform
├── k8s/
│   ├── base/                         Namespace, Deployment, dan Service aplikasi
│   └── overlays/
│       ├── prod/kustomization.yaml   Image ECR yang dipakai Argo CD di EKS
│       └── local/kustomization.yaml  Contoh lokal dari versi awal; tidak dipakai panduan AWS
├── gitops/application.yaml           Alamat repo Git yang dibaca Argo CD
└── scripts/
    ├── update-image.py               Dipakai pipeline untuk mengubah versi image di Git
    └── local-demo.sh                 Contoh lokal dari versi awal; tidak dipakai panduan AWS
```

**File yang Anda isi:** `gitops/application.yaml` (URL repo GitHub) dan salinan `infra/terraform/terraform.tfvars.example` menjadi `terraform.tfvars` (nama repo, ID numerik owner/repo GitHub, IP publik, Region Jakarta). **File yang diubah pipeline:** `k8s/overlays/prod/kustomization.yaml`. Jangan mengganti placeholder image produksi secara manual sebelum rilis pertama; job `release` akan mengisinya setelah image berhasil masuk ECR.

File `terraform.tfvars`, `terraform.tfstate`, folder `.terraform/`, dan PDF CV tidak boleh masuk repository atau ZIP. Semuanya adalah file lokal/masukan pribadi atau hasil kerja Terraform, bukan kode proyek yang perlu dibagikan.

## Istilah singkat

| Istilah | Arti di proyek ini |
|---|---|
| **Terraform** | Membuat dan mencatat resource AWS dari file di `infra/terraform/`. |
| **EKS** | Cluster Kubernetes di AWS tempat aplikasi berjalan. |
| **ECR** | Tempat menyimpan Docker image aplikasi. |
| **GitHub Actions** | Menjalankan pemeriksaan kode dan mengirim image ke ECR. |
| **SAST** | gosec memeriksa kode Go tanpa menjalankan aplikasi. |
| **DAST** | ZAP memeriksa aplikasi yang sedang berjalan dalam container sementara di runner GitHub; scan ini tidak menyerang EKS. |
| **GitOps** | Versi yang ingin dijalankan ditulis di Git. Argo CD membaca Git dan memasangnya ke EKS. |
| **OIDC** | Cara GitHub Actions meminta izin AWS sementara tanpa menyimpan AWS access key di GitHub. |

## 1. Siapkan akun, izin, dan alat

### 1.1 Akun

- **GitHub:** buat atau gunakan akun yang bisa membuat repository dan mengubah repository variables. Untuk latihan ini gunakan repository **public** agar Argo CD dapat membaca file Git tanpa kredensial tambahan. PDF CV sudah diabaikan oleh `.gitignore`; tetap periksa daftar file sebelum push.
- **AWS:** gunakan akun yang boleh membuat VPC, EC2, EKS, ECR, IAM, dan NAT Gateway. Jika memakai akun tim, minta admin memastikan izin, kuota EC2, dan batas biaya. Satu orang saja menjalankan Terraform dengan folder dan file state yang sama; jangan menjalankan `apply` dari dua komputer dengan state lokal yang berbeda.
- **Region Jakarta:** akun perlu mengaktifkan `ap-southeast-3`. Setelah AWS CLI terpasang dan Anda berhasil login pada langkah berikutnya, cek status Region dengan perintah di bawah.

### 1.2 Alat di komputer yang menjalankan Terraform

Pasang [Git](https://git-scm.com/downloads), [Terraform](https://developer.hashicorp.com/terraform/install), [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [kubectl](https://kubernetes.io/docs/tasks/tools/), dan `curl`. **Docker dan kind tidak perlu dipasang di komputer untuk jalur ini**; GitHub Actions akan membuat image dan menjalankan DAST di runner GitHub.

Cek alat:

```bash
git --version
terraform version
aws --version
kubectl version --client
curl --version
```

Untuk `aws login`, AWS CLI perlu versi **2.32.0 atau lebih baru**. Masuk dengan identitas AWS latihan, lalu cek nomor akun:

```bash
aws login
aws sts get-caller-identity
```

Jika tim memakai AWS IAM Identity Center/SSO, pakai cara login dari admin, misalnya `aws sso login --profile NAMA_PROFILE`, lalu jalankan `export AWS_PROFILE=NAMA_PROFILE` di terminal yang akan memakai Terraform. Cocokkan nilai `Account` dari `aws sts get-caller-identity` dengan akun yang memang disiapkan. Jika login ditolak, minta admin menyiapkan akses; jangan memasukkan access key ke file proyek. [Panduan login AWS CLI](https://docs.aws.amazon.com/signin/latest/userguide/command-line-sign-in.html).

Cek apakah Jakarta sudah aktif:

```bash
aws account get-region-opt-status --region-name ap-southeast-3 --region us-east-1
```

`RegionOptStatus` harus `ENABLED`. `--region us-east-1` hanya memilih endpoint global layanan pengaturan akun untuk **mengecek status**; resource proyek tetap dibuat di Jakarta. Jika `DISABLED`, pemilik akun/admin perlu mengaktifkan Jakarta dari **AWS Console → Account → AWS Regions** dan menunggu sampai `ENABLED`. Lihat [panduan aktivasi Region](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html). Jika perintah ditolak oleh IAM, minta admin mengecek statusnya di Console.

Untuk `git push` lewat HTTPS, siapkan [Git Credential Manager atau GitHub CLI](https://docs.github.com/en/get-started/git-basics/caching-your-github-credentials-in-git). Kata sandi akun GitHub biasa tidak dapat dipakai sebagai kredensial Git HTTPS.

## 2. Buat repository GitHub

1. Buat repository **public** baru di GitHub, misalnya `task-api-belajar`. Jangan buat README, `.gitignore`, atau license dari halaman GitHub karena file proyek sudah ada.
2. Catat nama lengkapnya dalam bentuk `PEMILIK/REPO`, misalnya `yassir/task-api-belajar`.
3. Buka `gitops/application.yaml`. Ganti `REPLACE_OWNER/REPLACE_REPO` dengan nama repo Anda. Contoh hasilnya: `repoURL: https://github.com/yassir/task-api-belajar.git`. Biarkan `targetRevision: main`.
4. Jika folder proyek **belum** mempunyai Git, jalankan:

```bash
git init -b main
git add .
git status --short
```

Periksa daftar `git status --short`. PDF CV, `terraform.tfvars`, dan file `terraform.tfstate` tidak boleh muncul. Jika aman:

```bash
git commit -m "Mulai Task API di AWS Jakarta"
git remote add origin https://github.com/PEMILIK/REPO.git
git push -u origin main
```

Ganti `PEMILIK/REPO` dengan milik Anda. Jika `git commit` meminta identitas, set `git config --global user.name "Nama Anda"` dan `git config --global user.email "email@contoh.com"`, lalu ulangi commit. Jika folder **sudah** punya Git, jangan jalankan `git init` atau `git remote add` lagi; periksa remote dengan `git remote -v`, commit perubahan, lalu push ke `main`.

Buka tab **Actions** di GitHub. Push pertama menjalankan tiga pemeriksaan. Job `release` akan **Skipped** karena ECR dan role AWS belum dibuat. Ini normal pada push pertama.

## 3. Siapkan Terraform untuk Jakarta

Jalankan dari folder proyek. Salin file contoh:

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
```

Lihat IP publik komputer yang nanti memakai `kubectl`:

```bash
curl -fsS https://checkip.amazonaws.com
```

Buka `infra/terraform/terraform.tfvars`. Isi dengan **repo dan IP Anda**, misalnya:

```hcl
github_repository           = "yassir/task-api-belajar"
github_owner_id             = "12345678"
github_repository_id        = "1234567890"
cluster_public_access_cidrs = ["198.51.100.25/32"]
aws_region                  = "ap-southeast-3"
```

Ganti angka ID dengan ID numerik GitHub owner dan repository. Untuk melihatnya dengan GitHub CLI, jalankan `gh api repos/OWNER/REPO --jq '{repository_id: .id, owner_id: .owner.id}'`. ID ini dipakai GitHub pada subject token OIDC. `github_repository` harus sama persis dengan nama repo pada langkah 2. Angka `198.51.100.25` hanya contoh; ganti dengan hasil `curl`. `/32` berarti hanya IP itu yang boleh mengakses API EKS dari internet. Terraform proyek ini menolak Region selain Jakarta.

Cek lagi akun AWS dan Region Jakarta:

```bash
aws sts get-caller-identity
aws account get-region-opt-status --region-name ap-southeast-3 --region us-east-1
```

## 4. Buat infrastruktur AWS: `init` → `validate` → `plan` → `apply`

Jalankan berurutan:

```bash
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform validate
terraform -chdir=infra/terraform plan
```

`init` mengunduh modul Terraform. `validate` memeriksa bentuk file. `plan` menampilkan resource yang akan dibuat. Ketiganya belum membuat infrastruktur. Pada hasil `plan`, pastikan regionnya `ap-southeast-3` dan nama resource sesuai. Jika ada error izin, kuota, atau Region belum aktif, selesaikan sebelum lanjut.

Kemudian buat resource:

```bash
terraform -chdir=infra/terraform apply
```

Terraform akan meminta konfirmasi. Ketik `yes` setelah membaca rencana. Proses EKS dapat memakan beberapa menit. Setelah selesai, ambil output:

```bash
terraform -chdir=infra/terraform output
```

Catat `cluster_name`, `ecr_repository_url`, dan `github_actions_role_arn`. Simpan file `infra/terraform/terraform.tfstate` di komputer operator Terraform; file itu adalah catatan apa yang telah dibuat. Jangan hapus atau unggah ke GitHub. Untuk pemakaian tim jangka panjang, pindahkan state ke backend bersama sebelum dua orang mengubah infrastruktur.

**Hasil langkah ini:** VPC dan subnet Jakarta, EKS dengan dua EC2 node, ECR kosong, dan role GitHub OIDC. Aplikasi **belum** berjalan di EKS.

## 5. Sambungkan `kubectl` ke EKS dan cek node

Ganti `NAMA_CLUSTER` dengan output `cluster_name`:

```bash
aws eks update-kubeconfig --region ap-southeast-3 --name NAMA_CLUSTER
kubectl config current-context
kubectl get nodes
```

Context harus menunjuk ke cluster EKS yang baru dibuat. `kubectl get nodes` seharusnya menampilkan dua node `Ready`. Jika akses ditolak, gunakan identitas AWS yang sama dengan saat `terraform apply`, atau minta admin memberi akses ke cluster. Jika IP publik berubah sejak langkah 3, perbarui `cluster_public_access_cidrs` lalu jalankan `terraform -chdir=infra/terraform plan` dan `terraform -chdir=infra/terraform apply` lagi.

## 6. Isi variable GitHub dan jalankan pipeline rilis pertama

Buka repo GitHub → **Settings → Secrets and variables → Actions → Variables → New repository variable**. Isi **dua** variable:

| Nama | Nilai yang dimasukkan |
|---|---|
| `ECR_REPOSITORY_URL` | Nilai output Terraform `ecr_repository_url` |
| `AWS_ECR_PUSH_ROLE_ARN` | Nilai output Terraform `github_actions_role_arn` |

Region pipeline sudah ditetapkan di workflow sebagai `ap-southeast-3`, jadi tidak ada variable region yang perlu diisi. Dua nilai di atas bukan kata sandi. Workflow memakai OIDC untuk memperoleh izin AWS sementara.

Periksa **Settings → Actions → General → Workflow permissions**. Job `release` perlu izin menulis file versi image kembali ke branch `main`. Untuk latihan ini, jangan pasang aturan branch yang melarang bot push. Jika organisasi mengunci izin Actions, minta admin menyesuaikan izin repository.

Buka **Actions → CI and GitOps delivery → Run workflow**. Pilih branch `main`, lalu jalankan. Urutan di run tersebut:

1. Tiga job berjalan **bersamaan**: `terraform-validate` memeriksa file Terraform, `test-and-sast` menjalankan test Go dan gosec, `dast` membuat container sementara dan menjalankan ZAP. Ketiga job ini tidak memasang aplikasi ke EKS.
2. Job `release` **menunggu ketiganya berhasil**. Kalau satu gagal, `release` tidak berjalan.
3. `release` memakai role AWS OIDC, membuat Docker image dari `Dockerfile`, lalu push ke ECR Jakarta dengan tag berupa commit SHA.
4. `release` mengubah `newName` dan `newTag` pada `k8s/overlays/prod/kustomization.yaml`, commit, lalu push perubahan file itu ke branch `main`.

Pastikan semua job hijau. Buka `k8s/overlays/prod/kustomization.yaml` **di GitHub**. `newName` harus berisi URL ECR Jakarta dan `newTag` berisi 40 karakter commit SHA. Jika masih ada `REPLACE_WITH_ECR_REPOSITORY_URL` atau `bootstrap`, rilis pertama belum selesai. File di komputer belum otomatis ikut berubah; sebelum mengedit lagi, jalankan `git pull --ff-only`.

## 7. Pasang Argo CD dan buat deploy pertama

Lakukan ini **setelah** image ada di ECR dan file produksi di GitHub berisi tag yang benar. `kubectl` harus masih menunjuk ke EKS Jakarta; cek dengan `kubectl config current-context`.

Pasang Argo CD:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
```

Jika namespace sudah ada, pesan `AlreadyExists` pada perintah pertama bisa diabaikan. Perintah instalasi mengikuti [panduan resmi Argo CD](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/).

Pastikan `gitops/application.yaml` sudah berisi URL repository Anda. Jalankan:

```bash
kubectl apply -f gitops/application.yaml
kubectl -n argocd get application task-api
kubectl -n task-demo rollout status deployment/task-api --timeout=300s
kubectl -n task-demo get pods
```

Argo CD akan membaca `k8s/overlays/prod` dari Git, lalu membuat Namespace, Service, dan Deployment di EKS. Pada `kubectl -n argocd get application task-api`, cari status `Synced` dan `Healthy`. Pod `task-api` harus `Running`.

Coba API melalui koneksi sementara dari komputer ke cluster:

```bash
kubectl -n task-demo port-forward service/task-api 8080:80
```

Biarkan terminal itu terbuka. Dari terminal kedua:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/tasks
curl -X POST http://localhost:8080/tasks -H 'Content-Type: application/json' -d '{"title":"Cek EKS Jakarta"}'
curl http://localhost:8080/tasks/1
```

`/healthz` perlu menjawab `ok`, dan tugas yang baru dibuat perlu muncul. Hentikan port forwarding dengan `Ctrl+C`. Service aplikasi bertipe `ClusterIP`, jadi belum punya alamat publik; akses demo memakai port forwarding.

## 8. Rilis berikutnya

Ubah kode di branch baru, buka pull request ke `main`, dan lihat tiga job pemeriksaan. Setelah lolos, merge. Pipeline membuat image baru di ECR dan mengubah tag di Git. **Argo CD yang sudah terpasang akan membaca perubahan itu dan memperbarui EKS tanpa `kubectl apply` manual.** Bandingkan `newTag` sebelum dan sesudah merge untuk melihat versi yang berjalan.

## Jika ada kendala

| Gejala | Yang diperiksa |
|---|---|
| Status Jakarta `DISABLED` | Minta pemilik akun mengaktifkan `ap-southeast-3`, lalu tunggu status `ENABLED`. |
| `terraform plan/apply` gagal `AccessDenied` | Identitas dari `aws sts get-caller-identity` belum punya izin untuk resource pada pesan error. |
| EKS node gagal dibuat | Periksa kuota EC2, kelayakan tipe instance untuk akun AWS, ketersediaan tipe pada AZ yang dipilih, dan detail error Terraform. Demo memakai dua node `t3.small`; akun yang membatasi peluncuran ke Free Tier mungkin menolak tipe yang tidak eligible. |
| `kubectl get nodes` ditolak atau timeout | Periksa context, identitas AWS, dan apakah IP publik masih cocok dengan `cluster_public_access_cidrs`. |
| Job `release` masih `Skipped` | Pastikan dua variable GitHub terisi, jalankan workflow manual dari branch `main`, dan tunggu tiga job pemeriksaan lulus. |
| `release` gagal saat meminta izin AWS | Cocokkan nama repo di `terraform.tfvars`, branch `main`, dan ARN role pada variable GitHub. |
| `release` gagal pada `git push` | Cek izin GitHub Actions dan aturan branch `main`. |
| File produksi masih berisi placeholder | Job `release` belum sukses; jangan buat Argo CD Application dahulu. |
| Argo CD `OutOfSync`/`Missing` | Periksa `repoURL`, branch `main`, path `k8s/overlays/prod`, dan apakah file produksi sudah memakai image ECR. |
| Pod `ImagePullBackOff` | Periksa `newName`/`newTag` dan pastikan image itu ada di ECR Jakarta. |

## Selesai latihan: hapus resource AWS

Gunakan komputer dan folder Terraform yang sama dengan saat `apply`. Pastikan akun AWS masih benar, lalu lihat rencana penghapusan:

```bash
aws sts get-caller-identity
terraform -chdir=infra/terraform plan -destroy
```

Jika daftar resource sudah benar:

```bash
terraform -chdir=infra/terraform destroy
```

Ketik `yes` saat diminta. Tunggu sampai selesai tanpa error. ECR latihan ini disetel agar image di dalamnya ikut terhapus saat `destroy`. Cek AWS Console/Billing sesudahnya. Jika `destroy` gagal, **simpan file state** dan ulangi setelah penyebabnya diperbaiki; menghapus state saja tidak menghapus resource atau menghentikan biaya.

## Batas contoh

- Data tugas ada di memori satu Pod. Restart atau deploy ulang menghapus data; belum ada database dan login pengguna.
- DAST memakai ZAP baseline pada aplikasi yang berjalan sementara di GitHub runner. Ini belum menguji semua alur API atau semua serangan.
- EKS memakai dua subnet privat dan satu NAT Gateway; contoh ini belum dirancang untuk ketersediaan tinggi.
- GitHub Actions langsung commit versi image ke `main`. Untuk tim nyata, aturan review dan pengelolaan Terraform state perlu disepakati sebelum dipakai bersama.

## Rujukan

- [AWS Region Jakarta dan status aktivasi](https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html)
- [Amazon EKS: menghubungkan kubectl](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html)
- [GitHub Actions: urutan job dengan `needs`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-jobs)
- [Argo CD: sinkronisasi otomatis](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
