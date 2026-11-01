#!/usr/bin/env bash
# Cài / thêm node XrayR (bản tự build) chỉ bằng số Node.
#
# Lần đầu trên một VPS (script hỏi ApiHost, ApiKey, token Cloudflare đúng một lần rồi nhớ lại):
#   bash <(curl -fsSL https://raw.githubusercontent.com/phuonggia010699/xrayr-custom/main/install-xrayr.sh) 5
#
# Các lần sau, thêm node khác vào cùng VPS (chỉ cần số Node):
#   bash <(curl -fsSL https://raw.githubusercontent.com/phuonggia010699/xrayr-custom/main/install-xrayr.sh) 7
#
# Script tự hỏi panel xem node đó là loại gì (VLESS/XHTTP, VMess, Trojan, Shadowsocks, Hysteria2),
# cổng nào, có TLS hay không, rồi tự viết config.yml cho TẤT CẢ node đã thêm trên VPS này.
#
# Dùng chung cho nhiều VPS: tạo sẵn file /etc/XrayR/xrayr.env (chmod 600) với nội dung
#   SAVED_API_HOST=https://panel.example.com
#   SAVED_API_KEY=khoa-panel
#   SAVED_CF_TOKEN=token-cloudflare
#   SAVED_CERT_EMAIL=email@cua-ban.com
# rồi chép file đó sang từng VPS mới; script sẽ không hỏi lại các thông tin này.
#
# Cú pháp: install-xrayr.sh [tùy chọn] ID [ID ...]
#   --api-host URL      địa chỉ panel (được nhớ lại sau lần đầu)
#   --api-key KEY       khóa panel (nên để script hỏi, không hiện khi gõ)
#   --cf-token TOKEN    token Cloudflare (quyền Zone:Read + DNS:Edit; nên để script hỏi)
#   --cert-mode MODE    dns | http | file | none (mặc định dns)
#   --cert-domain NAME  tên miền cấp chứng chỉ (mặc định lấy từ panel hoặc node trước đó)
#   --cert-email MAIL   email đăng ký chứng chỉ (mặc định admin@<tên miền>)
#   --node-type TYPE    vless | vmess | trojan | shadowsocks | hysteria2
#                       (chỉ cần khi cùng số ID tồn tại ở nhiều loại node)
#   --panel-type TYPE   mặc định NewV2board (đúng cho Zicboard/V2Board)
#   --list              liệt kê node đang cấu hình trên VPS này
#   --remove ID         bỏ node khỏi VPS này
#   --dry-run           chỉ dò panel và in config, không cài gì (để thử)
#   --block-cn          bật chặn lưu lượng đi tới Trung Quốc (geoip:cn, geosite:cn) và dải IP nội bộ
#                       trên VPS ĐANG CÓ XrayR; giữ nguyên node, tự lùi nếu dịch vụ không chạy
#   --allow-cn          khi thêm node mới: KHÔNG tự bật chặn lưu lượng về Trung Quốc (mặc định là chặn)
#   --upgrade           CHỈ thay file chạy XrayR, giữ nguyên config.yml và dịch vụ hiện có;
#                       tự lùi về bản cũ nếu bản mới không chạy (dùng cho VPS đang có node)

set -euo pipefail

BASE_URL="${BASE_URL:-https://github.com/phuonggia010699/xrayr-custom/releases/latest/download}"
GEO_URL="${GEO_URL:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"

INSTALL_DIR="${INSTALL_DIR:-/usr/local/XrayR}"
CONF_DIR="${CONF_DIR:-/etc/XrayR}"
CONFIG="$CONF_DIR/config.yml"
ENVFILE="$CONF_DIR/xrayr.env"
STATE="$CONF_DIR/nodes.tsv"
SERVICE=/etc/systemd/system/XrayR.service

API_HOST="${API_HOST:-}" ; API_KEY="" ; CF_TOKEN="" ; CERT_MODE="" ; CERT_DOMAIN_OPT="" ; CERT_EMAIL_OPT=""
FORCE_TYPE="" ; PANEL_TYPE="" ; ACTION=add ; DRY_RUN=0
IDS=() ; REMOVE_IDS=() ; BLOCK_CN=1

