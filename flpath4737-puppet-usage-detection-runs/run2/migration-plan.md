# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. The module provisions a Redis node that participates in a cluster, performing: Redis installation and configuration, application artifact deployment, health-check polling, secret retrieval via a proprietary internal secret store, cron-based backup scheduling, proprietary config-file management, and registration with an Enterprise Scheduler platform.

The migration scope is **one Puppet module** with **four custom Puppet types/providers** and **two custom Puppet functions**, all of which have no direct Ansible equivalents and must be re-implemented as Ansible tasks, modules, or roles. The proprietary integrations (`company_internal_lib` secret store, `schedulerctl` CLI, and the `!key=value` CompanyApp config format) represent the highest-risk items and require early coordination with the Platform/Security teams.

**Estimated timeline**: 3–5 weeks for a single engineer, accounting for proprietary integration discovery, testing, and sign-off.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree and via `read_file` are listed below.

---

- **profile_redis_cluster_case3**
  - **Description**: Redis cluster node profile (v3.1.0) that installs and configures a Redis server via the `puppet-redis` Forge module, deploys an internal application artifact (`myapp` v2.1.0) from an internal artifact repository, polls a local HTTP health-check endpoint and writes the result to disk, retrieves a service token from a proprietary internal secret store (`company_internal_lib`), manages entries in a proprietary `!key=value` CompanyApp settings file (`/etc/company/app.conf`), registers the node with a proprietary Enterprise Scheduler platform via the `schedulerctl` CLI, and schedules a nightly Redis backup cron job. Node discovery for cluster membership is performed via a live PuppetDB query.
  - **Path**: `.` (repository root — the module is the repository itself)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis installation with `puppet-redis` (bind `0.0.0.0`, port 6379, `requirepass`, AOF persistence, RDB snapshots, `maxmemory` / `maxmemory-policy`)
    - `redis.conf.erb` template rendered with FQDN, port, password, memory settings
    - Custom Facter fact `redis_role` — detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf`
    - PuppetDB node discovery (`puppetdb_query`) to enumerate all cluster members
    - Custom function `myFunction1` — HTTP GET to a health endpoint, returns parsed JSON
    - Custom function `mySecretFunction1` — fetches a named credential from `CompanyInternal::SecretStore` (requires `company_internal_lib` Ruby gem)
    - Custom type/provider `myDeploy1` — downloads a versioned `.tar.gz` artifact from an internal URL, extracts it, and tracks the installed version via `version.txt`
    - Custom type/provider `myFormatType1` — idempotently manages `!key=value` lines in the proprietary CompanyApp settings file
    - Custom type/provider `mySecretType1` — registers/unregisters the node with the Enterprise Scheduler via `/usr/local/bin/schedulerctl`
    - Custom type/provider `myCronType1` — manages root crontab entries via `crontab -l` / `crontab -`
    - Hardcoded default Redis password (`CHANGEME`) in class parameters

---

### Infrastructure Files

- `Puppetfile`: Declares Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be translated into Ansible Galaxy / collection requirements.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraints). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency version ranges.
- `manifests/init.pp`: Main class — orchestrates all resources, holds class parameters (port, password, memory), and drives PuppetDB-based node discovery.
- `manifests/install.pp`: Sub-class — delegates to `puppet-redis` class and ensures `/var/log/redis` directory exists.
- `templates/redis.conf.erb`: ERB template for `redis.conf`; parameterised on FQDN, port, password, memory. Must be converted to a Jinja2 template.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica`. Must be replaced with an Ansible fact or task that reads `/etc/redis/conf.d/replica.conf`.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper returning parsed JSON. Replace with Ansible `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval via `CompanyInternal::SecretStore` (proprietary Ruby gem). Must be replaced with Ansible Vault, HashiCorp Vault lookup, or equivalent secret-manager integration.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron manager (root crontab). Replace with Ansible `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Artifact downloader/extractor with version tracking. Replace with Ansible `get_url` + `unarchive` + `copy`/`template` for `version.txt`.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` config-file manager. No built-in Ansible module handles this format; requires a custom Ansible module or `lineinfile`/`replace` tasks with regex.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration via `schedulerctl` CLI. Replace with Ansible `command`/`shell` tasks wrapping `schedulerctl`, or a custom module.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9; Ubuntu 22.04 and 24.04 (explicitly declared in `metadata.json` `operatingsystem_support`). Package management differs between families — the `puppetlabs-apt` dependency confirms Debian/Ubuntu handling is required alongside RHEL/YUM.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The artifact URL (`http://artifacts.internal/…`) and health endpoint (`http://localhost:8080/health`) suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides `stdlib::to_json`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the `community.general` or `geerlingguy.redis` Ansible role, or implement directly using `ansible.builtin.package`, `ansible.builtin.template`, and `ansible.builtin.service`.
- **puppetlabs-apt (9.4.0)**: Manages APT repositories on Ubuntu/Debian. Replace with `ansible.builtin.apt_repository` and `ansible.builtin.apt_key` tasks, gated by `when: ansible_os_family == 'Debian'`.
- **company_internal_lib (Ruby gem — version unknown)**: Proprietary secret-store client used by `mySecretFunction1`. This gem and its API are not open-source. The Ansible replacement strategy depends entirely on what backend `CompanyInternal::SecretStore` wraps (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.). **Must be clarified with the Platform/Security team before migration begins.**
- **schedulerctl CLI (/usr/local/bin/schedulerctl — version unknown)**: Proprietary Enterprise Scheduler CLI used by `mySecretType1`. The Ansible replacement is an `ansible.builtin.command` task, but the idempotency logic (query before register/unregister) must be re-implemented explicitly. CLI availability on target nodes must be confirmed.
- **PuppetDB**: Used for live cluster-node discovery (`puppetdb_query`). Ansible has no native equivalent. Replace with a dynamic inventory plugin, a static group variable listing cluster members, or a custom lookup plugin that queries PuppetDB's REST API directly.

