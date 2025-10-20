#!/usr/bin/env bash
# =============================================================================
#  One-shot Fix & Autostart GVM/OpenVAS on Kali Linux
#  - يثبت الحزم المطلوبة (gvm, greenbone-feed-sync, rsync, redis-server)
#  - gvm-setup + إصلاح الشهادات TLS
#  - تهيئة greenbone-feed-sync ليعمل كمستخدم _gvm
#  - مزامنة كامل الـ feeds
#  - Drop-ins لـ systemd + تمكين الخدمات على الإقلاع
#  - فتح GSA على 0.0.0.0 تلقائيًا
#  - إنشاء/تحديث admin + ضبط Feed Import Owner
#  - فحص نهائي gvm-check-setup
#  السجل: /var/log/gvm_fix.log | بيانات الدخول: /root/gvm-admin-credentials.txt
# =============================================================================

set -Eeuo pipefail
trap 'echo "[!] خطأ عند السطر $LINENO"; exit 1' ERR

LOGFILE="/var/log/gvm_fix.log"
CRED_FILE="/root/gvm-admin-credentials.txt"
ADMIN_USER="admin"
GSA_LISTEN_ADDR="0.0.0.0"   # افتراضيًا يفتح الواجهة على كل العناوين

mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

echo "[+] بدء تجهيز GVM/OpenVAS @ $(date -Is)"

[[ $EUID -eq 0 ]] || { echo "[!] لازم تشغّل السكريبت بـ root"; exit 1; }
command -v systemctl >/dev/null || { echo "[!] systemctl مش موجود"; exit 1; }

echo "[+] تحديث النظام وتثبيت الحزم المطلوبة..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y gvm greenbone-feed-sync rsync redis-server || true

echo "[+] تشغيل gvm-setup (قد يستغرق وقتًا لأول مرة)..."
# gvm-setup بيعمل DB/شهادات/أول مستخدم admin وبيظبط خدمات أساسية
# لو هو متثبّت قبل كده، الأمر هيكمل بدون مشاكل
gvm-setup || true

echo "[+] إيقاف الخدمات مؤقتًا للتحضير..."
systemctl stop gsad gvmd ospd-openvas notus-scanner 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true

echo "[+] التأكد من PostgreSQL و Redis..."
systemctl enable postgresql redis-server >/dev/null 2>&1 || true
systemctl start postgresql
systemctl start redis-server

echo "[+] إصلاح/إنشاء شهادات TLS (آمن دومًا)..."
runuser -u _gvm -- gvm-manage-certs -a -f || true

echo "[+] تهيئة greenbone-feed-sync ليعمل كمستخدم _gvm (خاص بكالي)..."
install -d -m 0755 /etc/gvm
cat >/etc/gvm/greenbone-feed-sync.toml <<'EOF'
[greenbone-feed-sync]
user="_gvm"
group="_gvm"
EOF
chmod 0644 /etc/gvm/greenbone-feed-sync.toml

echo "[+] مزامنة الـ Greenbone Community Feed (كل الأنواع)... قد تستغرق دقائق/ساعات أول مرة"
greenbone-feed-sync -vvv || echo "[!] تحذير: حدثت مشاكل أثناء المزامنة — راجع $LOGFILE"

echo "[+] إضافة Drop-ins لـ systemd لضبط الاعتمادات وسياسة الإعادة..."
# gvmd يعتمد على PostgreSQL والشبكة
install -d -m 0755 /etc/systemd/system/gvmd.service.d
cat >/etc/systemd/system/gvmd.service.d/override.conf <<'EOF'
[Unit]
After=postgresql.service network-online.target
Wants=postgresql.service network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF

# ospd-openvas يعتمد على redis + الشبكة
install -d -m 0755 /etc/systemd/system/ospd-openvas.service.d
cat >/etc/systemd/system/ospd-openvas.service.d/override.conf <<'EOF'
[Unit]
After=redis-server.service network-online.target
Wants=redis-server.service network-online.target

