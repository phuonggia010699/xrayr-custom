#!/usr/bin/env bash
# Cài hoặc nâng cấp XrayR (bản tự build) trên VPS node chỉ bằng một lệnh.
#
# Ví dụ node VLESS + TLS, cấp chứng chỉ bằng Cloudflare DNS:
#   bash <(curl -fsSL https://raw.githubusercontent.com/phuonggia010699/xrayr-custom/main/install-xrayr.sh) \
#     --api-host https://panel.example.com --node-id 1 --node-type vless \
#     --cert-mode dns --cert-domain node01.example.com
#   (ApiKey và token Cloudflare sẽ được hỏi, không hiện trên màn hình)
#
# Tham số (tham số nào thiếu thì script sẽ hỏi):
#   --api-host URL        địa chỉ panel, vd https://panel.example.com
#   --api-key KEY         khóa giao tiếp của panel (nên để script hỏi)
#   --node-id N           ID node trong panel
#   --node-type TYPE      vless | v2ray | vmess | trojan | shadowsocks
#   --panel-type TYPE     mặc định NewV2board (đúng cho Zicboard/V2Board)
#   --cert-mode MODE      dns | http | file | none   (mặc định dns)
#   --cert-domain NAME    tên miền cấp chứng chỉ
#   --cert-email MAIL     email đăng ký chứng chỉ
#   --cf-token TOKEN      token Cloudflare (chỉ khi --cert-mode dns; nên để script hỏi)
#   --force-config        tạo lại config.yml dù đã có
#
# Chạy lại lệnh để nâng cấp: chỉ thay file chạy, giữ nguyên config.yml.

set -euo pipefail

# ===== Nơi chứa bản build (repo của bạn) =====
BASE_URL="${BASE_URL:-https://github.com/phuonggia010699/xrayr-custom/releases/latest/download}"
GEO_URL="${GEO_URL:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"
# =============================================

INSTALL_DIR=/usr/local/XrayR
CONF_DIR=/etc/XrayR
CONFIG="$CONF_DIR/config.yml"
SERVICE=/etc/systemd/system/XrayR.service

API_HOST="" ; API_KEY="" ; NODE_ID="" ; NODE_TYPE="" ; PANEL_TYPE="NewV2board"
CERT_MODE="dns" ; CERT_DOMAIN="" ; CERT_EMAIL="" ; CF_TOKEN="" ; FORCE_CONFIG=0
NT="" ; ENABLE_VLESS=false ; VLESS_FLOW_SET=0

die() { echo "LỖI: $*" >&2; exit 1; }

# >>> config-edit
esc() { printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'; }

# setkey KEY VALUE: chỉ sửa các dòng đang bật, không đụng các dòng bị comment (#)
setkey() {
  local key="$1" val
  val="$(esc "$2")"
  sed -i -E "s|^([[:space:]]*(-[[:space:]]+)?)${key}:.*|\1${key}: ${val}|" "$CONFIG"
  if ! grep -qE "^[[:space:]]*(-[[:space:]]+)?${key}:" "$CONFIG"; then
    echo "!! Không thấy khóa $key trong config.yml, hãy kiểm tra thủ công" >&2
  fi
}

apply_config_edits() {
  setkey PanelType "\"$PANEL_TYPE\""
  setkey ApiHost "\"$API_HOST\""
  setkey ApiKey "\"$API_KEY\""
  setkey NodeID "$NODE_ID"
  setkey NodeType "$NT"
  setkey EnableVless "$ENABLE_VLESS"
  if [[ "$VLESS_FLOW_SET" -eq 1 ]]; then
    setkey VlessFlow '""'
  fi

  setkey CertMode "$CERT_MODE"
  if [[ "$CERT_MODE" != "none" ]]; then
    setkey CertDomain "\"$CERT_DOMAIN\""
  fi
  case "$CERT_MODE" in
    dns)
      setkey Provider cloudflare
      setkey Email "$CERT_EMAIL"
      sed -i -E "s|^([[:space:]]*)ALICLOUD_ACCESS_KEY:.*|\1CLOUDFLARE_DNS_API_TOKEN: \"$(esc "$CF_TOKEN")\"|" "$CONFIG"
      sed -i -E '/^[[:space:]]*ALICLOUD_SECRET_KEY:/d' "$CONFIG"
      if ! grep -q 'CLOUDFLARE_DNS_API_TOKEN' "$CONFIG"; then
        echo "!! Không điền được token Cloudflare vào DNSEnv, hãy kiểm tra thủ công" >&2
      fi
      ;;
    file)
      setkey CertFile "$CONF_DIR/cert/$CERT_DOMAIN.cert"
      setkey KeyFile "$CONF_DIR/cert/$CERT_DOMAIN.key"
      ;;
  esac
}
# <<< config-edit

