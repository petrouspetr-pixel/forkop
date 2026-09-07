#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$FORKOP_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"
STATE_FILE="$WORK_DIR/uci.state"
UCI_LOG="$WORK_DIR/uci.log"
INCLUDE_FILE="$WORK_DIR/forkop-input.nft"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$STATE_FILE" <<'EOF'
firewall.defaults=defaults
EOF
: >"$UCI_LOG"

env \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_UCI_STATE_FILE="$STATE_FILE" \
  FORKOP_UCI_LOG_FILE="$UCI_LOG" \
  FORKOP_FIREWALL_INCLUDE_FILE="$INCLUDE_FILE" \
  FORKOP_PACKAGE_TEST_MODE=1 \
  NFT_FAKEIP_MARK=0x04000000 \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" ensure-tproxy-firewall

grep -Fxq 'firewall.forkop_tproxy_input=include' "$STATE_FILE" ||
  fail "named fw4 include section was not created"
grep -Fxq 'firewall.forkop_tproxy_input.type=nftables' "$STATE_FILE" ||
  fail "fw4 include type must be nftables"
grep -Fxq "firewall.forkop_tproxy_input.path=$INCLUDE_FILE" "$STATE_FILE" ||
  fail "fw4 include path mismatch"
grep -Fxq 'firewall.forkop_tproxy_input.position=chain-pre' "$STATE_FILE" ||
  fail "Forkop rule must run before regular fw4 input rules"
grep -Fxq 'firewall.forkop_tproxy_input.chain=input' "$STATE_FILE" ||
  fail "Forkop rule must be inserted in fw4 input chain"
grep -Fxq 'commit firewall' "$UCI_LOG" ||
  fail "firewall UCI changes were not committed"

expected='meta l4proto { tcp, udp } meta mark & 0x04000000 == 0x04000000 accept comment "!forkop: Allow TPROXY-marked input"'
[ "$(cat "$INCLUDE_FILE")" = "$expected" ] ||
  fail "unexpected fw4 input rule"

: >"$UCI_LOG"
env \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_UCI_STATE_FILE="$STATE_FILE" \
  FORKOP_UCI_LOG_FILE="$UCI_LOG" \
  FORKOP_FIREWALL_INCLUDE_FILE="$INCLUDE_FILE" \
  FORKOP_PACKAGE_TEST_MODE=1 \
  NFT_FAKEIP_MARK=0x04000000 \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" ensure-tproxy-firewall

[ ! -s "$UCI_LOG" ] ||
  fail "idempotent firewall ensure must not commit unchanged UCI"

if env \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_UCI_STATE_FILE="$STATE_FILE" \
  FORKOP_FIREWALL_INCLUDE_FILE="$WORK_DIR/invalid.nft" \
  FORKOP_PACKAGE_TEST_MODE=1 \
  NFT_FAKEIP_MARK='0x04000000; drop' \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" ensure-tproxy-firewall >/dev/null 2>&1; then
  fail "invalid nft mark must be rejected"
fi
[ ! -e "$WORK_DIR/invalid.nft" ] ||
  fail "invalid mark must not create an nft file"

: >"$UCI_LOG"
env \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_UCI_STATE_FILE="$STATE_FILE" \
  FORKOP_UCI_LOG_FILE="$UCI_LOG" \
  FORKOP_FIREWALL_INCLUDE_FILE="$INCLUDE_FILE" \
  FORKOP_PACKAGE_TEST_MODE=1 \
  NFT_FAKEIP_MARK=0x04000000 \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" remove-tproxy-firewall

if grep -Fq 'firewall.forkop_tproxy_input' "$STATE_FILE"; then
  fail "managed fw4 include section survived removal"
fi
[ ! -e "$INCLUDE_FILE" ] ||
  fail "managed nft include file survived removal"
grep -Fxq 'commit firewall' "$UCI_LOG" ||
  fail "firewall removal was not committed"

printf 'fw4 TPROXY input integration checks passed\n'