[Service]
Restart=on-failure
RestartSec=5s
EOF

# notus-scanner — إعادة تشغيل تلقائية عند الفشل
install -d -m 0755 /etc/systemd/system/notus-scanner.service.d
cat >/etc/systemd/system/notus-scanner.service.d/override.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

# gsad: فتح الواجهة على كل العناوين 0.0.0.0
GSAD_BIN="$(command -v gsad || echo /usr/sbin/gsad)"
install -d -m 0755 /etc/systemd/system/gsad.service.d
cat >/etc/systemd/system/gsad.service.d/override.conf <<EOF
[Unit]
After=gvmd.service network-online.target
Wants=network-online.target

[Service]
ExecStart=
ExecStart=${GSAD_BIN} --foreground --listen=${GSA_LISTEN_ADDR} --port=9392
Restart=on-failure
RestartSec=5s
EOF

echo "[+] إعادة تحميل وحدات systemd..."
systemctl daemon-reload

echo "[+] تمكين الخدمات على الإقلاع (Autostart)..."
systemctl enable postgresql redis-server gvmd gsad ospd-openvas notus-scanner >/dev/null 2>&1 || true

echo "[+] بدء الخدمات بالترتيب..."
systemctl start gvmd
sleep 3
systemctl start ospd-openvas
sleep 2
systemctl start notus-scanner || true
sleep 2
systemctl start gsad

# انتظار الجاهزية
wait_active() {
  local svc="$1" tries=90
  while (( tries-- > 0 )); do
    systemctl is-active --quiet "$svc" && return 0
    sleep 1
  done
  return 1
}
for s in gvmd ospd-openvas gsad; do
  echo "[i] انتظار جاهزية: $s"
  wait_active "$s" || echo "[!] تحذير: $s لم يصل لحالة active - افحص: systemctl status $s"
done

echo "[+] ترحيل قاعدة بيانات gvmd (لو لزم)..."
runuser -u _gvm -- gvmd --migrate || true

echo "[+] إنشاء/تحديث مستخدم الأدمن وإعداد كلمة سر قوية..."
ADMIN_PW="$(tr -dc 'A-Za-z0-9!@#%^_-+=' </dev/urandom | head -c 24)"
if runuser -u _gvm -- gvmd --get-users | grep -q "^${ADMIN_USER}\b"; then
  runuser -u _gvm -- gvmd --user="${ADMIN_USER}" --new-password="${ADMIN_PW}"
else
  runuser -u _gvm -- gvmd --create-user="${ADMIN_USER}" --password="${ADMIN_PW}"
fi

echo "[+] ضبط Feed Import Owner للمستخدم ${ADMIN_USER}..."
ADMIN_UUID="$(runuser -u _gvm -- gvmd --get-users --verbose | awk -v u="${ADMIN_USER}" '$1==u{print $2; exit}')"
if [[ -n "$ADMIN_UUID" ]]; then
  runuser -u _gvm -- gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "${ADMIN_UUID}" || true
else
  echo "[!] تعذر الحصول على UUID للأدمن — تخطيت خطوة Feed Import Owner"
fi

echo "[+] حفظ بيانات الدخول بشكل آمن..."
{
  echo "username=${ADMIN_USER}"
  echo "password=${ADMIN_PW}"
} > "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo "[+] فحص gvm-check-setup النهائي (قد يظهر تنبيهات معلوماتية)..."
gvm-check-setup || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "[✓] تم — كل شيء جاهز!"
echo "    🌐 واجهة الويب: https://${IP:-<Your-IP>}:9392"
echo "    👤 المستخدم: ${ADMIN_USER}"
echo "    🔑 كلمة السر: (موجودة في ${CRED_FILE})"
echo "    🧾 السجل: ${LOGFILE}"
echo
echo "[ℹ] ملاحظة: تحميل/فهرسة الـ feeds قد يحتاج شوية وقت بعد أول تشغيل — ده طبيعي."