while [[ $# -gt 0 ]]; do
  [[ "$1" == "--force-config" ]] || [[ $# -ge 2 ]] || die "Thiếu giá trị cho $1"
  case "$1" in
    --api-host)     API_HOST="$2"; shift 2 ;;
    --api-key)      API_KEY="$2"; shift 2 ;;
    --node-id)      NODE_ID="$2"; shift 2 ;;
    --node-type)    NODE_TYPE="$2"; shift 2 ;;
    --panel-type)   PANEL_TYPE="$2"; shift 2 ;;
    --cert-mode)    CERT_MODE="$2"; shift 2 ;;
    --cert-domain)  CERT_DOMAIN="$2"; shift 2 ;;
    --cert-email)   CERT_EMAIL="$2"; shift 2 ;;
    --cf-token)     CF_TOKEN="$2"; shift 2 ;;
    --force-config) FORCE_CONFIG=1; shift ;;
    *) die "Tham số không hợp lệ: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Cần chạy bằng root."
command -v systemctl >/dev/null || die "Máy này không có systemd."

if ! command -v curl >/dev/null; then
  if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y curl
  elif command -v yum >/dev/null; then yum install -y curl
  else die "Hãy cài curl rồi chạy lại."; fi
fi

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Kiến trúc $(uname -m) chưa được hỗ trợ." ;;
esac

mkdir -p "$INSTALL_DIR" "$CONF_DIR"

# File chạy nặng khoảng 124 MB; cần chỗ cho bản mới và bản sao lưu
AVAIL_MB="$(df -Pm "$INSTALL_DIR" | awk 'NR==2{print $4}')"
[[ "$AVAIL_MB" -ge 300 ]] || die "Ổ đĩa chỉ còn ${AVAIL_MB} MB, cần ít nhất 300 MB. Hãy dọn bớt rồi chạy lại."

# ---- Tải file chạy (tải thẳng vào thư mục cài, không dùng /tmp) ----
NEW="$INSTALL_DIR/XrayR.new"
SUMS="$(mktemp)"
trap 'rm -f "$NEW" "$SUMS"' EXIT

echo ">> Tải XrayR (linux/$ARCH)"
curl -fL --retry 3 -o "$NEW" "$BASE_URL/XrayR-linux-$ARCH"
curl -fsSL --retry 3 -o "$SUMS" "$BASE_URL/SHA256SUMS" || die "Không tải được SHA256SUMS."

WANT="$(awk -v f="XrayR-linux-$ARCH" '$2==f{print $1}' "$SUMS")"
GOT="$(sha256sum "$NEW" | awk '{print $1}')"
[[ -n "$WANT" && "$WANT" == "$GOT" ]] || die "Sai checksum (file tải về bị lỗi hoặc cắt cụt), dừng cài."
echo ">> Checksum đúng"

chmod +x "$NEW"
"$NEW" version >/dev/null 2>&1 || die "File tải về không chạy được trên máy này."

# ---- Thay file chạy, giữ bản cũ để lùi ----
systemctl stop XrayR 2>/dev/null || true
if [[ -f "$INSTALL_DIR/XrayR" ]]; then
  mv -f "$INSTALL_DIR/XrayR" "$INSTALL_DIR/XrayR.bak"
fi
mv -f "$NEW" "$INSTALL_DIR/XrayR"

# ---- File geo ----
for f in geoip.dat geosite.dat; do
  if [[ ! -f "$CONF_DIR/$f" ]]; then
    curl -fL --retry 3 -o "$CONF_DIR/$f" "$GEO_URL/$f" || echo "!! Không tải được $f (bỏ qua nếu bạn không dùng)"
  fi
done

# ---- config.yml ----
if [[ -f "$CONFIG" && $FORCE_CONFIG -eq 0 ]]; then
  echo ">> Giữ nguyên $CONFIG hiện có (thêm --force-config để tạo lại)"