die()  { echo "LỖI: $*" >&2; exit 1; }
note() { echo ">> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)    ACTION=list; shift; continue ;;
    --dry-run) DRY_RUN=1; shift; continue ;;
    --upgrade) ACTION=upgrade; shift; continue ;;
    --block-cn) ACTION=blockcn; shift; continue ;;
    --allow-cn) BLOCK_CN=0; shift; continue ;;
    --api-host|--api-key|--cf-token|--cert-mode|--cert-domain|--cert-email|--node-type|--panel-type|--remove)
      [[ $# -ge 2 ]] || die "Thiếu giá trị cho $1" ;;
  esac
  case "$1" in
    --api-host)    API_HOST="$2"; shift 2 ;;
    --api-key)     API_KEY="$2"; shift 2 ;;
    --cf-token)    CF_TOKEN="$2"; shift 2 ;;
    --cert-mode)   CERT_MODE="$2"; shift 2 ;;
    --cert-domain) CERT_DOMAIN_OPT="$2"; shift 2 ;;
    --cert-email)  CERT_EMAIL_OPT="$2"; shift 2 ;;
    --node-type)   FORCE_TYPE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --panel-type)  PANEL_TYPE="$2"; shift 2 ;;
    --remove)      ACTION=remove; REMOVE_IDS+=("$2"); shift 2 ;;
    [0-9]*)        [[ "$1" =~ ^[0-9]+$ ]] || die "ID node không hợp lệ: $1"; IDS+=("$1"); shift ;;
    *) die "Tham số không hợp lệ: $1" ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "Cần chạy bằng root."
  command -v systemctl >/dev/null || die "Máy này không có systemd."
fi

pkg_install() {
  if command -v apt-get >/dev/null; then apt-get update -y >/dev/null && apt-get install -y "$@" >/dev/null
  elif command -v yum >/dev/null; then yum install -y "$@" >/dev/null
  else die "Hãy tự cài: $*"; fi
}
command -v curl >/dev/null || pkg_install curl
if [[ "$ACTION" != "upgrade" && "$ACTION" != "blockcn" ]]; then
  command -v jq >/dev/null || { note "Cài jq (để đọc cấu hình từ panel)"; pkg_install jq; }
fi

# ------------------------------------------------------------------
# Tải và thay file chạy XrayR (chỉ tải khi bản mới khác bản đang cài)
# install_binary TARGET -> return 0 nếu đã thay, 10 nếu đã là bản mới nhất
# ------------------------------------------------------------------
install_binary() {
  local target="$1" dir arch sums new want have got avail
  dir="$(dirname "$target")"
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Kiến trúc $(uname -m) chưa được hỗ trợ." ;;
  esac
  mkdir -p "$dir"
  sums="$(mktemp)"; new="$target.new"
  curl -fsSL --retry 3 -o "$sums" "$BASE_URL/SHA256SUMS" || { rm -f "$sums"; die "Không tải được SHA256SUMS từ $BASE_URL"; }
  want="$(awk -v f="XrayR-linux-$arch" '$2==f{print $1}' "$sums")"; rm -f "$sums"
  [[ -n "$want" ]] || die "SHA256SUMS không có XrayR-linux-$arch"
  have=""; [[ -f "$target" ]] && have="$(sha256sum "$target" | awk '{print $1}')"
  if [[ "$have" == "$want" ]]; then
    note "XrayR đã là bản mới nhất, không cần tải lại"
    return 10
  fi
  avail="$(df -Pm "$dir" | awk 'NR==2{print $4}')"
  [[ "$avail" -ge 300 ]] || die "Ổ đĩa chỉ còn ${avail} MB, cần ít nhất 300 MB. Hãy dọn bớt rồi chạy lại."
  note "Tải XrayR (linux/$arch), khoảng 124 MB"
  curl -fL --retry 3 -o "$new" "$BASE_URL/XrayR-linux-$arch" || { rm -f "$new"; die "Tải file chạy thất bại."; }
  got="$(sha256sum "$new" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || { rm -f "$new"; die "Sai checksum (file tải về bị lỗi hoặc cắt cụt), dừng cài. Dịch vụ cũ chưa bị đụng tới."; }
  chmod +x "$new"
  "$new" version >/dev/null 2>&1 || { rm -f "$new"; die "File tải về không chạy được trên máy này. Dịch vụ cũ chưa bị đụng tới."; }
  systemctl stop XrayR 2>/dev/null || true
  [[ -f "$target" ]] && mv -f "$target" "$target.bak"
  mv -f "$new" "$target"
  return 0
}

