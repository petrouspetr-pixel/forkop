#!/usr/bin/env ucode

// Keep migrations in this file. A migration is identified by a stable name;
// release checks are optional conditions inside the migration itself.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let core_url = require("core.url");
let subscription_share_link = require("subscription.share_link");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("TRAFIRA_CONFIG_NAME") || "trafira";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const TRAFIRA_RUNTIME_STATE_DIR = getenv("TRAFIRA_RUNTIME_STATE_DIR") || "/var/run/trafira";
const TRAFIRA_SUBSCRIPTION_LINKS_DIR = getenv("TRAFIRA_SUBSCRIPTION_LINKS_DIR") || TRAFIRA_RUNTIME_STATE_DIR + "/subscription-links";
const TRAFIRA_SUBSCRIPTION_METADATA_DIR = getenv("TRAFIRA_SUBSCRIPTION_METADATA_DIR") || TRAFIRA_RUNTIME_STATE_DIR + "/subscription-metadata";
const TRAFIRA_OUTBOUND_METADATA_DIR = getenv("TRAFIRA_OUTBOUND_METADATA_DIR") || TRAFIRA_RUNTIME_STATE_DIR + "/outbound-metadata";
const TRAFIRA_SECTION_CACHE_DIR = getenv("TRAFIRA_SECTION_CACHE_DIR") || TRAFIRA_RUNTIME_STATE_DIR + "/section-cache";
const TRAFIRA_RUNTIME_CACHE_FORMAT_FILE = getenv("TRAFIRA_RUNTIME_CACHE_FORMAT_FILE") || TRAFIRA_RUNTIME_STATE_DIR + "/cache-format";
const TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/trafira/subscription-cache";
const TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "7";
const TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD = getenv("TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/trafira.internal-config-change";
const TRAFIRA_RUNTIME_CACHE_FORMAT = getenv("TRAFIRA_RUNTIME_CACHE_FORMAT") || "8";
const CONFIG_VERSION_OPTION = "config_version";
const APPLIED_MIGRATIONS_OPTION = "applied_migrations";
const CHILD_ITEM_TYPES = [
    "subscription_url",
    "section_interface",
    "urltest"
];

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return replace(as_string(data), /[\r\n]+$/g, "");
}

function run(command) {
    return system(command) == 0;
}

function section_name(section) {
    return option(section, ".name", "");
}

function clone_section(section) {
    let result = {};
    for (let key in keys(object_or_empty(section)))
        result[key] = section[key];
    return result;
}

