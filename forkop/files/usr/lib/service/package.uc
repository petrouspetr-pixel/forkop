#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let constants = require("core.constants");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("FORKOP_CONFIG_NAME", "forkop");
const RT_TABLES_PATH = env("FORKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("FORKOP_BIN", "/usr/bin/forkop");
const INIT_PATH = env("FORKOP_INIT", "/etc/init.d/forkop");
const DNS_APPLY_UC = env("FORKOP_DNS_APPLY_UC", "/usr/lib/forkop/dns/apply.uc");
const SING_BOX_INIT = env("FORKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("FORKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("FORKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Forkop managed sing-box service for binary variants");
const PACKAGE_UPGRADE_STATE = env("FORKOP_PACKAGE_UPGRADE_STATE", "/tmp/forkop-package-was-running");
const PACKAGE_TEST_MODE = env("FORKOP_PACKAGE_TEST_MODE", "") != "";
const FIREWALL_CONFIG = env("FORKOP_FIREWALL_CONFIG", "firewall");
const FIREWALL_INCLUDE_SECTION = env("FORKOP_FIREWALL_INCLUDE_SECTION", "forkop_tproxy_input");
const FIREWALL_INCLUDE_FILE = env("FORKOP_FIREWALL_INCLUDE_FILE", "/etc/forkop-input.nft");
const FIREWALL_INIT = env("FORKOP_FIREWALL_INIT", "/etc/init.d/firewall");
const NFT_FAKEIP_MARK = env("NFT_FAKEIP_MARK", constants.NFT_FAKEIP_MARK || "0x04000000");

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function valid_nft_mark(value) {
    value = trim(as_string(value));
    return match(value, /^(0x[0-9a-fA-F]+|[0-9]+)$/) != null;
}

function tproxy_firewall_rule_text() {
    if (!valid_nft_mark(NFT_FAKEIP_MARK))
        return "";

    return "meta l4proto { tcp, udp } meta mark & " + NFT_FAKEIP_MARK +
        " == " + NFT_FAKEIP_MARK +
        " accept comment \"!forkop: Allow TPROXY-marked input\"\n";
}

function write_file_if_changed(path, content) {
    let existing = fs.readfile(as_string(path));
    if (existing != null && as_string(existing) == as_string(content))
        return 0;
    return fs.writefile(as_string(path), as_string(content)) != null ? 1 : -1;
}

function firewall_include_path() {
    return FIREWALL_CONFIG + "." + FIREWALL_INCLUDE_SECTION;
}

function ensure_firewall_include_option(option_name, value) {
    let path = firewall_include_path() + "." + option_name;
    if (uci_core.get(path) == as_string(value))
        return 0;
    return uci_core.set(path, value) ? 1 : -1;
}

function reload_firewall() {
    if (PACKAGE_TEST_MODE || !path_exists(FIREWALL_INIT))
        return true;
    return command_success_from_args([ FIREWALL_INIT, "reload" ]);
}

function ensure_tproxy_firewall_include() {
    let rule = tproxy_firewall_rule_text();
    if (rule == "" || !uci_core.available())
        return false;

    let changed = false;
    let write_result = write_file_if_changed(FIREWALL_INCLUDE_FILE, rule);
    if (write_result < 0)
        return false;
    if (write_result > 0)
        changed = true;

    let section_path = firewall_include_path();
    let section = uci_core.get_all(FIREWALL_CONFIG, FIREWALL_INCLUDE_SECTION);
    if (type(section) != "object" || as_string(section[".type"] || "") != "include") {
        if (!uci_core.set_section(section_path, "include"))
            return false;
        changed = true;
    }

    for (let item in [
        [ "type", "nftables" ],
        [ "path", FIREWALL_INCLUDE_FILE ],
        [ "position", "chain-pre" ],
        [ "chain", "input" ]
    ]) {
        let result = ensure_firewall_include_option(item[0], item[1]);
        if (result < 0)
            return false;
        if (result > 0)
            changed = true;
    }

    if (!changed)
        return true;
    if (!uci_core.commit(FIREWALL_CONFIG))
        return false;
    return reload_firewall();
}

function remove_tproxy_firewall_include() {
    let changed = false;
    let section = uci_core.get_all(FIREWALL_CONFIG, FIREWALL_INCLUDE_SECTION);

    if (type(section) == "object" &&
        as_string(section[".type"] || "") == "include" &&
        as_string(section.path || "") == FIREWALL_INCLUDE_FILE) {
        if (!uci_core.delete(firewall_include_path()))
            return false;
        changed = true;
    }

    if (path_exists(FIREWALL_INCLUDE_FILE)) {
        unlink_if_exists(FIREWALL_INCLUDE_FILE);
        changed = true;
    }

    if (!changed)
        return true;
    if (uci_core.available() && !uci_core.commit(FIREWALL_CONFIG))
        return false;
    return reload_firewall();
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 forkop") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function remember_upgrade_state(action) {
    if (as_string(action) != "upgrade") {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }

    if (command_success_from_args([ INIT_PATH, "status" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        command_success_from_args([ INIT_PATH, "stop" ]);
        restore_dnsmasq_if_needed();
        remove_managed_sing_box();
    }

    let firewall_ok = true;
    if (as_string(action) != "upgrade")
        firewall_ok = remove_tproxy_firewall_include();

    return remove_rt_tables_entry() && firewall_ok;
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    if (!ensure_tproxy_firewall_include())
        return false;

    if (!path_exists(PACKAGE_UPGRADE_STATE))
        return true;

    if (!command_success_from_args([ INIT_PATH, "start" ]))
        return false;

    unlink_if_exists(PACKAGE_UPGRADE_STATE);
    return true;
}

function luci_cache_globs() {
    let configured = env("FORKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "forkop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "ensure-tproxy-firewall")
    exit(ensure_tproxy_firewall_include() ? 0 : 1);
else if (mode == "remove-tproxy-firewall")
    exit(remove_tproxy_firewall_include() ? 0 : 1);
else if (mode == "tproxy-firewall-rule")
    print(tproxy_firewall_rule_text());
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|ensure-tproxy-firewall|remove-tproxy-firewall|tproxy-firewall-rule|luci-postinst>\n");
    exit(1);
}
