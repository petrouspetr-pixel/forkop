#!/usr/bin/env ucode

// Provenance is supplied by the generator, never inferred from a tag or link.
// Only subscription objects can be removed; user and service objects are roots.
function array_value(value) {
    return type(value) == "array" ? value : [];
}

function object_value(value) {
    return type(value) == "object" ? value : {};
}

function add_reference(pending, value) {
    if (type(value) == "string" && value != "")
        push(pending, value);
}

function collect_references(value, pending) {
    if (type(value) == "array") {
        for (let item in value) {
            collect_references(item, pending);
        }
        return;
    }
    if (type(value) != "object")
        return;

    for (let key in keys(value)) {
        if (key == "outbounds") {
            for (let tag in array_value(value[key])) {
                add_reference(pending, tag);
            }
        }
        else if (key == "outbound" || key == "detour" || key == "download_detour" || key == "default") {
            add_reference(pending, value[key]);
        }
        else {
            collect_references(value[key], pending);
        }
    }
}

function prune_config(config, subscription_tags) {
    subscription_tags = object_value(subscription_tags);
    let indexed = {};
    let pending = [];
    for (let outbound in array_value(config.outbounds)) {
        indexed[outbound.tag] = outbound;
        if (!subscription_tags[outbound.tag])
            add_reference(pending, outbound.tag);
    }

    // Includes nested route rules, DNS transports, endpoints and remote rule sets.
    // Subscription groups must not become roots merely by existing in outbounds.
    for (let key in keys(config)) {
        if (key != "outbounds")
            collect_references(config[key], pending);
    }
    add_reference(pending, object_value(config.route).final);

    let visited = {};
    for (let i = 0; i < length(pending); i++) {
        let tag = pending[i];
        if (visited[tag])
            continue;
        visited[tag] = true;
        if (indexed[tag])
            collect_references(indexed[tag], pending);
    }

    let removed = {};
    let retained = [];
    for (let outbound in array_value(config.outbounds)) {
        if (subscription_tags[outbound.tag] && !visited[outbound.tag])
            removed[outbound.tag] = true;
        else
            push(retained, outbound);
    }
    config.outbounds = retained;
    return removed;
}

function retained_map(value, removed) {
    let result = {};
    value = object_value(value);
    for (let tag in keys(value)) {
        if (!removed[tag])
            result[tag] = value[tag];
    }
    return result;
}

function retained_tags(value, removed) {
    let result = [];
    for (let tag in array_value(value)) {
        if (!removed[tag])
            push(result, tag);
    }
    return result;
}

function prune_state(state, removed) {
    removed = object_value(removed);
    state.links = retained_map(state.links, removed);
    state.servers = retained_map(state.servers, removed);
    state.outboundMetadata = object_value(state.outboundMetadata);
    for (let field in keys(state.outboundMetadata)) {
        state.outboundMetadata[field] = retained_map(state.outboundMetadata[field], removed);
    }
    state.urltestCandidateTags = retained_tags(state.urltestCandidateTags, removed);
    for (let field in [ "urltestGroups", "priorityGroups" ]) {
        state[field] = retained_map(state[field], removed);
        for (let tag in keys(state[field])) {
            let group = state[field][tag];
            group.outbounds = retained_tags(group.outbounds, removed);
            for (let level in array_value(group.levels)) {
                level.outbounds = retained_tags(level.outbounds, removed);
            }
        }
    }
}

return { prune_config, prune_state };