# --upgrade: chỉ thay file chạy, giữ nguyên config và service, tự lùi nếu lỗi
if [[ "$ACTION" == "upgrade" ]]; then
  EXE="$(systemctl show XrayR -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1 || true)"
  [[ -n "$EXE" && -f "$EXE" ]] || EXE="$INSTALL_DIR/XrayR"
  [[ -f "$EXE" ]] || die "Không tìm thấy XrayR đã cài (đã thử: $EXE). Chế độ --upgrade chỉ dành cho VPS đang có XrayR."
  note "Nâng cấp file chạy: $EXE (giữ nguyên config và dịch vụ)"
  rc=0; install_binary "$EXE" || rc=$?
  [[ $rc -eq 10 ]] && exit 0
  [[ $rc -eq 0 ]] || exit "$rc"
  systemctl start XrayR || true
  sleep 8
  if systemctl is-active --quiet XrayR; then
    echo "Trạng thái: active. Bản cũ lưu tại $EXE.bak"
    journalctl -u XrayR -n 15 --no-pager || true
    echo "Lùi bản cũ nếu cần: systemctl stop XrayR && mv -f $EXE.bak $EXE && systemctl start XrayR"
    exit 0
  fi
  echo "!! Bản mới không chạy được, đang lùi về bản cũ ..." >&2
  journalctl -u XrayR -n 25 --no-pager >&2 || true
  systemctl stop XrayR 2>/dev/null || true
  mv -f "$EXE.bak" "$EXE"
  systemctl start XrayR || true
  sleep 3
  echo "Đã lùi về bản cũ. Trạng thái: $(systemctl is-active XrayR || true)" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Chặn lưu lượng quay về Trung Quốc (route.json + custom_outbound.json)
# ------------------------------------------------------------------
write_block_cn_files() { # $1 = thư mục chứa file
  local d="$1"
  cat > "$d/route.json" <<'JSON'
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
    { "type": "field", "outboundTag": "block", "domain": ["geosite:cn"] },
    { "type": "field", "outboundTag": "block", "ip": ["geoip:cn"] }
  ]
}
JSON
  cat > "$d/custom_outbound.json" <<'JSON'
[
  { "tag": "direct", "protocol": "freedom", "settings": {} },
  { "tag": "block", "protocol": "blackhole" }
]
JSON
}