function fixture_section_list(data, type_name) {
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function model_from_fixture(path) {
    let data = object_or_empty(read_json_file(path));
    let model = {
        settings: clone_section(object_or_empty(data.settings)),
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    if (model.settings[".name"] == null)
        model.settings[".name"] = "settings";
    if (model.settings[".type"] == null)
        model.settings[".type"] = "settings";

    for (let section in fixture_section_list(data, "section"))
        push(model.sections, clone_section(section));
    for (let type_name in CHILD_ITEM_TYPES)
        for (let section in fixture_section_list(data, type_name))
            push(model[type_name], clone_section(section));

    return model;
}

function model_from_uci(cursor) {
    let model = {
        settings: clone_section(object_or_empty(cursor.get_all(CONFIG_NAME, "settings"))),
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    cursor.foreach(CONFIG_NAME, "section", function(section) {
        push(model.sections, clone_section(section));
    });
    for (let type_name in CHILD_ITEM_TYPES) {
        cursor.foreach(CONFIG_NAME, type_name, function(section) {
            push(model[type_name], clone_section(section));
        });
    }

    return model;
}

function export_model(model) {
    let result = {
        settings: model.settings,
        section: model.sections
    };
    for (let type_name in CHILD_ITEM_TYPES)
        if (length(model[type_name] || []) > 0)
            result[type_name] = model[type_name];
    return result;
}

function migration_context(model) {
    return {
        model,
        operations: [],
        changed: false
    };
}

function record_operation(ctx, op) {
    push(ctx.operations, op);
    ctx.changed = true;
}

function option_exists(section, key) {
    return object_or_empty(section)[key] != null;
}

function set_option(ctx, section, key, value) {
    value = as_string(value);
    if (option(section, key, "") == value && option_exists(section, key))
        return;

    section[key] = value;
    record_operation(ctx, { op: "set", section: section_name(section), option: key, value });
}

function set_option_if_missing(ctx, section, key, value) {
    if (option_exists(section, key))
        return;
    set_option(ctx, section, key, value);
}

function list_values_equal(left, right) {
    if (length(left) != length(right))
        return false;

    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;

    return true;
}

function set_list_option(ctx, section, key, values) {
    let normalized = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "")
            push(normalized, value);
    }

    let current = object_or_empty(section)[key];
    let current_values = [];
    if (type(current) == "array")
        current_values = current;
    else if (current != null && as_string(current) != "")
        current_values = [ as_string(current) ];

    if (option_exists(section, key) && list_values_equal(current_values, normalized))
        return;

    section[key] = normalized;
    record_operation(ctx, { op: "set_list", section: section_name(section), option: key, values: normalized });
}

function delete_option(ctx, section, key) {
    if (!option_exists(section, key))
        return;

    delete section[key];
    record_operation(ctx, { op: "delete", section: section_name(section), option: key });
}

function create_child_section(ctx, type_name) {
    ctx.child_index = int(ctx.child_index || 0) + 1;
    let item_id = "__" + type_name + "_" + ctx.child_index;
    let section = {
        ".name": item_id,
        ".type": type_name
    };
    if (ctx.model[type_name] == null)
        ctx.model[type_name] = [];
    push(ctx.model[type_name], section);
    record_operation(ctx, { op: "create", section: item_id, type: type_name, anonymous: true });
    return section;
}

function create_child_for_section(ctx, parent, type_name) {
    let child = create_child_section(ctx, type_name);
    set_option(ctx, child, "section", section_name(parent));
    return child;
}

function option_list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (value == null)
        return [];
    value = as_string(value);
    return value == "" ? [] : [ value ];
}


