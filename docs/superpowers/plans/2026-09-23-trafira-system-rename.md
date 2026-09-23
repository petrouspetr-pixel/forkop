# Trafira 2.0.0 system identity and release

User-approved scope: rename runtime packages/configuration to trafira, remove old releases after a successful new build, publish a new release, one-command installation and manual upgrade documentation, updates from petrouspetr-pixel/trafira.

1. Rename source layout, package metadata, installed paths, UCI/RPC IDs, init scripts, runtime directories, frontend symbols/locales, fixtures and CI paths consistently. Preserve upstream credit, canonical historical baseline and explicit legacy migration identifiers.
2. Add tested Forkop migration in installer: persistent backup before destructive steps, stop old service, install renamed packages, migrate saved config and required state, preserve rollback material and user files. Existing Podkop Plus compatibility remains explicit.
3. Review updater owner and asset matching, firmware package formats, conflicts/coexistence and cache cleanup. Compare generated configs against the unchanged upstream baseline after normalizing identity differences only.
4. Rebuild frontend; run backend compilation/tests, frontend lint/tests/reproducibility, shellcheck. Review and merge only green commit.
5. Build version 2.0.0 using GitHub Actions. Verify six renamed IPK/APK artifacts and release target. Publish release notes and installation/manual upgrade README. Remove only old releases 1.0.6/1.0.7/1.0.8 after new artifacts are available; retain git history/tags.
6. Verify latest release API, updater target, README instructions and clean repository. No router deployment is authorized by this task.