# --block-cn: bật chặn trên VPS đang chạy, tự lùi nếu lỗi
if [[ "$ACTION" == "blockcn" ]]; then
  [[ -f "$CONFIG" ]] || die "Không thấy $CONFIG. Chế độ --block-cn chỉ dành cho VPS đang có XrayR."
  cfgpath() { grep -E "^$1:" "$CONFIG" | head -1 | sed -E "s/^[^:]*:[[:space:]]*//; s/^#.*$//; s/[[:space:]]+#.*$//; s/^\"//; s/\"$//"; }
  [[ -z "$(cfgpath RouteConfigPath)" && -z "$(cfgpath OutboundConfigPath)" ]] \
    || die "Config đã có RouteConfigPath/OutboundConfigPath riêng. Để khỏi ghi đè, hãy tự thêm quy tắc chặn geoip:cn vào file route của bạn."
  grep -qE '^RouteConfigPath:' "$CONFIG" && grep -qE '^OutboundConfigPath:' "$CONFIG" \
    || die "Không thấy khóa RouteConfigPath/OutboundConfigPath ở đầu config.yml; hãy thêm tay."

  # Xray cần geoip.dat/geosite.dat có nhóm "cn" ở thư mục tài nguyên mà dịch vụ dùng
  EXE="$(systemctl show XrayR -p ExecStart --value 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1 || true)"
  ASSET="$(systemctl show XrayR -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^XRAY_LOCATION_ASSET=//p' | head -1 || true)"
  [[ -n "$ASSET" ]] || ASSET="$(dirname "${EXE:-$INSTALL_DIR/XrayR}")"
  for f in geoip.dat geosite.dat; do
    [[ -f "$ASSET/$f" ]] || { note "Tải $f vào $ASSET"; curl -fL --retry 3 -o "$ASSET/$f" "$GEO_URL/$f" || die "Không tải được $f"; }
  done

  cp -f "$CONFIG" "$CONFIG.bak.blockcn"
  write_block_cn_files "$CONF_DIR"
  sed -i -E "s|^RouteConfigPath:.*|RouteConfigPath: $CONF_DIR/route.json|; s|^OutboundConfigPath:.*|OutboundConfigPath: $CONF_DIR/custom_outbound.json|" "$CONFIG"
  note "Đã bật chặn lưu lượng về Trung Quốc, khởi động lại XrayR"
  systemctl restart XrayR || true
  sleep 8
  if systemctl is-active --quiet XrayR; then
    echo "Trạng thái: active. Config cũ lưu tại $CONFIG.bak.blockcn"
    journalctl -u XrayR -n 15 --no-pager || true
    echo "Tắt chặn nếu cần: cp $CONFIG.bak.blockcn $CONFIG && systemctl restart XrayR"
    exit 0
  fi
  echo "!! XrayR không chạy với cấu hình chặn, đang lùi về config cũ ..." >&2
  journalctl -u XrayR -n 25 --no-pager >&2 || true
  cp -f "$CONFIG.bak.blockcn" "$CONFIG"
  systemctl restart XrayR || true
  sleep 3
  echo "Đã lùi về config cũ. Trạng thái: $(systemctl is-active XrayR || true)" >&2
  exit 1
fi

mkdir -p "$CONF_DIR/cert"

# ------------------------------------------------------------------
# Trạng thái: xrayr.env (ApiHost, ApiKey, token) và nodes.tsv (danh sách node)
# nodes.tsv: id|nodetype|vless|certmode|domain|port|proto|reality|label
# ------------------------------------------------------------------
load_env() { [[ -f "$ENVFILE" ]] && source "$ENVFILE" || true; }

save_env() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  umask 077
  {
    printf 'SAVED_API_HOST=%q\n'    "$API_HOST"
    printf 'SAVED_API_KEY=%q\n'     "$API_KEY"
    printf 'SAVED_CF_TOKEN=%q\n'    "$CF_TOKEN"
    printf 'SAVED_CERT_MODE=%q\n'   "$CERT_MODE"
    printf 'SAVED_PANEL_TYPE=%q\n'  "$PANEL_TYPE"
    printf 'SAVED_CERT_EMAIL=%q\n'  "$CERT_EMAIL_OPT"
  } > "$ENVFILE"
  chmod 600 "$ENVFILE"
}

