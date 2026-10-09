<div align="center">

# ⚡ RAZZIA
### Panduan Deployment Aplikasi Kuis Berbasis Web

**Praktikum KDJK 2026/2027 · P1 — Kelompok 8**

*Dari aplikasi lokal menuju layanan kuis yang dapat diakses melalui server VPS.*

---

`Ubuntu 24.04` · `Docker Compose` · `Razzia` · `HTTPS`

</div>

## Daftar Isi

- [Sekilas Tentang](#sekilas-tentang)
- [Instalasi](#instalasi)
- [Konfigurasi](#konfigurasi)
- [Maintenance](#maintenance)
- [Otomatisasi](#otomatisasi)
- [Cara Pemakaian](#cara-pemakaian)
- [Pembahasan](#pembahasan)
- [Referensi](#referensi)

> **Catatan status praktikum**
>
> Panduan ini mendokumentasikan deployment Razzia pada VPS Ubuntu. Skrip `setup.sh`, `backup.sh`, `restore.sh`, dan `update.sh` menangani deployment serta pemeliharaan dasar aplikasi. Pemeriksaan HTTP lokal bukan bukti bahwa DNS, HTTPS, dan akses dari internet sudah berfungsi. Lengkapi pengaturan reverse proxy dan TLS, lalu lakukan pengujian publik sebelum menyatakan layanan siap digunakan.

---

## Sekilas Tentang

### Apa itu Razzia?

[Razzia](https://github.com/ralex91/razzia) adalah aplikasi kuis berbasis web yang dapat di-host sendiri (*self-hosted*). Aplikasi ini cocok digunakan untuk membuat sesi kuis yang diikuti peserta melalui browser.

Dalam praktikum ini, fokus pekerjaan bukan membuat aplikasi kuis dari nol, melainkan **men-deploy aplikasi open-source ke VPS**, mengelola konfigurasinya, serta menyiapkan prosedur backup, restore, dan update.

### Tujuan praktikum

1. Menjalankan aplikasi web pada VPS berbasis Ubuntu.
2. Menggunakan Docker dan Docker Compose untuk mengelola container.
3. Mengatur password manager dengan aman.
4. Memahami pemetaan port dan peran reverse proxy.
5. Menyediakan skrip untuk backup, restore, dan update.
6. Menguji aplikasi dan mendokumentasikan hasilnya.

### Arsitektur deployment

```text
Pengguna / Peserta
       │
       ▼
Browser ── HTTPS ──► Domain publik
                         │
                         ▼
                 Reverse proxy (Caddy)
                         │ HTTP lokal
                         ▼
                 127.0.0.1:3000
                         │
                         ▼
                 Docker Compose
                         │
                         ▼
                   Razzia container
                         │
                         ▼
                 /opt/razzia/config
```

> Reverse proxy dan HTTPS merupakan lapisan terpisah dari skrip instalasi Razzia. Skrip `setup.sh` hanya memeriksa endpoint HTTP lokal pada `127.0.0.1:3000`; skrip tersebut tidak membuat konfigurasi Caddy atau sertifikat TLS.

### Lingkungan praktikum

| Komponen | Detail |
|---|---|
| Sistem operasi VPS | Ubuntu 24.04 LTS |
| Aplikasi | Razzia |
| Image container | `ralex91/razzia:latest` |
| Runtime | Docker Engine + Docker Compose plugin |
| Direktori aplikasi | `/opt/razzia` |
| Direktori backup | `/opt/razzia-backups` |
| Port aplikasi | `3000` pada loopback `127.0.0.1` |
| Domain praktikum | `razzia-kdjk.web.id` |

*(Gambar yang disarankan: diagram arsitektur deployment dengan ikon browser, domain, VPS, Caddy, Docker, dan Razzia.)*

---

## Instalasi

### 1. Prasyarat

Siapkan hal-hal berikut sebelum menjalankan skrip:

- VPS Ubuntu 24.04 dengan akses `sudo` atau root.
- Akses SSH ke VPS.
- Docker Engine dan plugin Docker Compose sudah terpasang dan berjalan.
- Koneksi internet untuk mengunduh image aplikasi.
- Domain yang DNS-nya diarahkan ke alamat IP publik VPS apabila aplikasi akan diakses melalui domain.
- Port `80/tcp` dan `443/tcp` dapat diakses dari internet untuk konfigurasi HTTPS.
- Empat skrip praktikum: `setup.sh`, `backup.sh`, `restore.sh`, dan `update.sh`.

> **Penting:** `setup.sh` memeriksa keberadaan Docker dan Docker Compose. Skrip ini tidak memasang Docker Engine. Pasang Docker terlebih dahulu menggunakan dokumentasi resmi Docker untuk Ubuntu.

### 2. Hubungkan ke VPS

Dari terminal komputer, jalankan perintah SSH berikut. Ganti `USER` dengan akun server yang diberikan penyedia VPS.

```bash
ssh USER@IP_PUBLIK_VPS
```

Setelah masuk, periksa versi sistem operasi:

```bash
lsb_release -a
```

Periksa Docker dan Compose:

```bash
docker --version
docker compose version
sudo docker info
```

Jika perintah Docker memerlukan hak administrator, gunakan `sudo` saat menjalankan skrip.

*(Screenshot 1: terminal berhasil terhubung ke VPS dan menampilkan versi Ubuntu, Docker, serta Docker Compose.)*

### 3. Siapkan berkas skrip

Simpan empat skrip pada direktori kerja, lalu pastikan nama berkasnya sesuai:

```text
deployment/
├── setup.sh
├── backup.sh
├── restore.sh
└── update.sh
```

Jika skrip dikirim dari komputer lokal, unggah ke VPS menggunakan `scp` atau metode transfer berkas lain yang tersedia. Contoh:

```bash
scp setup.sh backup.sh restore.sh update.sh USER@IP_PUBLIK_VPS:~/
```

Di VPS, periksa berkas yang diterima:

```bash
ls -l ~/setup.sh ~/backup.sh ~/restore.sh ~/update.sh
```

### 4. Jalankan instalasi Razzia

Jalankan skrip setup:

```bash
sudo bash ~/setup.sh
```

Skrip akan melakukan hal-hal berikut:

1. Memastikan skrip dijalankan sebagai root dan Docker Compose tersedia.
2. Memasang `curl` dan `python3` jika belum tersedia.
3. Membuat direktori `/opt/razzia` dan `/opt/razzia/config`.
4. Membuat `compose.yml` jika belum ada.
5. Meminta password manager dan konfirmasinya jika `config/game.json` belum tersedia.
6. Memvalidasi konfigurasi dan memastikan port aplikasi diterbitkan hanya ke loopback.
7. Mengunduh image Razzia, menjalankan container, dan memeriksa respons HTTP lokal.

**Jangan gunakan password default atau password yang mudah ditebak.** Ketik password ketika diminta; input password tidak ditampilkan di terminal.

### 5. Verifikasi instalasi

Periksa status container:

```bash
cd /opt/razzia
sudo docker compose -f compose.yml ps
```

Lihat log aplikasi jika diperlukan:

```bash
sudo docker compose -f /opt/razzia/compose.yml logs --tail=100
```

Uji endpoint lokal:

```bash
curl -I http://127.0.0.1:3000/
```

Jika endpoint merespons, aplikasi telah melewati pemeriksaan HTTP lokal. Ini belum memastikan domain publik atau HTTPS berfungsi.

*(Screenshot 2: output `docker compose ps` yang menunjukkan container berjalan.)*

*(Screenshot 3: terminal menunjukkan pemeriksaan HTTP lokal berhasil.)*

---

## Konfigurasi

### 1. Struktur direktori

Setelah instalasi, struktur utama yang digunakan adalah:

```text
/opt/razzia/
├── compose.yml
└── config/
    └── game.json

/opt/razzia-backups/
├── razzia-backup-<waktu>-<pid>.tar.gz
├── pre-update-<waktu>-<pid>.tar.gz
└── pre-update-<waktu>-<pid>.rollback.json
```

Direktori backup dibuat oleh skrip pemeliharaan sesuai kebutuhan. Nama berkas aktual memuat penanda waktu dan/atau PID.

### 2. Docker Compose

Konfigurasi dasar yang dibuat oleh `setup.sh` kurang lebih berbentuk:

```yaml
services:
  razzia:
    image: ralex91/razzia:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - ./config:/app/config
```

Keterangan:

- `image`: image Razzia yang diunduh dari registry.
- `restart: unless-stopped`: container akan dimulai kembali secara otomatis kecuali dihentikan secara eksplisit.
- `127.0.0.1:3000:3000`: port aplikasi hanya dipublikasikan pada loopback VPS, bukan langsung pada semua antarmuka jaringan.
- `./config:/app/config`: konfigurasi aplikasi pada host dipasang ke direktori konfigurasi di container.

Pemetaan loopback membatasi akses langsung ke port aplikasi dari luar VPS. Untuk akses publik, gunakan reverse proxy yang dikonfigurasi secara terpisah.

### 3. Password manager

Berkas `/opt/razzia/config/game.json` menyimpan konfigurasi aplikasi. Skrip setup membuat konfigurasi awal seperti berikut:

```json
{
  "managerPassword": "GANTI_DENGAN_PASSWORD_KUAT"
}
```

Contoh di atas hanya ilustrasi format. **Jangan menggunakan teks contoh sebagai password sebenarnya.**

Lindungi berkas konfigurasi karena memuat rahasia:

```bash
sudo ls -l /opt/razzia/config/game.json
sudo stat -c '%a %n' /opt/razzia/config/game.json
```

Skrip setup mengatur izin `game.json` menjadi `600` dan direktori `config` menjadi `700`. Jangan menampilkan atau menyalin password ke laporan, screenshot, repositori publik, maupun pesan yang dapat diakses orang lain.

### 4. Domain dan HTTPS

Domain praktikum: `razzia-kdjk.web.id`.

Agar aplikasi dapat diakses melalui HTTPS, pastikan:

1. DNS domain mengarah ke IP publik VPS.
2. Reverse proxy (misalnya Caddy) terpasang dan berjalan.
3. Reverse proxy meneruskan permintaan domain ke `127.0.0.1:3000`.
4. Firewall dan aturan penyedia VPS mengizinkan koneksi HTTP/HTTPS yang diperlukan.
5. Sertifikat TLS berhasil diterbitkan dan diperpanjang secara otomatis oleh mekanisme yang dikonfigurasi.

Contoh konsep konfigurasi Caddy:

```caddyfile
razzia-kdjk.web.id {
    reverse_proxy 127.0.0.1:3000
}
```

Konfigurasi ini merupakan **contoh konfigurasi reverse proxy**, bukan sesuatu yang dibuat otomatis oleh empat skrip praktikum. Terapkan melalui konfigurasi Caddy yang benar pada server, lalu validasi dan muat ulang Caddy sesuai dokumentasi resminya.

Verifikasi setelah konfigurasi selesai:

```bash
curl -I https://razzia-kdjk.web.id
```

Hasil uji harus diperiksa bersama status DNS, sertifikat TLS, dan log reverse proxy. Jangan menyimpulkan HTTPS berhasil hanya dari `curl http://127.0.0.1:3000/`.

*(Screenshot 4: domain Razzia terbuka di browser dengan HTTPS aktif dan indikator sertifikat valid. Tutupi informasi sensitif jika ada.)*

---

## Maintenance

Pemeliharaan membantu menjaga konfigurasi tetap dapat dipulihkan dan mengurangi risiko saat melakukan perubahan.

### 1. Backup berkala

Jalankan backup sebelum perubahan konfigurasi dan sebelum update:

```bash
sudo bash ~/backup.sh
```

Skrip membuat arsip pada:

```text
/opt/razzia-backups/
```

Isi backup meliputi:

- `compose.yml`
- Direktori `config/`, termasuk `config/game.json`

Skrip memvalidasi arsip, membatasi izin akses, dan melaporkan lokasi berkas yang dibuat.

**Batasan backup:** arsip ini tidak mencakup image Docker, konfigurasi Caddy, sertifikat TLS, maupun data di luar `config/`. Salin backup ke tempat penyimpanan lain di luar VPS. Jangan mengunggah arsip yang mengandung password ke repositori publik.

### 2. Restore dari backup

Restore mengganti `compose.yml` dan seluruh direktori `config/` dengan versi di dalam arsip. Proses ini dapat menyebabkan aplikasi berhenti sementara.

Jalankan:

```bash
sudo bash ~/restore.sh /opt/razzia-backups/NAMA_BACKUP.tar.gz
```

Ganti `NAMA_BACKUP.tar.gz` dengan nama arsip yang benar. Ketika diminta konfirmasi, ketik `YES` hanya setelah memeriksa bahwa berkas backup yang dipilih memang benar.

Sebelum menerapkan restore, skrip:

1. Memvalidasi isi arsip dan jalur berkas.
2. Mengekstrak berkas ke direktori staging.
3. Memeriksa konfigurasi JSON dan Docker Compose.
4. Meminta konfirmasi.
5. Membuat *safety backup* dari konfigurasi aktif sebelum menggantinya.

Setelah restore, skrip menguji respons HTTP lokal dan mencoba mengembalikan konfigurasi sebelumnya jika proses gagal. Mekanisme rollback tersebut tidak memulihkan image Docker atau konfigurasi Caddy/TLS.

### 3. Update aplikasi

Jalankan:

```bash
sudo bash ~/update.sh
```

Skrip update:

1. Memvalidasi deployment aktif.
2. Membuat backup konfigurasi.
3. Menyimpan image container yang sedang digunakan dengan tag lokal untuk kebutuhan rollback.
4. Meminta konfirmasi sebelum update.
5. Mengunduh image yang dikonfigurasi dan menerapkan update.
6. Memeriksa endpoint HTTP lokal.
7. Mencoba menjalankan kembali image lama jika update gagal atau pemeriksaan HTTP tidak berhasil.

Skrip ini sengaja dibatasi untuk deployment Docker Compose dengan **tepat satu service dan satu container**. Jangan menganggapnya sebagai mekanisme update universal untuk semua stack Compose.

Jika rollback image diperlukan, skrip menampilkan lokasi berkas `*.rollback.json` dan nama image rollback. Simpan informasi tersebut dan ikuti instruksi output skrip. Tag image rollback dipertahankan; lakukan pembersihan hanya setelah yakin image tersebut tidak lagi diperlukan.

### 4. Pemeriksaan rutin

| Frekuensi | Pemeriksaan |
|---|---|
| Sebelum perubahan | Buat backup dan periksa ruang disk |
| Setelah update | Periksa `docker compose ps`, log, dan HTTP lokal |
| Secara berkala | Pastikan backup tersedia dan salin ke luar VPS |
| Setelah perubahan domain/TLS | Uji URL HTTPS dari luar VPS |
| Saat ada masalah | Periksa log container dan reverse proxy |

Perintah diagnostik yang berguna:

```bash
sudo docker compose -f /opt/razzia/compose.yml ps
sudo docker compose -f /opt/razzia/compose.yml logs --tail=100
df -h
```

---

## Otomatisasi

Empat skrip shell disiapkan untuk menyederhanakan pekerjaan berulang. Jalankan dari direktori tempat skrip disimpan atau gunakan path lengkap.

| Skrip | Fungsi | Perintah |
|---|---|---|
| `setup.sh` | Instalasi awal Razzia | `sudo bash setup.sh` |
| `backup.sh` | Backup konfigurasi | `sudo bash backup.sh` |
| `restore.sh` | Restore dari arsip | `sudo bash restore.sh /path/backup.tar.gz` |
| `update.sh` | Update image dengan upaya rollback | `sudo bash update.sh` |

### Mengapa menggunakan skrip?

- **Konsisten:** langkah pemeriksaan dan operasi dijalankan dengan urutan yang sama.
- **Lebih aman:** skrip memvalidasi beberapa konfigurasi dan membatasi izin berkas yang berisi rahasia.
- **Mudah diulang:** perintah dapat dijalankan kembali ketika diperlukan.
- **Lebih mudah diaudit:** operasi penting menghasilkan pesan status dan lokasi backup.

### Hal yang perlu diperhatikan

- Skrip harus dijalankan dengan hak root melalui `sudo`.
- Skrip setup memerlukan Docker Engine dan Docker Compose yang sudah tersedia.
- Restore membutuhkan path arsip backup yang benar.
- Backup menyimpan password di dalam arsip konfigurasi; lindungi dan pindahkan arsip dengan aman.
- Update dan restore memeriksa HTTP lokal, bukan kesehatan HTTPS publik.
- Jalankan skrip hanya setelah memahami perubahan yang akan dilakukan dan membaca prompt konfirmasinya.

*(Screenshot 5: terminal menampilkan pesan backup berhasil beserta lokasi arsip. Pastikan tidak ada password yang terlihat.)*

---

## Cara Pemakaian

### 1. Membuka aplikasi

Setelah deployment dan konfigurasi domain/HTTPS selesai, buka:

**https://razzia-kdjk.web.id**

Jika domain belum dikonfigurasi atau HTTPS belum aktif, gunakan pemeriksaan lokal pada server:

```bash
curl -I http://127.0.0.1:3000/
```

Alamat loopback tersebut hanya dapat digunakan dari VPS itu sendiri. Untuk mengakses aplikasi dari perangkat lain, selesaikan konfigurasi DNS dan reverse proxy terlebih dahulu.

*(Screenshot 6: halaman utama Razzia pada browser.)*

### 2. Alur penggunaan kuis

Alur umum penggunaan aplikasi kuis adalah:

1. **Manager membuka halaman pengelolaan.** Gunakan alamat halaman manager yang disediakan aplikasi, lalu autentikasi dengan password manager yang telah dikonfigurasi.
2. **Manager menyiapkan kuis.** Buat atau pilih kuis dan periksa pertanyaan sebelum sesi dimulai.
3. **Manager memulai sesi permainan.** Ikuti instruksi yang ditampilkan aplikasi untuk membuka sesi.
4. **Peserta bergabung.** Bagikan URL permainan atau kode/identitas ruang yang ditampilkan aplikasi, jika tersedia.
5. **Peserta menjawab pertanyaan.** Peserta membuka halaman permainan melalui browser dan mengikuti instruksi pada layar.
6. **Manager memantau sesi.** Gunakan tampilan yang tersedia untuk memantau peserta dan hasil permainan.

Nama menu, mekanisme room, dan tampilan dapat berbeda sesuai versi Razzia yang sedang dijalankan. Gunakan elemen yang benar-benar tampil pada versi deployment praktikum; jangan mengasumsikan fitur yang belum diverifikasi.

### 3. Skenario demonstrasi

Gunakan data dummy berikut untuk demonstrasi kelas, lalu sesuaikan dengan fitur yang tersedia di aplikasi.

**Contoh sesi:** *Kuis Dasar Jaringan Komputer*

| No. | Pertanyaan | Jawaban benar |
|---|---|---|
| 1 | Apa kepanjangan dari IP pada istilah IP address? | Internet Protocol |
| 2 | Protokol apa yang digunakan untuk mengakses halaman web terenkripsi? | HTTPS |
| 3 | Apa fungsi DNS secara umum? | Memetakan nama domain ke alamat IP |
| 4 | Port default HTTPS adalah berapa? | 443 |
| 5 | Apa fungsi reverse proxy pada deployment ini? | Meneruskan permintaan ke aplikasi backend |

Tabel tersebut adalah **contoh materi kuis**, bukan bukti bahwa data ini sudah dimasukkan ke dalam server. Masukkan pertanyaan melalui antarmuka aplikasi jika format dan fitur kuis pada versi yang dipakai mendukungnya.

### 4. Dokumentasi hasil uji

Lengkapi tabel berikut berdasarkan pengujian nyata. Ubah status setelah setiap pengujian selesai.

| Pengujian | Hasil yang diharapkan | Hasil praktikum |
|---|---|---|
| Container berjalan | Service Razzia aktif | *(Isi berdasarkan hasil aktual)* |
| HTTP lokal | Endpoint `127.0.0.1:3000` merespons | *(Isi berdasarkan hasil aktual)* |
| Halaman web | Halaman Razzia tampil di browser | *(Isi berdasarkan hasil aktual)* |
| Login manager | Password yang benar diterima | *(Isi berdasarkan hasil aktual)* |
| Sesi kuis | Manager dapat memulai sesi | *(Isi berdasarkan hasil aktual)* |
| Peserta | Peserta dapat bergabung dan menjawab | *(Isi berdasarkan hasil aktual)* |
| Domain HTTPS | Domain terbuka dengan TLS valid | *(Isi berdasarkan hasil aktual)* |
| Backup | Arsip tercipta dan tervalidasi | *(Isi berdasarkan hasil aktual)* |
| Restore | Konfigurasi dipulihkan dan aplikasi diuji | *(Isi berdasarkan hasil aktual)* |
| Update | Update berhasil atau rollback ditangani | *(Isi berdasarkan hasil aktual)* |

*(Screenshot 7: manager menyiapkan kuis dengan data dummy.)*

*(Screenshot 8: tampilan peserta saat bergabung atau menjawab pertanyaan.)*

*(Screenshot 9: hasil kuis atau ringkasan sesi, apabila tersedia pada versi aplikasi.)*

> **Etika dokumentasi:** gunakan akun dan data dummy. Jangan tampilkan password, token, kredensial VPS, private key, atau isi rahasia dari `game.json` pada screenshot laporan.

---

## Pembahasan

### Kelebihan

- **Tidak perlu membuat aplikasi dari nol.** Deployment menggunakan aplikasi open-source yang sudah tersedia.
- **Isolasi aplikasi melalui container.** Docker Compose memudahkan pengelolaan service dan pemetaan port.
- **Port backend tidak langsung dibuka ke internet.** Konfigurasi dasar mengikat port aplikasi ke `127.0.0.1`, sehingga akses publik direncanakan melalui reverse proxy.
- **Konfigurasi terpisah dari image.** Direktori `config/` dipasang sebagai volume dan dapat dicadangkan.
- **Tersedia skrip pemeliharaan.** Backup, restore, dan update memiliki pemeriksaan awal serta pesan status.
- **Ada upaya rollback.** Restore membuat safety backup sebelum mengganti konfigurasi, sedangkan update menyimpan image lama untuk upaya rollback.

### Kekurangan dan batasan

- **Memerlukan administrasi server.** Pengguna perlu memahami SSH, Linux, Docker, DNS, firewall, dan reverse proxy.
- **HTTPS tidak otomatis disiapkan oleh skrip ini.** DNS, Caddy, dan sertifikat TLS harus dikonfigurasi serta diuji secara terpisah.
- **Backup tidak mencakup seluruh server.** Image Docker, konfigurasi Caddy, sertifikat TLS, dan data di luar direktori konfigurasi tidak termasuk.
- **Rollback memiliki batasan.** Pemulihan konfigurasi tidak sama dengan pemulihan seluruh VPS; update hanya mendukung satu service dan satu container.
- **Pembaruan menggunakan tag `latest`.** Versi aplikasi dapat berubah ketika image baru diunduh. Untuk deployment yang membutuhkan reproduktibilitas tinggi, versi image sebaiknya ditetapkan dan diuji secara terencana.
- **Pemeriksaan kesehatan masih sederhana.** Respons HTTP lokal belum membuktikan seluruh fitur kuis, login manager, DNS, dan HTTPS berjalan normal.

### Perbandingan singkat

Perbandingan berikut bersifat umum. Kemampuan rinci tiap produk bergantung pada versi dan konfigurasi yang digunakan.

| Aspek | Razzia self-hosted | Kahoot! | Quizizz / Wayground |
|---|---|---|---|
| Hosting | Dikelola sendiri di server | Layanan terkelola | Layanan terkelola |
| Kontrol server | Tinggi; administrator mengelola VPS | Terbatas pada opsi layanan | Terbatas pada opsi layanan |
| Tanggung jawab operasi | Update, backup, keamanan, dan TLS ditangani pengelola | Sebagian besar infrastruktur ditangani penyedia | Sebagian besar infrastruktur ditangani penyedia |
| Kebutuhan teknis awal | Relatif tinggi | Relatif rendah | Relatif rendah |
| Fleksibilitas deployment | Bergantung pada aplikasi dan konfigurasi server | Bergantung pada layanan | Bergantung pada layanan |

**Kesimpulan:** Razzia cocok untuk praktikum yang berfokus pada deployment dan administrasi aplikasi web karena mahasiswa dapat mempelajari container, konfigurasi server, domain, reverse proxy, serta pemeliharaan. Sebaliknya, layanan kuis terkelola umumnya lebih mudah digunakan tanpa menyiapkan dan merawat server sendiri.

---

## Referensi

1. Razzia — repositori sumber aplikasi.  
   https://github.com/ralex91/razzia
2. Docker Docs — dokumentasi Docker Engine.  
   https://docs.docker.com/engine/
3. Docker Docs — dokumentasi Docker Compose.  
   https://docs.docker.com/compose/
4. Caddy Documentation — dokumentasi reverse proxy dan HTTPS.  
   https://caddyserver.com/docs/
5. Ubuntu Server Documentation.  
   https://documentation.ubuntu.com/server/
6. Cloudflare Docs — dokumentasi DNS.  
   https://developers.cloudflare.com/dns/

> **Catatan referensi:** skrip `setup.sh`, `backup.sh`, `restore.sh`, dan `update.sh` yang digunakan pada praktikum merupakan berkas implementasi lokal kelompok. Dokumentasikan versi final berkas tersebut bersama laporan atau repositori praktikum agar langkah yang dijelaskan dapat ditelusuri.

---

<div align="center">

**RAZZIA · KDJK 2026/2027 · P1 — KELOMPOK 8**

*Deploy with care. Back up before change. Verify before claiming success.*

</div>