---

### Security Considerations

- **Hardcoded default Redis password**: `manifests/init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default. In Ansible, this must be stored in Ansible Vault or an external secrets manager — never in a plain variable default or inventory file.
- **Redis password in `redis.conf.erb`**: The `requirepass` directive is rendered directly from `@redis_password`. The Jinja2 equivalent must source the value from a vaulted variable.
- **`mySecretFunction1` / `company_internal_lib`**: Retrieves a `redis_service_token` credential from a proprietary secret store at catalog-compile time. The Ansible equivalent must integrate with whatever secret backend this library wraps. The credential type is a service token (string). The integration path is unknown until the Platform/Security team documents the backend.
- **Internal artifact URL (HTTP, not HTTPS)**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/…` over plain HTTP. The Ansible `get_url` replacement should enforce HTTPS and checksum validation (`checksum` parameter) to prevent supply-chain attacks.
- **`mySecretType1` / Enterprise Scheduler registration**: Calls `schedulerctl register` with the node name and schedule. If `schedulerctl` communicates with an external platform using credentials, those credentials must be managed via Ansible Vault.
- **File permissions**: `/var/lib/redis/health_check.json` is owned `redis:redis` mode `0644`; `/var/log/redis` is mode `0755`. These must be preserved in Ansible `file` tasks.
- **`redis_role` Facter fact**: Reads `/etc/redis/conf.d/replica.conf` to determine node role. This file may contain replication credentials (`masterauth`). Ensure the Ansible fact-gathering equivalent does not log sensitive file contents.

---

### Technical Challenges

- **PuppetDB cluster-node discovery**: `puppetdb_query` is called at catalog-compile time to enumerate all nodes running this profile. Ansible has no compile-time equivalent. This must be replaced with a dynamic inventory source (e.g., a PuppetDB dynamic inventory plugin, a custom script, or a static group) before the role can replicate cluster-aware behaviour. **This is the highest architectural gap.**
- **Proprietary `!key=value` config format (`myFormatType1`)**: The CompanyApp settings file uses a non-standard `!key=value` line format. No Ansible built-in module handles this. Options: (a) a custom Ansible module in Python, (b) `ansible.builtin.lineinfile` with a carefully crafted regex, or (c) a full `ansible.builtin.template`-managed file if all keys are known. Option (a) is the most robust for idempotency.
- **Proprietary secret store (`company_internal_lib`)**: The Ruby gem's backend is unknown. Migration is blocked until the Platform/Security team identifies the underlying secret manager and provides an Ansible-compatible lookup plugin or integration path.
- **`schedulerctl` CLI idempotency**: The Puppet provider implements `exists?` (query), `create` (register), and `destroy` (unregister) as separate operations. Ansible `command`/`shell` tasks are not inherently idempotent. The migration must implement a check-before-act pattern (e.g., `register` the result of a query task and conditionally run register/unregister) or wrap the logic in a custom Ansible module.
- **Custom artifact deployment (`myDeploy1`)**: The provider tracks installed version via `version.txt`. The Ansible replacement must replicate this idempotency check (`stat` + `slurp`/`command` to read `version.txt`, skip download/extract if version matches). Additionally, the source URL uses HTTP — this should be upgraded to HTTPS with checksum verification.
- **Cross-platform package management**: The module targets both RHEL (yum/dnf) and Ubuntu (apt). Ansible tasks must use `ansible.builtin.package` for generic installs or include `when: ansible_os_family` conditionals for platform-specific steps (e.g., APT repository setup via `puppetlabs-apt`).
- **ERB → Jinja2 template conversion**: `redis.conf.erb` uses `<%= @facts['networking']['fqdn'] %>` and class-scoped variables. These must be mapped to Ansible facts (`ansible_fqdn`) and role variables. The conversion is straightforward but must be validated against the full Redis configuration to ensure no directives are dropped.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact is available to all Puppet resources on the node. In Ansible, this must be implemented as a `set_fact` task (reading `/etc/redis/conf.d/replica.conf`) early in the play, before any task that depends on the node's role.

