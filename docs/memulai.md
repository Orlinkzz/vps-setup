# Memulai dengan VPS pertama Anda

Anda baru menyewa server Linux ("VPS") dari penyedia seperti DigitalOcean, Linode, Vultr,
atau lainnya. Sekarang apa? Panduan ini membantu langkah pertama agar server aman dan siap pakai.

---

## 1. Login pertama kali

Penyedia Anda memberikan alamat IP dan password root (atau SSH key). Hubungkan dari terminal:

```bash
ssh root@<ALAMAT_IP_SERVER>
```

Contoh: `ssh root@203.0.113.10`

Saat pertama connect Anda akan diminta konfirmasi sidik jari server — ketik `yes`.

> **Pengguna Windows:** buka PowerShell atau Windows Terminal. Jika `ssh` tidak dikenali,
> instal dari Settings → Apps → Optional features → Add "OpenSSH Client".

## 2. Download dan jalankan VPS Setup

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
```

Perintah ini mendownload tool dan membuka menu. Jika ingin lihat kodenya dulu:

```bash
git clone https://github.com/orlinkzz/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

## 3. Ikuti menu

**Pilih titik awal:**

- **Recommended** — paling cocok untuk kebanyakan orang. Memasang update, user aman,
  firewall, web server, PostgreSQL, Redis, Python, dan lainnya.
- **Minimal** — hanya esensial: update, swap, user, dan firewall.
- **Custom** — pilih semuanya sendiri.

**Pilih fitur:** Anda bisa centang/hapus centang tiap item. Tekan SPASI untuk
centang/hapus, ENTER untuk lanjut. Arahkan kursor ke item untuk membaca penjelasannya.

**Jawab pertanyaan:** tool bertanya sederhana seperti "siapa username-nya?" Ketik jawaban
Anda.

**Periksa:** ringkasan menunjukkan apa yang akan terjadi. Jika sudah benar, konfirmasi.
Tidak ada yang berubah sebelum titik ini.

**Tunggu:** tool menjalankan setiap langkah. Sebagian selesai dalam detik; instalasi paket
mungkin butuh beberapa menit. Jangan tutup terminal.

## 4. Apa yang baru saja terjadi?

Setelah selesai Anda akan melihat ringkasan:

```
✓  Sistem sudah terbaru
✓  Swap file dibuat
✓  User "deploy" siap
✓  Hardening SSH diterapkan
✓  Firewall aktif
✓  PostgreSQL terpasang
✓  Nginx terpasang
…
```

Server Anda sekarang memiliki:
- User admin non-root (Anda login sebagai `deploy` bukan `root`)
- Login hanya dengan SSH key (lebih aman daripada password)
- Firewall yang memblokir semuanya kecuali SSH dan website
- Web server siap melayani situs Anda
- Database server jika Anda memilihnya

## 5. Login sebagai user baru

Buka **jendela terminal baru** (biarkan yang lama tetap terbuka sampai Anda tes):

```bash
ssh deploy@<ALAMAT_IP_SERVER>
```

Jika berhasil, Anda siap. Sesi root lama bisa ditutup.

## 6. Langkah selanjutnya?

- **Tambah website:** jalankan `sudo ./setup.sh --add-domain` dan ikuti wizard.
- **Buat database:** jalankan `sudo ./setup.sh --add-database`.
- **Cek kesehatan server:** jalankan `sudo vps-setup-health`.
- **Jalankan tool lagi:** aman — langkah yang sudah selesai otomatis dilewati.
- **Lihat log lengkap:** semua tercatat di `/var/log/vps-setup.log`.

## Tips untuk pemula

- **Jaga server tetap update:** tool mengaktifkan update keamanan otomatis. Anda tidak perlu
  memeriksa update manual.
- **Gunakan dry-run dulu:** `sudo ./setup.sh --dry-run` menunjukkan semua yang akan terjadi
  tanpa mengubah apa pun.
- **Firewall penyedia cloud:** jika penyedia VPS Anda punya panel firewall sendiri
  ("security groups"), buka port 80 (HTTP) dan 443 (HTTPS) di sana juga.
- **Butuh bantuan?** Cek file log di `/var/log/vps-setup.log` — semua perintah tercatat.
