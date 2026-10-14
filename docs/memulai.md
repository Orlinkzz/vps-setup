# Memulai dengan VPS pertama Anda

Anda baru menyewa server Linux ("VPS") dari penyedia seperti DigitalOcean, Linode, Vultr,
atau lainnya. Sekarang apa? Panduan ini membantu langkah pertama agar server aman dan siap pakai.

---

## 1. Buat SSH key di komputer Anda sendiri (lakukan ini dulu)

VPS Setup mematikan login password lewat SSH, karena password terus-menerus ditebak oleh bot.
Setelah itu Anda login memakai **SSH key**: sepasang file di komputer Anda. Buat sekarang, sebelum
menyentuh server:

```bash
ssh-keygen -t ed25519 -C "laptop-saya"
```

Tekan Enter untuk lokasi bawaan. Passphrase opsional tetapi disarankan.
Perintah ini membuat dua file di `~/.ssh/` (di Windows: `C:\Users\<nama>\.ssh\`):

- `id_ed25519` — kunci **privat**. Jangan dibagikan, jangan diunggah ke mana pun.
- `id_ed25519.pub` — kunci **publik**. File inilah yang dipasang di server.

Tampilkan kunci publik agar bisa disalin:

```bash
cat ~/.ssh/id_ed25519.pub
```

Isinya satu baris yang diawali `ssh-ed25519 AAAA...`. VPS Setup akan meminta Anda menempelkannya.

> **Pengguna Windows:** jalankan perintah di PowerShell atau Windows Terminal. Jika `ssh` tidak
> dikenali, instal dari Settings → Apps → Optional features → Add "OpenSSH Client".

## 2. Login pertama kali

Penyedia Anda memberikan alamat IP dan password root (atau sudah memasang key Anda). Hubungkan:

```bash
ssh root@<ALAMAT_IP_SERVER>
```

Contoh: `ssh root@203.0.113.10`

Saat pertama connect Anda akan diminta konfirmasi sidik jari server — ketik `yes`.

## 3. Download dan jalankan VPS Setup

```bash
curl -fsSL https://raw.githubusercontent.com/orlinkzz/vps-setup/main/install.sh | sudo bash
```

Perintah ini memasang tool di `/opt/vps-setup`, menambahkan perintah `vps-setup`, lalu membuka menu.
Setelah itu Anda bisa menjalankannya dari mana saja dengan `sudo vps-setup`.

Ingin membaca kodenya dulu? (Disarankan.)

```bash
git clone https://github.com/orlinkzz/vps-setup.git
cd vps-setup
sudo ./setup.sh
```

(Pada salinan hasil clone, pakai `sudo ./setup.sh` di setiap tempat panduan ini menulis `sudo vps-setup`.)

## 4. Ikuti menunya

**Pilih titik awal:**

- **Recommended** — terbaik untuk kebanyakan orang. Memasang update, user aman, firewall, web
  server, PostgreSQL, Redis, Python, dan lainnya.
- **Minimal** — hanya yang penting: update, swap, user, dan firewall.
- **Custom** — pilih semuanya sendiri.
- **Tambah website**, **Buat database**, **Di belakang Cloudflare** — tugas tunggal untuk nanti.
- **Kelola server ini** — cek kesehatan, daftar atau hapus website dan database.

**Pilih fitur:** centang atau hapus centang tiap item. Tekan SPASI untuk mencentang, ENTER untuk
lanjut.

**Jawab pertanyaan:** tool menanyakan hal sederhana seperti "username apa?" dan
"tempelkan SSH key publik Anda" (dari langkah 1).

**Tinjau:** ringkasan menampilkan persis apa yang akan dilakukan. Jika sudah benar, konfirmasi.
Tidak ada yang berubah sebelum titik ini.

**Tunggu:** tool menjalankan setiap langkah. Kebanyakan selesai dalam hitungan detik; instalasi
paket bisa beberapa menit. Jangan tutup terminal.

## 5. Apa yang baru saja terjadi?

Saat selesai Anda akan melihat ringkasan:

```
✓  Sistem sudah terbaru
✓  Swap file dibuat
✓  User "deploy" siap
✓  Pengamanan SSH diterapkan (port 22)
✓  Firewall aktif
✓  PostgreSQL terpasang
✓  Nginx terpasang
…
```

Server Anda sekarang punya:
- User admin non-root (Anda login sebagai `deploy`, bukan `root`)
- Login SSH hanya dengan key (lebih aman daripada password)
- Firewall yang memblokir semua kecuali SSH dan website
- Web server yang siap melayani situs
- Server database jika Anda memilihnya

## 6. Login sebagai user baru — sebelum menutup apa pun

Buka **jendela terminal baru** dan biarkan yang lama tetap terbuka sampai ini berhasil:

```bash
ssh deploy@<ALAMAT_IP_SERVER>
# jika SSH dipindah ke port lain:
ssh -p 2222 deploy@<ALAMAT_IP_SERVER>
```

Jika berhasil, semuanya siap dan sesi root lama boleh ditutup. Jika gagal, pakai sesi lama untuk
memperbaikinya (lihat *Pemecahan masalah* di bawah) — itulah gunanya sesi itu dibiarkan terbuka.

## 7. Selanjutnya?

| Tugas | Perintah |
|---|---|
| Tambah website | `sudo vps-setup --add-domain` |
| Buat database | `sudo vps-setup --add-database` |
| Apakah semuanya sehat? | `sudo vps-setup --doctor` |
| Apa saja yang sudah saya buat? | `sudo vps-setup --list-sites` / `--list-databases` |
| Hapus website | `sudo vps-setup --remove-domain lama.example.com` (bertanya dulu) |
| Perbarui tool | `sudo vps-setup --update` |
| Batalkan konfigurasinya | `sudo vps-setup --uninstall` (paket dan data tetap ada) |

- **Jalankan tool lagi kapan saja:** langkah yang sudah selesai otomatis dilewati.
- **Lihat log lengkap:** semuanya ditulis ke `/var/log/vps-setup.log`.

## Pemecahan masalah

**Saya terkunci dari SSH.**
Setiap penyedia punya konsol web ("Console", "Recovery", "VNC") di dashboard yang bekerja tanpa
SSH. Login di sana sebagai root, lalu:
- periksa konfigurasi: `sshd -t` (tidak ada output berarti valid)
- lihat port SSH: `sshd -T | grep ^port`
- pastikan firewall mengizinkannya: `ufw status` (Ubuntu/Debian) atau `firewall-cmd --list-all` (AlmaLinux/Rocky)
- pastikan kunci publik Anda ada di `/home/deploy/.ssh/authorized_keys`
- `sudo vps-setup --doctor` menunjukkan penyebab yang umum.

**Sertifikat HTTPS tidak terbuat.**
Let's Encrypt hanya bisa menerbitkan sertifikat jika domain sudah mengarah ke server ini.
Periksa dengan `getent hosts example.com`: alamatnya harus IP server Anda. Setelah mengubah DNS,
perlu waktu sampai tersebar. Lalu jalankan lagi `sudo vps-setup --add-domain` untuk domain itu.
Terlalu banyak percobaan terkena batas Let's Encrypt; tunggu satu jam sebelum mencoba lagi.

**"Port 80 sudah dipakai".**
Ada web server atau aplikasi lain yang berjalan. Langkah web server akan menanyakan tindakannya
(hentikan, lanjutkan, atau lewati). `sudo ss -ltnp 'sport = :80'` menunjukkan siapa yang memakainya.

**Ada langkah yang gagal.**
Ringkasan menandainya dengan ✗. Baca baris terakhir `/var/log/vps-setup.log`, perbaiki penyebabnya,
lalu jalankan tool lagi: ia melanjutkan dari tempat berhenti.

## Tips untuk pemula

- **Jaga server tetap terbaru:** tool mengaktifkan update keamanan otomatis. Anda tidak perlu
  memeriksa update secara manual.
- **Coba dry-run dulu:** `sudo vps-setup --dry-run` menampilkan semuanya tanpa mengubah apa pun.
- **Firewall penyedia cloud:** jika penyedia VPS punya panel firewall sendiri ("security groups"),
  buka juga port 80 (HTTP), 443 (HTTPS), dan port SSH Anda di sana.
- **Docker:** port container yang dipublikasikan hanya mendengarkan di `127.0.0.1`. Untuk
  membukanya dengan sengaja, tulis `-p 0.0.0.0:8080:80` dan buka port itu di firewall.