# Nếu VPS đã cài bằng script cũ (có config.yml, chưa có nodes.tsv) thì nhập lại node cũ để không mất
import_legacy() {
  [[ -f "$CONFIG" && ! -f "$STATE" ]] || return 0
  local id nt vl cm cd
  get() { grep -E "^[[:space:]]*(-[[:space:]]+)?$1:" "$CONFIG" | head -1 | sed -E "s/^[^:]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^\"//; s/\"$//"; }
  id="$(get NodeID)"; nt="$(get NodeType)"; vl="$(get EnableVless)"; cm="$(get CertMode)"; cd="$(get CertDomain)"
  [[ "$id" =~ ^[0-9]+$ ]] || return 0
  note "Phát hiện config cũ: nhập node $id vào danh sách để không bị mất"
  [[ "$DRY_RUN" -eq 1 ]] || cp -f "$CONFIG" "$CONFIG.legacy.bak"
  [[ -n "${SAVED_API_HOST:-}" ]] || { SAVED_API_HOST="$(get ApiHost)"; }
  [[ -n "${SAVED_API_KEY:-}"  ]] || { SAVED_API_KEY="$(get ApiKey)"; }
  [[ -n "${SAVED_CF_TOKEN:-}" ]] || { SAVED_CF_TOKEN="$(get CLOUDFLARE_DNS_API_TOKEN)"; }
  API_HOST="${API_HOST:-$SAVED_API_HOST}"; API_KEY="${API_KEY:-$SAVED_API_KEY}"; CF_TOKEN="${CF_TOKEN:-$SAVED_CF_TOKEN}"
  CERT_MODE="${CERT_MODE:-${cm:-dns}}"; PANEL_TYPE="${PANEL_TYPE:-$(get PanelType)}"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "${nt:-V2ray}" "${vl:-false}" "${cm:-dns}" "$cd" "?" "tcp" "0" "legacy" > "$STATE"
  save_env
}

state_get()  { [[ -f "$STATE" ]] && grep -E "^$1\|" "$STATE" | head -1 || true; }
state_drop() { [[ -f "$STATE" ]] && { grep -vE "^$1\|" "$STATE" > "$STATE.tmp" || true; mv -f "$STATE.tmp" "$STATE"; } || true; }

load_env
# --dry-run làm việc trên bản sao tạm của danh sách node, không đổi gì trên máy
if [[ "$DRY_RUN" -eq 1 ]]; then
  REAL_STATE="$STATE"; STATE="$(mktemp)"; rm -f "$STATE"
  [[ -f "$REAL_STATE" ]] && cp "$REAL_STATE" "$STATE"
  trap 'rm -f "$STATE"' EXIT
fi
import_legacy

API_HOST="${API_HOST:-${SAVED_API_HOST:-}}"
API_KEY="${API_KEY:-${SAVED_API_KEY:-}}"
CF_TOKEN="${CF_TOKEN:-${SAVED_CF_TOKEN:-}}"
CERT_MODE="${CERT_MODE:-${SAVED_CERT_MODE:-dns}}"
PANEL_TYPE="${PANEL_TYPE:-${SAVED_PANEL_TYPE:-NewV2board}}"
CERT_EMAIL_OPT="${CERT_EMAIL_OPT:-${SAVED_CERT_EMAIL:-}}"

