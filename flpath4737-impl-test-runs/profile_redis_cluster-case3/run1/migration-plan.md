# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. The module provisions a Redis node that participates in a cluster, performing: Redis installation and configuration, application artifact deployment, health-check polling, cron-based backup scheduling, proprietary config-file management, and registration with an internal Enterprise Scheduler platform. Secret retrieval is handled through a proprietary internal Ruby library (`company_internal_lib`).

The migration scope is **one Puppet module** with **four custom types/providers**, **two custom functions**, and **one custom Facter fact**, all of which must be re-implemented as native Ansible constructs. The primary complexity drivers are:

- Replacing PuppetDB-based node discovery with Ansible inventory/group mechanics.
- Replacing the proprietary `mySecretFunction1` / `company_internal_lib` secret store with a supported secrets backend (e.g., HashiCorp Vault, Ansible Vault, or a cloud secrets manager).
- Replacing the proprietary `schedulerctl` Enterprise Scheduler CLI integration with an equivalent Ansible task or module.
- Replacing the custom `myFormatType1` INI-like config-file format (`!key=value`) with an Ansible file-manipulation task.

**Estimated migration effort:** 2–4 weeks for a single engineer, including testing and documentation, given the moderate number of custom extensions and the proprietary integrations that require coordination with internal platform teams.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