---

### Migration Order

1. **Redis installation and configuration** (`manifests/install.pp` + `templates/redis.conf.erb`): Lowest risk, well-supported by existing Ansible roles (`geerlingguy.redis` or `community.general`). Establishes the foundation and validates the cross-platform (RHEL/Ubuntu) task structure. Delivers immediate value.
2. **`redis_role` fact and log directory** (`lib/facter/redis_role.rb`, `/var/log/redis`): Simple `set_fact` task and `file` module task. No external dependencies. Unblocks any downstream tasks that branch on node role.
3. **Cron backup job** (`myCronType1` / `myCronProvider1`): Direct replacement with `ansible.builtin.cron`. Self-contained, no external dependencies.
4. **Health-check polling and JSON file** (`myFunction1`, `file` resource): Replace with `ansible.builtin.uri` + `ansible.builtin.copy`. Straightforward, no proprietary dependencies.
5. **Artifact deployment** (`myDeploy1` / `myDeployProvider`): Replace with `get_url` + `unarchive` + idempotency check via `stat`/`slurp`. Requires upgrading the artifact URL to HTTPS and adding checksum validation. Moderate complexity.
6. **CompanyApp config management** (`myFormatType1` / `myFormatProvider1`): Requires a custom Ansible module or carefully crafted `lineinfile` tasks. Implement and unit-test the custom module before integrating into the role.
7. **Enterprise Scheduler registration** (`mySecretType1` / `mySecretProvider1`): Depends on `schedulerctl` being present on target nodes. Implement as idempotent `command` tasks with a query-before-act pattern. Requires coordination with the team that owns the Enterprise Scheduler platform.
8. **Secret retrieval** (`mySecretFunction1` / `company_internal_lib`): Blocked on Platform/Security team identifying the secret-store backend. Implement last, once the Ansible Vault or external lookup integration path is confirmed. This is the migration's critical dependency.
9. **Cluster-node discovery** (PuppetDB `puppetdb_query`): Implement a dynamic inventory plugin or static group to replace PuppetDB queries. This is an infrastructure-level change that affects how the playbook is invoked, not just a task-level replacement. Coordinate with the team that owns the inventory strategy.

---

### Assumptions

1. **Secret store backend unknown**: `mySecretFunction1` depends on `company_internal_lib`, a proprietary Ruby gem. The underlying secret backend (HashiCorp Vault, CyberArk, AWS Secrets Manager, or other) is not documented in this repository. The migration plan assumes an Ansible-compatible lookup plugin or Vault integration exists or can be built — this must be confirmed before migration begins.
2. **`schedulerctl` will remain available**: It is assumed that `/usr/local/bin/schedulerctl` will be present on target nodes during and after migration. If the Enterprise Scheduler platform is also being migrated or decommissioned, the `mySecretType1` replacement strategy must be revisited.
3. **Internal artifact repository is accessible from Ansible control node**: The `myDeploy1` provider downloads from `http://artifacts.internal/…`. It is assumed this URL is reachable from wherever Ansible runs (control node or target node, depending on whether `get_url` fetches to the control node or directly on the target).
4. **PuppetDB will remain available during transition**: The cluster-node discovery mechanism relies on PuppetDB. It is assumed PuppetDB remains operational long enough to inform the design of the Ansible dynamic inventory replacement.
5. **`myapp` version `2.1.0` is the current pinned version**: The artifact URL and version are hardcoded in `init.pp`. It is assumed this is intentional and that version management will be handled via Ansible role variables going forward.
6. **`/etc/redis/conf.d/replica.conf` is the authoritative replica indicator**: The `redis_role` fact assumes this file's existence and content determine node role. It is assumed this convention is stable and will not change during migration.
7. **The `!key=value` CompanyApp config format is stable**: The `myFormatType1` provider manages a proprietary file format. It is assumed the format specification will not change during migration, and that all keys managed by this module are known (currently `app-mode` and `health-port`).
8. **Cross-platform support is required**: `metadata.json` lists RHEL 8/9 and Ubuntu 22.04/24.04. It is assumed all four OS variants are actively used in production and must be supported by the Ansible role.
9. **No Hiera data layer**: This repository contains no `data/` directory or `hiera.yaml`. It is assumed all configuration is passed via class parameters or hardcoded defaults, and that no external Hiera hierarchy needs to be translated into Ansible group/host variables.
10. **The `redis_service_token` credential type and rotation policy are unknown**: Only the credential name is visible in the source. The Ansible replacement must handle the same credential, but its format, TTL, and rotation mechanism are undocumented here.
11. **`puppetlabs-apt` is only needed on Ubuntu/Debian targets**: The `apt` module is listed as a dependency but is not explicitly invoked in the manifests reviewed. It is assumed it is pulled in transitively by `puppet-redis` for Debian-family nodes and that the Ansible equivalent (`apt_repository`) will be similarly gated.