else
  [[ -n "$API_HOST" ]]   || read -rp "ApiHost (vd https://panel.example.com): " API_HOST
  [[ -n "$API_KEY" ]]    || { read -rsp "ApiKey (không hiện khi gõ): " API_KEY; echo; }
  [[ -n "$NODE_ID" ]]    || read -rp "NodeID: " NODE_ID
  [[ -n "$NODE_TYPE" ]]  || read -rp "Loại node (vless/v2ray/vmess/trojan/shadowsocks): " NODE_TYPE

  [[ "$API_HOST" =~ ^https?://[^[:space:]\"]+$ ]] || die "ApiHost phải bắt đầu bằng http:// hoặc https://"
  [[ "$NODE_ID" =~ ^[0-9]+$ ]] || die "NodeID phải là số."
  [[ -n "$API_KEY" && "$API_KEY" != *'"'* && "$API_KEY" != *'\'* ]] || die "ApiKey trống hoặc chứa ký tự \" hay \\."

  case "$(printf '%s' "$NODE_TYPE" | tr '[:upper:]' '[:lower:]')" in
    vless)       NT=V2ray; ENABLE_VLESS=true; VLESS_FLOW_SET=1 ;;   # XHTTP không dùng flow vision
    v2ray)       NT=V2ray ;;
    vmess)       NT=Vmess ;;
    trojan)      NT=Trojan ;;
    shadowsocks) NT=Shadowsocks ;;
    *) die "Loại node không hợp lệ: $NODE_TYPE" ;;
  esac

  case "$CERT_MODE" in
    dns|http|file|none) ;;
    *) die "--cert-mode phải là dns, http, file hoặc none." ;;
  esac
  if [[ "$CERT_MODE" != "none" ]]; then
    [[ -n "$CERT_DOMAIN" ]] || read -rp "Tên miền cấp chứng chỉ (vd node01.example.com): " CERT_DOMAIN
    [[ "$CERT_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Tên miền không hợp lệ."
  else
    echo "!! CertMode none sẽ tắt hoàn toàn TLS của node."
  fi
  if [[ "$CERT_MODE" == "dns" ]]; then
    if [[ -z "$CERT_EMAIL" ]]; then
      read -rp "Email đăng ký chứng chỉ (Enter để dùng admin@$CERT_DOMAIN): " CERT_EMAIL
      [[ -n "$CERT_EMAIL" ]] || CERT_EMAIL="admin@$CERT_DOMAIN"
    fi
    [[ -n "$CF_TOKEN" ]] || { read -rsp "Token Cloudflare (quyền Zone:Read + DNS:Edit, không hiện khi gõ): " CF_TOKEN; echo; }
    [[ -n "$CF_TOKEN" && "$CF_TOKEN" != *'"'* && "$CF_TOKEN" != *'\'* ]] || die "Token Cloudflare trống hoặc chứa ký tự không hợp lệ."
  fi

  if [[ -f "$CONFIG" ]]; then
    cp -f "$CONFIG" "$CONFIG.bak"
  fi
  curl -fL --retry 3 -o "$CONFIG" "$BASE_URL/config.yml.template"
  mkdir -p "$CONF_DIR/cert"
  apply_config_edits
  chmod 600 "$CONFIG"

  echo
  echo "---- Cấu hình đã tạo (ApiKey và token đã được ẩn) ----"
  grep -nE '^[[:space:]]*(-[[:space:]]+)?(PanelType|ApiHost|NodeID|NodeType|EnableVless|VlessFlow|EnableREALITY|CertMode|CertDomain|Provider):' "$CONFIG" || true
  echo "------------------------------------------------------"
fi

# ---- systemd ----
cat > "$SERVICE" <<EOF
[Unit]
Description=XrayR Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=simple
LimitNOFILE=999999
WorkingDirectory=$INSTALL_DIR
Environment=XRAY_LOCATION_ASSET=$CONF_DIR
ExecStart=$INSTALL_DIR/XrayR --config $CONFIG
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable XrayR >/dev/null 2>&1
systemctl restart XrayR
sleep 3

echo
echo "Trạng thái: $(systemctl is-active XrayR || true)"
journalctl -u XrayR -n 25 --no-pager || true
echo
echo "Việc cần kiểm tra tiếp:"
echo " - Mở cổng node (vd 443/tcp) trên tường lửa của VPS và trong bảng quản lý của nhà cung cấp VPS."
echo " - Nếu dùng --cert-mode http: mở thêm cổng 80/tcp và trỏ tên miền thẳng về IP của VPS này."
echo "Xem log:     journalctl -u XrayR -f"
echo "Sửa config:  nano $CONFIG && systemctl restart XrayR"
echo "Lùi bản cũ:  systemctl stop XrayR && mv -f $INSTALL_DIR/XrayR.bak $INSTALL_DIR/XrayR && systemctl start XrayR"
