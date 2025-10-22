# 🛡️ OpenVAS (Greenbone Community Edition) Installation Guide on Kali Linux

> **Professional Installation and Configuration Guide**
>
> This repository provides a complete, step-by-step installation guide for **OpenVAS (Greenbone Community Edition)** on **Kali Linux**, including troubleshooting tips and optional configurations for professional environments.

---

## 📋 System Requirements

| Resource | Minimum | Recommended |
|-----------|----------|-------------|
| **RAM** | 4 GB | 8 GB |
| **Disk Space** | 50 GB | 100 GB |
| **CPU** | Dual-Core | Quad-Core |
| **OS** | Kali Linux (Rolling Release) | Latest Updated Version |

---
## ⚡ QuickStart — One-line installer

Run the full installer with one command (after you upload this repository to GitHub):

```bash
sudo curl -sSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS/main/install_openvas.sh | sudo bash
```
---
# OR
---
## ⚙️ Step 1: Update Kali Linux

Before installation, update and upgrade all packages to ensure system compatibility.

```bash
sudo apt update && sudo apt upgrade -y
```

> **Note:**  
> It’s highly recommended to perform a full system upgrade since OpenVAS requires the latest PostgreSQL version.

---

## 🧩 Step 2: Install Greenbone Community Edition

Install OpenVAS and all its dependencies:

```bash
sudo apt install gvm -y
```
---
```bash
sudo apt install openvas -y
```

> This command automatically installs **Greenbone Vulnerability Manager (GVM)** and all required components.

---

## 🔧 Step 3: Run the Configuration Script

Run the setup script to initialize databases, services, and admin credentials:

```bash
sudo gvm-setup
```

During setup, you will receive a default **admin username** and **password**.  
> ⚠️ Make sure to **save them securely** — they are required to log in later.

---

## 🔍 Step 4: Verify Installation

To confirm that the installation was successful:

```bash
sudo gvm-check-setup
```

Expected successful output:
```
It seems like your GVM-22.5.0 installation is OK.
```

---

## ▶️ Step 5: Start & Stop Greenbone Services

**Start all services:**
```bash
sudo gvm-start
```

**Stop all services:**
```bash
sudo gvm-stop
```

---

## 🌐 Step 6: Access the Web Interface

Open your browser and navigate to:

```
https://127.0.0.1:9392
```

Use the **admin credentials** provided in Step 3.

---

## ⏳ Step 7: Verify Feed Status

Before scanning, ensure that the Greenbone feed has synchronized correctly:

- Go to **Administration → Feed Status**
- Wait until all feeds show as **“Current”**

Feed synchronization can take **a few minutes to several hours** depending on system performance.

---

## 🌍 Enable Remote Access (Access via Server IP)

By default, OpenVAS only listens on **localhost (127.0.0.1)**.  
To allow access from a **server IP (e.g. 192.168.x.x or public IP):**

1. Edit the `gsad` service file:
   ```bash
   sudo nano /usr/lib/systemd/system/gsad.service
   ```

2. Change the `ExecStart` line from:
   ```bash
   ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392
   ```
   to:
   ```bash
   ExecStart=/usr/local/sbin/gsad --foreground --listen=0.0.0.0 --port=9392
   ```

3. Apply and restart the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart gsad
   ```

Now you can access OpenVAS from any browser using your server IP:

```
https://<SERVER-IP>:93992
```

---

## 🧠 Troubleshooting Common Issues

### 🧩 Issue 1: Web Interface Not Accessible
**Cause:** gsad not listening on correct IP  
**Fix:**
```bash
sudo systemctl restart gsad
sudo netstat -tulnp | grep gsad
```
Ensure the service is running and listening on the configured port (443 or 9392).

---

### 🔐 Issue 2: Invalid or Missing Admin Credentials

If you forgot your username or password, create a new admin user:

```bash
sudo runuser -u _gvm -- gvmd --create-user=admin2 --password=newpassword123
```

To list existing users:
```bash
sudo runuser -u _gvm -- gvmd --get-users
```

To reset a password:
```bash
sudo runuser -u _gvm -- gvmd --user=admin --new-password=YourNewPassword123
```

---

### 🧱 Issue 3: Feed Not Updating

Force a feed update manually:
```bash
sudo runuser -u _gvm -- greenbone-feed-sync --type GVMD_DATA
sudo runuser -u _gvm -- greenbone-feed-sync --type SCAP
sudo runuser -u _gvm -- greenbone-feed-sync --type CERT
sudo gvm-check-setup

```

Restart services after update:
```bash
sudo gvm-stop && sudo gvm-start
```

---

## 🔏 Optional Configuration

### 🧰 View Logs
```bash
ls /var/log/gvm
```

### ⚙️ Edit Configuration Files
```bash
ls /etc/gvm
ls /etc/openvas
```

### 🔑 Set Password Policy
```bash
sudo nano /etc/gvm/pwpolicy.conf
```

---

## 🧾 Summary of Useful Commands

| Purpose | Command |
|----------|----------|
| Update System | `sudo apt update && sudo apt upgrade -y` |
| Install GVM | `sudo apt install gvm -y` |
| Run Setup | `sudo gvm-setup` |
| Check Setup | `sudo gvm-check-setup` |
| Start GVM | `sudo gvm-start` |
| Stop GVM | `sudo gvm-stop` |
| Create User | `sudo runuser -u _gvm -- gvmd --create-user=<user> --password=<pass>` |
| Reset Password | `sudo runuser -u _gvm -- gvmd --user=<user> --new-password=<pass>` |
| Feed Sync | `sudo greenbone-feed-sync --type ALL` |

---

## 🧩 References

- [Greenbone Community Docs](https://greenbone.github.io/docs/)
- [Kali Linux Official Docs](https://www.kali.org/docs/)
- [Greenbone Support Portal](https://community.greenbone.net/)

---

## 📄 License
This project follows the **MIT License** — free to use, modify, and distribute.

---

## 👤 Author
**AbdulRhman AbdulGhaffar**  
Cybersecurity Consultant  & Incident Response Specialist 

---

**© 2025 – All Rights Reserved**