- **profile_redis_cluster_case3**:
  - Description: Redis cluster node profile (v3.1.0) that installs and configures Redis via the `puppet-redis` Forge module, manages persistence (AOF + RDB snapshots), enforces memory limits and eviction policy, deploys an internal application artifact (`myapp` v2.1.0) from an internal artifact server, polls a local HTTP health-check endpoint, writes health-check results as JSON, manages a daily cron job for Redis backups, writes proprietary `!key=value` entries to `/etc/company/app.conf`, and registers the node with an internal Enterprise Scheduler platform on a daily schedule. Node discovery for cluster membership is performed via a live PuppetDB query.
  - Path: `manifests/init.pp`, `manifests/install.pp`
  - Technology: Puppet
  - Key Features:
    - Redis installation bound to `0.0.0.0`, port 6379, password-protected, AOF persistence (`appendfsync everysec`), RDB snapshots, configurable `maxmemory` and `maxmemory-policy`
    - Cluster node discovery via `puppetdb_query()` (live PuppetDB API call at catalog compile time)
    - HTTP health-check polling via custom function `myFunction1` against `http://localhost:8080/health`; result written to `/var/lib/redis/health_check.json`
    - Application artifact deployment (`myapp` v2.1.0) from `http://artifacts.internal/` via custom type `myDeploy1`
    - Secret retrieval via custom function `mySecretFunction1` backed by `company_internal_lib::SecretStore`
    - Enterprise Scheduler registration via custom type `mySecretType1` / `schedulerctl` CLI
    - Proprietary config-file management (`!key=value` format) via custom type `myFormatType1`
    - Cron job management for `/usr/local/bin/redis-backup.sh` via custom type `myCronType1`
    - Custom Facter fact `redis_role` (detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf`)

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). These must be replaced with equivalent Ansible roles/collections.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraints, Forge dependencies). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency version requirements.
- `templates/redis.conf.erb`: ERB template for `/etc/redis/redis.conf`. Injects `fqdn`, `redis_port`, `redis_password`, `maxmemory_mb`, and `maxmemory_policy`. Must be converted to a Jinja2 template for Ansible.
- `lib/facter/redis_role.rb`: Custom Facter fact that determines node role (`primary`/`replica`) by checking for `replicaof` in `/etc/redis/conf.d/replica.conf`. Must be replaced with an Ansible `set_fact` task using `stat` + `slurp`/`shell`.
- `lib/puppet/functions/myFunction1.rb`: Custom Puppet function performing an HTTP GET and returning parsed JSON or raw body. Must be replaced with Ansible's `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Custom Puppet function fetching secrets from `company_internal_lib::SecretStore` by credential name. Must be replaced with an Ansible secrets lookup plugin (HashiCorp Vault, AWS Secrets Manager, etc.) — **requires coordination with the internal platform/security team**.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom type/provider managing root crontab entries via `crontab -l` / `crontab -`. Must be replaced with Ansible's built-in `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom type/provider that downloads a versioned tarball from an internal artifact URL, extracts it to an install directory, and tracks the installed version via `version.txt`. Must be replaced with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Custom type/provider managing `!key=value` entries in a proprietary CompanyApp settings file (`/etc/company/app.conf`). Must be replaced with Ansible `lineinfile` (with a regex matching `!key=`) or a custom Jinja2 template rendering the full file.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom type/provider that registers/unregisters nodes in an internal Enterprise Scheduler platform via the proprietary `/usr/local/bin/schedulerctl` CLI. Must be replaced with an Ansible `command`/`shell` task wrapping `schedulerctl`, or a custom Ansible module — **requires coordination with the Enterprise Scheduler platform team**.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9; Ubuntu 22.04 and 24.04 (explicitly declared in `metadata.json` `operatingsystem_support`). Package management differs between families (yum/dnf vs apt); the `puppetlabs-apt` Forge dependency confirms apt-family support is intentional.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified in the repository. The internal artifact URL (`http://artifacts.internal/`) and internal secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides `stdlib::to_json()` used in `init.pp`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community Ansible role [`geerlingguy.redis`](https://galaxy.ansible.com/geerlingguy/redis) or [`community.general`](https://docs.ansible.com/ansible/latest/collections/community/general/) tasks, or write a dedicated `redis` role using `package`, `template`, `file`, and `service` modules.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Debian/Ubuntu targets. Replace with Ansible's `ansible.builtin.apt_repository` module for Ubuntu targets; no equivalent needed for RHEL targets (use `ansible.builtin.yum_repository` or `ansible.builtin.dnf`).
- **company_internal_lib (Ruby gem, internal)**: Backs `mySecretFunction1`. There is no public equivalent. The Ansible replacement must integrate with whatever secrets backend this library wraps (likely an internal Vault, CyberArk, or similar). **Requires platform/security team input before migration can begin.**
- **schedulerctl CLI (/usr/local/bin/schedulerctl, internal)**: Proprietary Enterprise Scheduler CLI. The Ansible replacement can wrap it with `ansible.builtin.command`, but the idempotency logic (query before register/unregister) must be re-implemented explicitly. A custom Ansible module is the cleaner long-term solution.
- **PuppetDB API**: Used for live cluster node discovery via `puppetdb_query()`. Ansible has no built-in equivalent. Replace with Ansible dynamic inventory (if nodes are already in an inventory source) or a pre-task that queries PuppetDB's REST API via the `uri` module and registers results as a fact/variable.

---

### Security Considerations

- **Hardcoded default password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp`. This value is also interpolated directly into `redis.conf.erb` as `requirepass`. In the Ansible role, this parameter must have **no default** (or a `fail` guard), and the value must be sourced exclusively from a secrets backend — never from a plaintext variable file or inventory.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` credential is fetched at catalog compile time from an internal secret store. The Ansible equivalent must use a lookup plugin (e.g., `community.hashi_vault.hashi_vault`, `amazon.aws.aws_secret`, or a custom lookup) so that the secret is never written to disk or logged. The credential name `redis_service_token` must be mapped to the new secrets backend path.
- **Redis password in config template**: `redis.conf.erb` writes `requirepass` in plaintext. The Ansible Jinja2 template equivalent must ensure the rendered file has mode `0600` and is owned by `redis:redis` to prevent world-readable credentials.
- **Internal artifact URL (HTTP, not HTTPS)**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` over plain HTTP. The Ansible `get_url` task should enforce `validate_certs: true` and the URL should be upgraded to HTTPS if the artifact server supports it. A checksum (`checksum` parameter in `get_url`) should be added to verify artifact integrity.
- **Redis bound to 0.0.0.0**: The Redis configuration binds to all interfaces. Confirm this is intentional for cluster communication and that network-level controls (firewall rules, security groups) restrict access appropriately. Consider binding to a specific cluster interface in the Ansible template.
- **Log directory permissions**: `/var/log/redis` is created with mode `0755`. Evaluate whether `0750` (redis:redis) is more appropriate to prevent other local users from reading Redis logs that may contain sensitive query data.

---

### Technical Challenges

- **PuppetDB node discovery → Ansible inventory**: `puppetdb_query()` performs a live query at catalog compile time to discover all nodes running this profile. Ansible has no direct equivalent. The migration must decide between: (a) static inventory groups, (b) a dynamic inventory plugin, or (c) a pre-task that queries PuppetDB's REST API. This is the highest-risk architectural change and must be resolved before the role can be considered feature-complete.
- **Custom type/provider idempotency re-implementation**: All four custom types (`myCronType1`, `myDeploy1`, `myFormatType1`, `mySecretType1`) implement their own `exists?`/`create`/`destroy` idempotency logic in Ruby. Each must be carefully re-implemented in Ansible tasks with equivalent idempotency guarantees — particularly `myDeploy1` (version-file tracking) and `mySecretType1` (schedulerctl query-before-register).
- **Proprietary `!key=value` config format (`myFormatType1`)**: The `/etc/company/app.conf` file uses a non-standard `!key=value` format. Ansible's `lineinfile` can manage individual entries with a carefully crafted `regexp`, but if the full file must be rendered consistently, a Jinja2 template is safer. The migration team must obtain the full expected structure of this file to avoid partial overwrites.
- **`company_internal_lib` Ruby dependency**: This internal gem is not available outside the Puppet agent runtime. The secrets integration must be fully re-architected for Ansible. This is a **blocking dependency** — the migration cannot be completed without knowing what backend the library wraps.
- **`schedulerctl` CLI availability**: The `schedulerctl` binary at `/usr/local/bin/schedulerctl` must be present on managed nodes for the Ansible equivalent task to function. Confirm whether it is pre-installed via another mechanism or whether the Ansible role must also manage its installation.
- **Cross-platform package management**: The module targets both RHEL (dnf/yum) and Ubuntu (apt). The Ansible role must use `ansible.builtin.package` for generic installs or include OS-family conditionals (`when: ansible_os_family == 'RedHat'`) for repository setup, mirroring the `puppetlabs-apt` dependency that currently handles the Ubuntu path.
- **ERB → Jinja2 template conversion**: `redis.conf.erb` uses `@facts['networking']['fqdn']` (Puppet facts). The Ansible equivalent is `ansible_fqdn`. All fact references must be audited and mapped to their Ansible equivalents during template conversion.
- **`redis_role` Facter fact**: The custom fact determines `primary` vs `replica` by inspecting a file at runtime. In Ansible, this must be implemented as a `set_fact` task (using `stat` + `slurp` or `shell`) early in the play, and the result used in subsequent conditional tasks.

---

### Migration Order

1. **Redis installation and configuration** (`manifests/install.pp` + `templates/redis.conf.erb`): Lowest risk, maps directly to `geerlingguy.redis` or a custom role using `package`/`template`/`service`. No proprietary dependencies. Delivers immediate value and validates the cross-platform (RHEL/Ubuntu) task structure.
2. **Cron job management** (`myCronType1`): Trivial replacement with `ansible.builtin.cron`. Implement and validate the `redis-backup` cron entry early to build confidence in the migration process.
3. **Health-check HTTP polling** (`myFunction1`): Straightforward replacement with `ansible.builtin.uri` + `copy`/`template` to write the JSON result to `/var/lib/redis/health_check.json`.
4. **`redis_role` fact** (`lib/facter/redis_role.rb`): Replace with a `set_fact` pre-task. Low complexity, but must be done before any task that branches on node role.
5. **Proprietary config-file management** (`myFormatType1`): Replace with `lineinfile` tasks for `app-mode` and `health-port` entries. Requires obtaining the full expected structure of `/etc/company/app.conf` from the application team.
6. **Application artifact deployment** (`myDeploy1`): Replace with `get_url` + `unarchive` + version-file tracking via `copy`. Upgrade artifact URL to HTTPS and add checksum verification. Requires access to the internal artifact server from Ansible control node/target.
7. **Node discovery** (PuppetDB `puppetdb_query()`): Resolve the inventory strategy (static group, dynamic inventory, or REST pre-task). This is an architectural decision that affects the entire play structure and should be finalized before the role is considered production-ready.
8. **Secret retrieval** (`mySecretFunction1` / `company_internal_lib`): Blocked on platform/security team input. Once the backend is identified, implement the appropriate Ansible lookup plugin and remove the `'CHANGEME'` default password entirely.
9. **Enterprise Scheduler registration** (`mySecretType1` / `schedulerctl`): Implement as an `ansible.builtin.command` task with idempotency guard (query before register). Consider promoting to a custom Ansible module if the scheduler is used across multiple roles.

---

### Assumptions

1. **`company_internal_lib` backend is unknown**: The Ruby gem name suggests an internal library. The actual secrets backend it wraps (Vault, CyberArk, AWS Secrets Manager, an internal API, etc.) is not documented in this repository. This must be clarified with the platform/security team before migration can be completed.
2. **`schedulerctl` is pre-installed**: It is assumed that `/usr/local/bin/schedulerctl` is already present on managed nodes via a separate provisioning mechanism not represented in this repository. If not, the Ansible role must also manage its installation.
3. **PuppetDB remains available during transition**: The migration plan assumes PuppetDB is still queryable during the transition period, allowing the team to validate that Ansible inventory groups match the PuppetDB-discovered node list before cutting over.
4. **Internal artifact server is reachable from Ansible targets**: `http://artifacts.internal/` must be accessible from managed nodes (or the Ansible control node, depending on delegation strategy) for the `get_url` task to function.
5. **`myapp` version pinning is intentional**: The artifact version `2.1.0` is hardcoded in `init.pp`. It is assumed this will be parameterized in the Ansible role (as a variable with a default), rather than remaining hardcoded.
6. **`/etc/company/app.conf` is exclusively managed by this module**: The `myFormatType1` provider rewrites the entire file. If other Puppet classes or external processes also write to this file, a `lineinfile`-based approach is safer than a full template render. This must be confirmed with the application team.
7. **Redis cluster topology is homogeneous**: All nodes managed by this profile are assumed to be either primary or replica, with role determined at runtime by the `redis_role` fact. It is assumed no node changes role without reprovisioning.
8. **No Hiera data files exist**: The repository contains no `data/` directory or `hiera.yaml`. All parameters are assumed to be passed directly at classification time or use the defaults in `init.pp`. If Hiera data exists at the environment level (outside this module), it must be located and mapped to Ansible group/host variables.
9. **The `redis_service_token` credential purpose is internal**: The token fetched by `mySecretFunction1('redis_service_token')` is stored in a file but its downstream consumer is not visible in this module. It is assumed it is consumed by `myapp` or another service on the node, not by Redis itself.
10. **OS-family-specific Redis repository setup is handled by `puppetlabs-apt`**: On Ubuntu targets, `puppetlabs-apt` likely adds the official Redis PPA or a company mirror. The equivalent `apt_repository` task parameters must be obtained from the environment-level Puppet code or the `puppet-redis` module's own data, which is outside this repository.