function migrate_interface_item_settings(ctx, section) {
    let owner = section_name(section);
    let resolver_enabled = bool_option(section, "domain_resolver_enabled", false) ? "1" : "0";
    let dns_type = option(section, "domain_resolver_dns_type", "udp") || "udp";
    let dns_server = option(section, "domain_resolver_dns_server", "8.8.8.8") || "8.8.8.8";
    let seen_values = {};

    for (let child in ctx.model.section_interface || []) {
        if (option(child, "section", "") != owner)
            continue;

        let value = option(child, "name", "");
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        set_option_if_missing(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option_if_missing(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option_if_missing(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    let values = option_list_values(section, "interfaces");
    let legacy_interface = option(section, "interface", "");
    if (legacy_interface != "")
        push(values, legacy_interface);

    for (let value in values) {
        value = as_string(value);
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        let child = create_child_for_section(ctx, section, "section_interface");
        set_option(ctx, child, "name", value);
        set_option(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    delete_option(ctx, section, "interface");
    delete_option(ctx, section, "interfaces");
    delete_option(ctx, section, "interface_settings");
    delete_option(ctx, section, "domain_resolver_enabled");
    delete_option(ctx, section, "domain_resolver_dns_type");
    delete_option(ctx, section, "domain_resolver_dns_server");
}

function version_parts(value) {
    let matched = match(as_string(value), /^([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (!matched)
        return [ 0, 0, 0 ];
    return [ int(matched[1]), int(matched[2]), int(matched[3]) ];
}

function compare_versions(left, right) {
    left = version_parts(left);
    right = version_parts(right);
    for (let i = 0; i < 3; i++) {
        if (left[i] < right[i])
            return -1;
        if (left[i] > right[i])
            return 1;
    }
    return 0;
}

function release_at_most(ctx, version) {
    return compare_versions(ctx.source_release, version) <= 0;
}

function migrate_interface_sections(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    for (let section in ctx.model.sections)
        migrate_interface_item_settings(ctx, section);
}

function migrate_enable_component_checks(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    set_option(ctx, ctx.model.settings, "component_update_check_enabled", "1");
}

function migration_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;

    value = int(value);
    return value >= 1 && value <= 65535 ? value : null;
}

function unique_migration_tag(base, taken) {
    base = trim(as_string(base));
    if (base == "")
        base = "http";
    if (!taken[base])
        return base;

    for (let suffix = 1; suffix < 100000; suffix++) {
        let candidate = base + "-" + suffix;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function migrated_http_outbound(link, tag_name) {
    link = core_url.strip_fragment(core_url.decode(link));
    let scheme = core_url.scheme(link);
    if (scheme != "http" && scheme != "https")
        return null;

    let host = core_url.host(link);
    let port = migration_port(core_url.port(link));
    let path = core_url.path(link);
    if (host == "" || port == null || (path != "" && path != "/") || index(link, "?") >= 0)
        return null;

    let outbound = {
        type: "http",
        tag: tag_name,
        server: host,
        server_port: port
    };
    let userinfo = core_url.userinfo(link);
    if (userinfo != "") {
        let colon = index(userinfo, ":");
        outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
        if (colon >= 0)
            outbound.password = substr(userinfo, colon + 1);
    }
    if (scheme == "https")
        outbound.tls = { enabled: true };
    return outbound;
}

function migrate_http_connection_urls(ctx) {
    if (!release_at_most(ctx, "1.0.4"))
        return;

    for (let section in ctx.model.sections) {
        let existing_jsons = option_list_values(section, "outbound_jsons");
        let taken = {};
        for (let value in existing_jsons) {
            try {
                let outbound = json(value);
                let tag_name = type(outbound) == "object" ? trim(as_string(outbound.tag || "")) : "";
                if (tag_name != "")
                    taken[tag_name] = true;
            }
            catch (e) {
            }
        }

        let remaining_links = [];
        let migrated_jsons = [];
        for (let link in option_list_values(section, "selector_proxy_links")) {
            let tag_name = unique_migration_tag(core_url.fragment(link), taken);
            let outbound = migrated_http_outbound(link, tag_name);
            if (outbound == null) {
                push(remaining_links, link);
                continue;
            }

            taken[tag_name] = true;
            push(migrated_jsons, sprintf("%J", outbound));
        }

        if (length(migrated_jsons) == 0)
            continue;

        if (length(remaining_links) > 0)
            set_list_option(ctx, section, "selector_proxy_links", remaining_links);
        else
            delete_option(ctx, section, "selector_proxy_links");

        for (let value in existing_jsons)
            push(migrated_jsons, value);
        set_list_option(ctx, section, "outbound_jsons", migrated_jsons);
    }
}

const MIGRATIONS = [
    { id: "interface_sections", run: migrate_interface_sections },
    { id: "enable_component_checks", run: migrate_enable_component_checks },
    { id: "http_connection_urls", run: migrate_http_connection_urls }
];

function apply_migrations(ctx) {
    ctx.source_release = option(ctx.model.settings, CONFIG_VERSION_OPTION, "");

    let applied = [];
    let seen = {};
    let added = false;
    for (let id in list_option(ctx.model.settings, APPLIED_MIGRATIONS_OPTION)) {
        id = as_string(id);
        if (id == "" || seen[id])
            continue;
        seen[id] = true;
        push(applied, id);
    }

    for (let migration in MIGRATIONS) {
        if (seen[migration.id])
            continue;

        migration.run(ctx);
        seen[migration.id] = true;
        push(applied, migration.id);
        added = true;
    }

    if (added)
        set_list_option(ctx, ctx.model.settings, APPLIED_MIGRATIONS_OPTION, applied);

    if (release_at_most(ctx, "1.0.4"))
        set_option(ctx, ctx.model.settings, CONFIG_VERSION_OPTION, "1.0.5");
}

function migrate_trafira_model(model) {
    let ctx = migration_context(model);
    apply_migrations(ctx);
    return ctx;
}

// Runtime UCI adapter and external command dispatcher.
function first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function ensure_dir(path) {
    run("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1");
}

function clear_subscription_runtime_cache() {
    run("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(TRAFIRA_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(TRAFIRA_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(TRAFIRA_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(TRAFIRA_SECTION_CACHE_DIR));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(TRAFIRA_RUNTIME_STATE_DIR);
    ensure_dir(TRAFIRA_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(TRAFIRA_OUTBOUND_METADATA_DIR);
    ensure_dir(TRAFIRA_SECTION_CACHE_DIR);
}

function ensure_runtime_cache_format() {
    ensure_dir(TRAFIRA_RUNTIME_STATE_DIR);

    if (first_line(TRAFIRA_RUNTIME_CACHE_FORMAT_FILE) != TRAFIRA_RUNTIME_CACHE_FORMAT) {
        if (first_line(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) == TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT)
            subscription_share_link.populate_subscription_dir(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        fs.writefile(TRAFIRA_RUNTIME_CACHE_FORMAT_FILE, TRAFIRA_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (first_line(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
        run("rm -rf " + shell_quote(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        run("chmod 700 " + shell_quote(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_DIR) + " >/dev/null 2>&1");
        fs.writefile(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT + "\n");
        run("chmod 600 " + shell_quote(TRAFIRA_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) + " >/dev/null 2>&1");
    }
}

function remove_legacy_server_country_cache() {
    fs.unlink(TRAFIRA_RUNTIME_STATE_DIR + "/server-country-cache.json");
}

function apply_operations(cursor, operations) {
    let created = {};
    let section_ref = function(name) {
        name = as_string(name);
        return as_string(created[name] || name);
    };

    for (let op in operations) {
        if (op.op == "create") {
            if (op.anonymous && type(cursor.add) == "function")
                created[as_string(op.section)] = cursor.add(CONFIG_NAME, op.type);
            else
                cursor.set(CONFIG_NAME, op.section, op.type);
        }
        else if (op.op == "set")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.value);
        else if (op.op == "delete")
            cursor.delete(CONFIG_NAME, section_ref(op.section), op.option);
        else if (op.op == "set_list")
            cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.values);
    }
}

function runtime_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        },
        add: function(package_name, type_name) {
            return uci_core.add(package_name, type_name);
        },
        set: function(package_name, section_name, option_name, value) {
            if (value == null)
                return uci_core.set_section(package_name + "." + section_name, option_name);
            return uci_core.set(package_name + "." + section_name + "." + option_name, value);
        },
        delete: function(package_name, section_name, option_name) {
            return uci_core.delete(package_name + "." + section_name + "." + option_name);
        },
        commit: function(package_name) {
            return uci_core.commit(package_name);
        }
    };
}

function current_config_hash() {
    let config_path = "/etc/config/" + CONFIG_NAME;
    if (fs.stat(config_path) == null)
        return "";

    let output = command_output("md5sum " + shell_quote(config_path) + " 2>/dev/null");
    let fields = split(trim(output), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function mark_internal_config_guard() {
    let hash = current_config_hash();
    if (hash == "") {
        fs.unlink(TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, TRAFIRA_INTERNAL_CONFIG_TRIGGER_GUARD))
        fs.unlink(tmp_path);
}

function commit_cursor(cursor) {
    if (!cursor.commit(CONFIG_NAME))
        return false;
    mark_internal_config_guard();
    return true;
}

function migrate_model(model) {
    return migrate_trafira_model(model);
}

function migrate_runtime() {
    ensure_runtime_cache_format();
    remove_legacy_server_country_cache();

    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    let ctx = migrate_model(model_from_uci(cursor));
    if (!ctx.changed)
        return true;

    apply_operations(cursor, ctx.operations);

    return commit_cursor(cursor);
}

function commit_runtime() {
    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    return commit_cursor(cursor);
}

function migrate_fixture(path) {
    let ctx = migrate_model(model_from_fixture(path));
    write_json({
        changed: ctx.changed,
        config: export_model(ctx.model),
        operations: ctx.operations
    });
}

function main(argv) {
    let mode = argv[0] || "";

    if (mode == "migrate")
        return migrate_runtime() ? 0 : 1;
    if (mode == "commit")
        return commit_runtime() ? 0 : 1;
    if (mode == "migrate-fixture") {
        migrate_fixture(argv[1]);
        return 0;
    }

    warn("Usage: config/migration.uc migrate\n");
    warn("       config/migration.uc commit\n");
    warn("       config/migration.uc migrate-fixture <fixture.json>\n");
    return 1;
}

function module_exports() {
    return {
        main: main,
        migrate_model: migrate_model,
        migrate_trafira_model: migrate_trafira_model,
        mark_internal_config_guard: mark_internal_config_guard
    };
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return module_exports();

exit(main(ARGV));
