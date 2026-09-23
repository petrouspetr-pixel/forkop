#!/usr/bin/env ucode
let fs = require("fs");
let ip = require("core.ip");
let rule = require("config.rule");
const GITHUB_RAW_URL = getenv("GITHUB_RAW_URL") || "https://raw.githubusercontent.com/itdoginfo/allow-domains/main";
const BUILTIN_SUBNET_URLS = {
    twitter: [ getenv("SUBNETS_TWITTER") || GITHUB_RAW_URL + "/Subnets/IPv4/twitter.lst", getenv("SUBNETS_TWITTER6") || GITHUB_RAW_URL + "/Subnets/IPv6/twitter.lst" ],
    meta: [ getenv("SUBNETS_META") || GITHUB_RAW_URL + "/Subnets/IPv4/meta.lst", getenv("SUBNETS_META6") || GITHUB_RAW_URL + "/Subnets/IPv6/meta.lst" ],
    discord: [ getenv("SUBNETS_DISCORD") || GITHUB_RAW_URL + "/Subnets/IPv4/discord.lst", getenv("SUBNETS_DISCORD6") || GITHUB_RAW_URL + "/Subnets/IPv6/discord.lst" ],
    roblox: [ getenv("SUBNETS_ROBLOX") || GITHUB_RAW_URL + "/Subnets/IPv4/roblox.lst" ],
    telegram: [ getenv("SUBNETS_TELERAM") || GITHUB_RAW_URL + "/Subnets/IPv4/telegram.lst", getenv("SUBNETS_TELERAM6") || GITHUB_RAW_URL + "/Subnets/IPv6/telegram.lst" ],
    cloudflare: [ getenv("SUBNETS_CLOUDFLARE") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudflare.lst", getenv("SUBNETS_CLOUDFLARE6") || GITHUB_RAW_URL + "/Subnets/IPv6/cloudflare.lst" ],
    hetzner: [ getenv("SUBNETS_HETZNER") || GITHUB_RAW_URL + "/Subnets/IPv4/hetzner.lst", getenv("SUBNETS_HETZNER6") || GITHUB_RAW_URL + "/Subnets/IPv6/hetzner.lst" ],
    ovh: [ getenv("SUBNETS_OVH") || GITHUB_RAW_URL + "/Subnets/IPv4/ovh.lst", getenv("SUBNETS_OVH6") || GITHUB_RAW_URL + "/Subnets/IPv6/ovh.lst" ],
    digitalocean: [ getenv("SUBNETS_DIGITALOCEAN") || GITHUB_RAW_URL + "/Subnets/IPv4/digitalocean.lst", getenv("SUBNETS_DIGITALOCEAN6") || GITHUB_RAW_URL + "/Subnets/IPv6/digitalocean.lst" ],
    cloudfront: [ getenv("SUBNETS_CLOUDFRONT") || GITHUB_RAW_URL + "/Subnets/IPv4/cloudfront.lst", getenv("SUBNETS_CLOUDFRONT6") || GITHUB_RAW_URL + "/Subnets/IPv6/cloudfront.lst" ]
};

function entries(service, folder) {
    let result = [];
    let urls = BUILTIN_SUBNET_URLS[service];
    if (type(urls) != "array")
        return result;
    for (let i = 0; i < length(urls); i++) {
        let tag = "community-" + service + "-" + (i == 0 ? "ipv4" : "ipv6");
        push(result, { url: urls[i], tag, path: folder + "/" + tag + ".json", family: i == 0 ? 4 : 6 });
    }
    return result;
}

// Keep the last valid family on download/validation failure. Publish a complete
// source file atomically, before these same addresses are handed to nft.
function publish(entry, input_path, normalized_path) {
    let data = fs.readfile(input_path);
    if (data == null)
        return false;
    let values = [];
    let seen = {};
    for (let value in rule.text_list_values(data, "space")) {
        if (ip.ip_family(value) != entry.family)
            return false;
        if (!seen[value]) {
            seen[value] = true;
            push(values, value);
        }
    }
    if (length(values) == 0)
        return false;
    // nft list updates add elements rather than replacing sets. Keep matching
    // routes for previously intercepted addresses until the runtime is reset.
    let previous = fs.readfile(entry.path);
    if (previous != null) {
        try {
            let old = json(previous);
            for (let item in old.rules || []) {
                for (let value in item.ip_cidr || []) {
                    if (ip.ip_family(value) == entry.family && !seen[value]) {
                        seen[value] = true;
                        push(values, value);
                    }
                }
            }
        }
        catch (e) {
            return false;
        }
    }
    let staging = entry.path + ".new";
    let result = fs.writefile(staging, sprintf("%J\n", { version: 3, rules: [ { ip_cidr: values } ] }));
    if (result == null || result === false)
        return false;
    result = fs.writefile(normalized_path, join("\n", values) + "\n");
    if (result == null || result === false) {
        fs.unlink(staging);
        return false;
    }
    if (!fs.rename(staging, entry.path)) {
        fs.unlink(staging);
        return false;
    }
    return true;
}

return { entries, publish, urls: BUILTIN_SUBNET_URLS };
