#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
NFT_RUNTIME="$ROOT_DIR/trafira/files/usr/lib/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
IP_LOG="$WORK_DIR/ip.log"
LOGGER_LOG="$WORK_DIR/logger.log"
SYSCTL_LOG="$WORK_DIR/sysctl.log"

nft_ucode() {
  ucode -L "$TRAFIRA_LIB" "$NFT_RUNTIME" "$@"
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'ip log:\n' >&2
  cat "$IP_LOG" >&2 2>/dev/null || true
  printf 'logger log:\n' >&2
  cat "$LOGGER_LOG" >&2 2>/dev/null || true
  printf 'sysctl log:\n' >&2
  cat "$SYSCTL_LOG" >&2 2>/dev/null || true
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq "$expected" "$file" || fail "$label: expected '$expected'"
}

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/ip" <<'IP'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'ip'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${IP_LOG:?}"

if [ "$#" -eq 4 ] && [ "$1" = "route" ] && [ "$2" = "list" ] && [ "$3" = "table" ]; then
  printf '%s\n' "${IP_ROUTE_OUTPUT:-}"
  exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = "-4" ] && [ "$2" = "rule" ] && [ "$3" = "list" ]; then
  printf '%s\n' "${IP_RULE_OUTPUT:-}"
  exit 0
fi

exit 0
IP
chmod 0755 "$WORK_DIR/bin/ip"

cat >"$WORK_DIR/bin/sysctl" <<'SYSCTL'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'sysctl'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${SYSCTL_LOG:?}"

if [ "$#" -eq 2 ] && [ "$1" = "-n" ]; then
  case "$2" in
    net.ipv6.conf.all.disable_ipv6)
      printf '%s\n' "${SYSCTL_IPV6_ALL_DISABLE:-0}"
      exit 0
      ;;
    net.ipv6.conf.lo.disable_ipv6)
      printf '%s\n' "${SYSCTL_IPV6_LO_DISABLE:-0}"
      exit 0
      ;;
  esac
fi

exit 1
SYSCTL
chmod 0755 "$WORK_DIR/bin/sysctl"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${LOGGER_LOG:?}"
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"
export IP_LOG LOGGER_LOG SYSCTL_LOG

rt_tables="$WORK_DIR/rt_tables"
SYSCTL_IPV6_ALL_DISABLE=1 SYSCTL_IPV6_LO_DISABLE=1 \
  IP_ROUTE_OUTPUT='' IP_RULE_OUTPUT='' \
  nft_ucode ensure-tproxy-route-rule trafira 0x00100000 "$rt_tables"

assert_contains "$IP_LOG" $'ip\troute\tadd\tlocal\t0.0.0.0/0\tdev\tlo\ttable\ttrafira' "IPv4 TPROXY route"
assert_contains "$IP_LOG" $'ip\t-4\trule\tadd\tfwmark\t0x00100000/0x00100000\ttable\ttrafira\tpriority\t105' "IPv4 TPROXY rule"