case "$ACTION" in
  list)
    [[ -f "$STATE" ]] || { echo "Chưa có node nào trên VPS này."; exit 0; }
    printf '%-6s %-12s %-10s %-8s %-6s %s\n' ID LOẠI CHỨNG-CHỈ CỔNG GIAO-THỨC TÊN-MIỀN
    while IFS='|' read -r id nt vl cm dom port proto rl label; do
      printf '%-6s %-12s %-10s %-8s %-6s %s\n' "$id" "$label" "$cm" "$port" "$proto" "$dom"
    done < "$STATE"
    exit 0 ;;
  remove)
    for r in "${REMOVE_IDS[@]}"; do state_drop "$r"; note "Đã bỏ node $r"; done ;;
  add)
    [[ ${#IDS[@]} -gt 0 ]] || die "Hãy nhập số node. Ví dụ: ... install-xrayr.sh 5"
    ;;
esac

# ------------------------------------------------------------------
# Thông tin panel (hỏi một lần rồi nhớ)
# ------------------------------------------------------------------
ask_panel() {
  [[ -n "$API_HOST" ]] || read -rp "ApiHost (vd https://panel.example.com): " API_HOST
  [[ -n "$API_KEY"  ]] || { read -rsp "ApiKey (không hiện khi gõ): " API_KEY; echo; }
  API_HOST="${API_HOST%/}"
  [[ "$API_HOST" =~ ^https?://[^[:space:]\"\\]+$ ]] || die "ApiHost phải bắt đầu bằng http:// hoặc https://"
  [[ -n "$API_KEY" && "$API_KEY" != *'"'* && "$API_KEY" != *'\'* && "$API_KEY" != *[[:space:]]* ]] || die "ApiKey trống hoặc chứa ký tự không hợp lệ."
}

# Gọi API panel mà không để lộ ApiKey trên dòng lệnh (đưa qua stdin cho curl)
api_get() { # $1=id $2=type
  local key; key="$(printf '%s' "$API_KEY" | jq -sRr @uri)"
  printf 'url = "%s/api/v1/server/UniProxy/config?node_id=%s&node_type=%s&token=%s"\n' "$API_HOST" "$1" "$2" "$key" \
    | curl -fsS --max-time 15 -K - 2>/dev/null
}

# probe_node ID -> in ra "type<TAB>json" cho từng loại khớp
probe_node() {
  local id="$1" t j
  for t in vless vmess trojan shadowsocks hysteria; do
    [[ -z "$FORCE_TYPE" || "$FORCE_TYPE" == "$t" || ( "$FORCE_TYPE" == "hysteria2" && "$t" == "hysteria" ) ]] || continue
    j="$(api_get "$id" "$t" || true)"
    [[ -n "$j" ]] || continue
    if jq -e '(.server_port // 0 | tonumber) > 0' >/dev/null 2>&1 <<<"$j"; then
      printf '%s\t%s\n' "$t" "$(jq -c . <<<"$j")"
    fi
  done
}

# ------------------------------------------------------------------
# Thêm node
# ------------------------------------------------------------------
add_node() {
  local id="$1" found=() types=() choice="" t j line n
  note "Hỏi panel về node $id ..."
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    types+=("${line%%$'\t'*}"); found+=("${line#*$'\t'}")
  done < <(probe_node "$id")

  [[ ${#types[@]} -gt 0 ]] || die "Panel không có node $id (hoặc sai ApiHost/ApiKey). Kiểm tra lại số node và khóa."

  if [[ ${#types[@]} -eq 1 ]]; then
    n=0
  else
    echo "Số $id tồn tại ở nhiều loại node: ${types[*]}"
    [[ -t 0 ]] || die "Hãy thêm --node-type <loại>."
    read -rp "Chọn loại [${types[*]}]: " choice
    n=-1; for i in "${!types[@]}"; do [[ "${types[$i]}" == "$choice" ]] && n=$i; done
    [[ $n -ge 0 ]] || die "Loại không hợp lệ."
  fi
  t="${types[$n]}"; j="${found[$n]}"

  local nt vless=false reality=0 tlsflag port proto=tcp net sni=""
  port="$(jq -r '.server_port|tonumber' <<<"$j")"
  tlsflag="$(jq -r '(.tls // 0)|tonumber' <<<"$j")"
  net="$(jq -r '.network // ""' <<<"$j")"

  case "$t" in
    vless)       nt=V2ray; vless=true ;;
    vmess)       nt=V2ray ;;
    trojan)      nt=Trojan ;;
    shadowsocks) nt=Shadowsocks; tlsflag=0 ;;
    hysteria)
      local ver; ver="$(jq -r '.version // 2' <<<"$j")"
      [[ "$ver" == "2" ]] || die "Node $id là Hysteria phiên bản $ver; chỉ hỗ trợ Hysteria2. Hãy đặt phiên bản 2 trong panel."
      nt=Hysteria2; proto=udp; tlsflag=1 ;;
  esac
  [[ "$t" == "trojan" ]] && tlsflag=1
  [[ "$tlsflag" == "2" ]] && reality=1

  # Tên miền chứng chỉ: tham số > gợi ý từ panel > node khác trên VPS > hỏi
  sni="$(jq -r '[.tls_settings.server_name, .tlsSettings.serverName, .tls_settings.serverName, .server_name] | map(select(. != null and . != "")) | .[0] // ""' <<<"$j")"
  if [[ -z "$sni" && ( "$t" == "hysteria" || "$t" == "trojan" ) ]]; then
    sni="$(jq -r '.host // ""' <<<"$j")"
  fi

  local cm="$CERT_MODE" dom=""
  if [[ "$tlsflag" == "0" || "$reality" == "1" ]]; then
    cm=none
  else
    [[ "$cm" != "none" ]] || [[ "$t" != "hysteria" ]] || die "Hysteria2 bắt buộc phải có TLS (đừng dùng --cert-mode none)."
    dom="${CERT_DOMAIN_OPT:-$sni}"
    if [[ -z "$dom" && -f "$STATE" ]]; then dom="$(awk -F'|' '$6!="" && $4!="none"{print $5; exit}' "$STATE")"; fi
    if [[ -z "$dom" ]]; then read -rp "Tên miền cấp chứng chỉ cho node $id (vd node01.example.com): " dom; fi
    [[ "$dom" =~ ^[A-Za-z0-9.-]+$ ]] || die "Tên miền không hợp lệ: '$dom'"
    note "Node $id dùng tên miền chứng chỉ: $dom"
  fi

  state_drop "$id"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$id" "$nt" "$vless" "$cm" "$dom" "$port" "$proto" "$reality" "$t${net:+/$net}" >> "$STATE"
  note "Node $id: loại $t${net:+ ($net)}, cổng $port/$proto, TLS=$tlsflag"
}

# ------------------------------------------------------------------
# Viết config.yml từ danh sách node
# ------------------------------------------------------------------
yq_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g; s/"/\\"/g')"; }

render_node() { # id nt vless cm dom port proto reality label
  local id="$1" nt="$2" vl="$3" cm="$4" dom="$5" rl="$8" email
  email="${CERT_EMAIL_OPT:-admin@${dom:-example.com}}"
  cat <<EOF
  - PanelType: $(yq_str "$PANEL_TYPE")
    ApiConfig:
      ApiHost: $(yq_str "$API_HOST")
      ApiKey: $(yq_str "$API_KEY")
      NodeID: $id
      NodeType: $nt
      Timeout: 30
      EnableVless: $vl
      VlessFlow: ""
      SpeedLimit: 0
      DeviceLimit: 0
      RuleListPath:
      DisableCustomConfig: false
    ControllerConfig:
      ListenIP: 0.0.0.0
      SendIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableDNS: false
      DNSType: AsIs
      EnableProxyProtocol: false
      AutoSpeedLimitConfig:
        Limit: 0
        WarnTimes: 0
        LimitSpeed: 0
        LimitDuration: 0
      GlobalDeviceLimitConfig:
        Enable: false
        RedisNetwork: tcp
        RedisAddr: 127.0.0.1:6379
        RedisUsername:
        RedisPassword: YOUR PASSWORD
        RedisDB: 0
        Timeout: 5
        Expiry: 60
      EnableFallback: false
      DisableLocalREALITYConfig: $([[ "$rl" == "1" ]] && echo true || echo false)
      EnableREALITY: false
      CertConfig:
        CertMode: $cm
        CertDomain: $(yq_str "$dom")
        CertFile: $CONF_DIR/cert/$dom.cert
        KeyFile: $CONF_DIR/cert/$dom.key
        Provider: cloudflare
        Email: $email
        DNSEnv:
          CLOUDFLARE_DNS_API_TOKEN: $(yq_str "$CF_TOKEN")
EOF
}

render_config() {
  cat <<EOF
# File này được install-xrayr.sh tự tạo lại mỗi lần thêm/bỏ node. Danh sách node nằm ở $STATE.
Log:
  Level: warning
  AccessPath:
  ErrorPath:
DnsConfigPath:
RouteConfigPath: $([[ "$BLOCK_CN" -eq 1 ]] && echo "$CONF_DIR/route.json")
InboundConfigPath:
OutboundConfigPath: $([[ "$BLOCK_CN" -eq 1 ]] && echo "$CONF_DIR/custom_outbound.json")
ConnectionConfig:
  Handshake: 4
  ConnIdle: 30
  UplinkOnly: 2
  DownlinkOnly: 4
  BufferSize: 64
Nodes:
EOF
  local id nt vl cm dom port proto rl label
  while IFS='|' read -r id nt vl cm dom port proto rl label; do
    [[ -n "$id" ]] || continue
    render_node "$id" "$nt" "$vl" "$cm" "$dom" "$port" "$proto" "$rl" "$label"
  done < "$STATE"
}

# ------------------------------------------------------------------
# Chạy
# ------------------------------------------------------------------
if [[ "$ACTION" == "add" ]]; then
  ask_panel
  for id in "${IDS[@]}"; do add_node "$id"; done

  # Cần token Cloudflare nếu có node nào dùng chứng chỉ dns
  if [[ -f "$STATE" ]] && awk -F'|' '$4=="dns"{f=1} END{exit !f}' "$STATE"; then
    [[ -n "$CF_TOKEN" ]] || { read -rsp "Token Cloudflare (quyền Zone:Read + DNS:Edit, không hiện khi gõ): " CF_TOKEN; echo; }
    [[ -n "$CF_TOKEN" && "$CF_TOKEN" != *'"'* && "$CF_TOKEN" != *'\'* ]] || die "Token Cloudflare trống hoặc chứa ký tự không hợp lệ."
  fi
elif [[ "$ACTION" == "remove" ]]; then
  [[ -f "$STATE" && -s "$STATE" ]] || die "VPS này không còn node nào. Hãy dừng dịch vụ: systemctl disable --now XrayR"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  render_config | sed -E 's/(ApiKey: ).*/\1"***"/; s/(CLOUDFLARE_DNS_API_TOKEN: ).*/\1"***"/'
  exit 0
fi

# ---- Cài/cập nhật file chạy ----
mkdir -p "$INSTALL_DIR"
rc=0; install_binary "$INSTALL_DIR/XrayR" || rc=$?
[[ $rc -eq 0 || $rc -eq 10 ]] || exit "$rc"

for f in geoip.dat geosite.dat; do
  [[ -f "$CONF_DIR/$f" ]] || curl -fL --retry 3 -o "$CONF_DIR/$f" "$GEO_URL/$f" || echo "!! Không tải được $f (bỏ qua nếu bạn không dùng)"
done

# ---- Ghi trạng thái + config ----
save_env
[[ "$BLOCK_CN" -eq 0 ]] || write_block_cn_files "$CONF_DIR"
[[ -f "$CONFIG" ]] && cp -f "$CONFIG" "$CONFIG.bak"
render_config > "$CONFIG"
chmod 600 "$CONFIG"

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
sleep 4

echo
echo "Trạng thái: $(systemctl is-active XrayR || true)"
journalctl -u XrayR -n 20 --no-pager || true
echo
echo "Node trên VPS này:"
printf '  %-6s %-16s %-6s %s\n' ID LOẠI CỔNG TÊN-MIỀN
while IFS='|' read -r id nt vl cm dom port proto rl label; do
  [[ -n "$id" ]] || continue
  printf '  %-6s %-16s %-6s %s\n' "$id" "$label" "$port/$proto" "$dom"
done < "$STATE"
echo
echo "Việc cần kiểm tra tiếp:"
echo " - Mở đúng cổng và đúng giao thức ở trên (tcp hoặc udp) trên tường lửa VPS và trong bảng quản lý của nhà cung cấp."
echo " - Node Hysteria2 chạy UDP: tên miền phải để DNS only (mây xám) trên Cloudflare."
echo "Xem log:      journalctl -u XrayR -f"
echo "Danh sách:    bash <(curl -fsSL <URL-script>) --list"
echo "Lùi bản cũ:   systemctl stop XrayR && mv -f $INSTALL_DIR/XrayR.bak $INSTALL_DIR/XrayR && systemctl start XrayR"
