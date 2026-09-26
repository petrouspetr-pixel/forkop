#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFIRA_LIB="$ROOT_DIR/trafira/files/usr/lib"
GENERATOR="$TRAFIRA_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "fully",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain": "example.com",
      "fully_routed_ips": [ "192.168.1.50" ]
    },
    {
      ".name": "scoped",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "source_ip_cidr": [ "192.168.1.60/32" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

generate_for_version() {
  local version="$1"
  local output="$2"
  mkdir -p "$output.section-cache" "$output.rulesets"
  ucode -L "$TRAFIRA_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "$version"
}

generate_for_version "1.13.18-extended-2.6.5" "$WORK_DIR/sb113.json"
generate_for_version "1.14.1-extended-2.7.2" "$WORK_DIR/sb114.json"
generate_for_version "" "$WORK_DIR/unknown.json"

cat >"$WORK_DIR/assert.uc" <<'UCODE'
let fs = require("fs");

function fail(message) {
    warn("FAIL: ", message, "\n");
    exit(1);
}

function assert(condition, message) {
    if (!condition)
        fail(message);
}

function dns_rules(name) {
    let text = fs.readfile(ARGV[0] + "/" + name);
    assert(text != null, "missing generated config " + name);
    return json(text).dns.rules;
}

function contains(values, value) {
    if (type(values) != "array")
        values = [ values ];
    return index(values, value) >= 0;
}

function has_source(rule, source) {
    return type(rule) == "object" && contains(rule.source_ip_cidr, source);
}

function find_index(rules, predicate) {
    for (let i = 0; i < length(rules); i++)
        if (predicate(rules[i]))
            return i;
    return -1;
}

function uses_legacy_address_filter(rule) {
    if (rule.type == "logical") {
        for (let sub in rule.rules)
            if (uses_legacy_address_filter(sub))
                return true;
        return false;
    }
    return (rule.ip_cidr != null || rule.ip_is_private != null || rule.ip_accept_any != null) &&
        rule.match_response !== true;
}

function assert_legacy(name) {
    let rules = dns_rules(name);
    for (let source in [ "192.168.1.50", "192.168.1.60/32" ]) {
        let probe = find_index(rules, r => r.type == "logical" && r.action == "route" &&
            r.server == "dnsmasq-server" && has_source(r.rules[0], source) &&
            r.rules[1].invert === true && contains(r.rules[1].ip_cidr, "198.18.0.0/15") &&
            r.rules[1].match_response == null);
        let fallback = find_index(rules, r => r.server == "dns-server" && has_source(r, source) &&
            contains(r.query_type, "A"));
        assert(probe >= 0, name + ": legacy dnsmasq probe for " + source);
        assert(fallback > probe, name + ": real DNS fallback follows legacy probe for " + source);
    }
    assert(find_index(rules, r => r.action == "evaluate" || r.action == "respond") < 0,
        name + ": pre-1.14 config must not use evaluate/respond");
}

function assert_response_match(name) {
    let rules = dns_rules(name);
    for (let source in [ "192.168.1.50", "192.168.1.60/32" ]) {
        let evaluate = find_index(rules, r => r.action == "evaluate" &&
            r.server == "dnsmasq-server" && has_source(r, source) && contains(r.inbound, "source-dns-in"));
        let respond = find_index(rules, r => r.type == "logical" && r.action == "respond" &&
            r.server == null && has_source(r.rules[0], source) &&
            r.rules[1].match_response === true && r.rules[1].invert === true &&
            contains(r.rules[1].ip_cidr, "198.18.0.0/15") && contains(r.rules[1].ip_cidr, "fc00::/18"));
        let fallback = find_index(rules, r => r.server == "dns-server" && has_source(r, source) &&
            contains(r.query_type, "A"));
        assert(evaluate >= 0, name + ": dnsmasq evaluate rule for " + source);
        assert(respond == evaluate + 1, name + ": respond rule directly follows evaluate for " + source);
        assert(fallback > respond, name + ": real DNS fallback follows respond for " + source);
    }
    for (let rule in rules)
        assert(!uses_legacy_address_filter(rule), name + ": sing-box 1.14 rejects address filters without match_response");
}

assert_legacy("sb113.json");
assert_legacy("unknown.json");
assert_response_match("sb114.json");
UCODE

ucode "$WORK_DIR/assert.uc" "$WORK_DIR"

printf 'sing-box 1.14 DNS response match checks passed\n'
