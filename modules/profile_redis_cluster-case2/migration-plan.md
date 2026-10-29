# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version 3.1.0, authored by the Platform Team, and targets Red Hat Enterprise Linux 8/9 and Ubuntu 22.04/24.04.

The migration scope is moderate in size but carries **above-average complexity** due to three non-standard extension points that have no direct Ansible equivalents:

1. A **custom Puppet function** (`myFunction1`) that performs an HTTP health-check call at catalog compile time.
2. A **proprietary secret-store function** (`mySecretFunction1`) backed by an internal Ruby library (`company_internal_lib`) that fetches credentials at compile time.
3. A **custom Puppet type/provider pair** (`mySecretType1` / `mySecretProvider1`) that registers nodes in a proprietary Enterprise Scheduler platform via a CLI tool (`schedulerctl`).
4. A **custom Puppet type/provider pair** (`myDeploy1` / `myDeployProvider`) that downloads and installs a versioned application artifact.

The core Redis configuration work is straightforward to migrate; the blockers are the proprietary integrations above. Assuming the proprietary tooling questions are resolved in parallel, a realistic end-to-end migration timeline is **3–5 weeks** for a single engineer, or **2–3 weeks** with two engineers working in parallel.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**
  - **Description**: Redis cluster node profile that installs and configures a Redis server via the `puppet-redis` Forge module. Manages the Redis package, service, and `redis.conf` (bind address, port, password, AOF persistence, RDB snapshots, memory policy). Performs PuppetDB-based cluster node discovery, runs an HTTP health-check against a local sidecar endpoint, deploys a versioned application artifact (`myapp 2.1.0`) from an internal artifact server, retrieves a service token from a proprietary secret store, and registers the node in a proprietary Enterprise Scheduler platform.
  - **Path**: `.` (repository root — the module itself is the repository)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis 6/7 installation and configuration via `puppet-redis` (bind `0.0.0.0`, configurable port/password/maxmemory)
    - AOF persistence (`appendonly yes`, `appendfsync everysec`) and RDB snapshots
    - `allkeys-lru` eviction policy (configurable via Hiera/parameter)
    - PuppetDB live node discovery (`puppetdb_query`) to enumerate cluster peers
    - Custom HTTP health-check function (`myFunction1`) writing JSON result to `/var/lib/redis/health_check.json`
    - Proprietary secret retrieval (`mySecretFunction1` → `company_internal_lib::SecretStore`)
    - Versioned artifact deployment (`myDeploy1` custom type, downloads tarball from internal artifact server, tracks version via `version.txt`)
    - Enterprise Scheduler registration (`mySecretType1` custom type, wraps `schedulerctl` CLI)
    - Custom Facter fact (`redis_role`) that detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf`
    - ERB template (`redis.conf.erb`) embedding FQDN, port, password, maxmemory, and eviction policy

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be replaced by Ansible Galaxy `requirements.yml`.
- `metadata.json`: Module metadata (name, version, author, OS support matrix, dependency version ranges). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and Puppet version requirement (>= 7, < 9). No direct Ansible equivalent; information should be captured in the role's `README.md` and `meta/main.yml`.
- `templates/redis.conf.erb`: ERB template for `redis.conf`. Must be converted to a Jinja2 template (`.j2`). Variable references (`@redis_port`, `@redis_password`, `@maxmemory_mb`, `@maxmemory_policy`, `@facts['networking']['fqdn']`) map directly to Ansible variables and the `ansible_fqdn` magic variable.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica` by checking for `replicaof` in `/etc/redis/conf.d/replica.conf`. Must be replaced by an Ansible task using `stat` + `lineinfile`/`slurp` to set a host variable or fact (`set_fact`).
- `lib/puppet/functions/myFunction1.rb`: Custom Puppet function performing an HTTP GET and returning parsed JSON. Must be replaced by an Ansible `uri` module task.
- `lib/puppet/functions/mySecretFunction1.rb`: Custom Puppet function fetching secrets from `company_internal_lib::SecretStore`. Must be replaced by an Ansible lookup plugin (e.g., `community.hashi_vault.hashi_vault`, a custom lookup, or environment-variable injection depending on the backing store).
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom type/provider that downloads a versioned tarball and extracts it. Must be replaced by Ansible `get_url` + `unarchive` tasks with a version-file idempotency check.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom type/provider that registers/unregisters nodes in a proprietary Enterprise Scheduler via `schedulerctl`. Must be replaced by an Ansible `command`/`shell` task (or a custom module) wrapping `schedulerctl`.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary targets per `metadata.json`); Ubuntu 22.04 and 24.04 also supported. Package management differs between families — the `puppetlabs-apt` dependency confirms Debian/Ubuntu support is active. Ansible tasks must branch on `ansible_os_family` where package names or paths differ.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The internal artifact URL (`http://artifacts.internal/`) and internal secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with direct Ansible tasks: `package` (install `redis` / `redis-server`), `template` (deploy `redis.conf.j2`), and `service` (enable + start `redis`). Alternatively, adopt the `geerlingguy.redis` Ansible Galaxy role as a drop-in equivalent.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu. Replace with the `ansible.builtin.apt_repository` module or the `geerlingguy.repo-epel` / distro-specific tasks.
- **company_internal_lib (Ruby gem, internal)**: Backing library for `mySecretFunction1`. The Ansible replacement depends entirely on what secret backend this library wraps (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.). This must be clarified with the Platform Team before migration begins — it is the single highest-risk dependency.
- **schedulerctl CLI (/usr/local/bin/schedulerctl)**: Proprietary Enterprise Scheduler CLI. Ansible will invoke it via `command` or `shell` tasks. Idempotency must be implemented manually (query before register/unregister). A custom Ansible module is recommended if the CLI is used across multiple roles.
- **PuppetDB (puppetdb_query)**: Used for live cluster node discovery. Ansible has no built-in equivalent. Replace with a dynamic inventory script/plugin, a static group in the inventory, or a custom lookup against a CMDB/service-discovery endpoint.

---

### Security Considerations

- **Hardcoded default password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp`. This value is also rendered directly into `redis.conf.erb` as `requirepass`. In Ansible, this parameter must be sourced from Ansible Vault or an external secrets backend — never stored in plaintext in a variable file or role default.
- **Proprietary secret store (`mySecretFunction1`)**: Fetches `redis_service_token` at Puppet catalog compile time via `company_internal_lib::SecretStore`. The Ansible equivalent lookup plugin must be identified and tested before migration. The token itself must never appear in Ansible logs (`no_log: true` on the retrieving task).
- **Artifact download over plain HTTP**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (unencrypted). The Ansible `get_url` task should enforce `https://` and validate a checksum (`checksum` parameter) to prevent tampering.
- **Redis password in template**: The ERB template writes `requirepass <%= @redis_password %>` in cleartext to `/etc/redis/redis.conf`. The Jinja2 replacement must ensure the file has mode `0640`, owner `redis`, group `redis`, and that the Ansible task uses `no_log: true` when the variable is referenced in debug output.
- **`redis_role` fact exposure**: The custom Facter fact exposes node topology (primary/replica) as a system fact visible to all Puppet agents. In Ansible, this should be a scoped host variable rather than a globally broadcast fact.

---

### Technical Challenges

- **PuppetDB cluster discovery → Ansible dynamic inventory**: `puppetdb_query` is called at catalog compile time to enumerate all nodes running this profile. Ansible has no equivalent compile-time query. This must be replaced by a dynamic inventory plugin (e.g., querying a CMDB, Consul, or a static group) before the role can manage multi-node cluster topology. This is the most architecturally significant change in the migration.
- **Compile-time HTTP health check**: `myFunction1` is called during Puppet catalog compilation, meaning the health-check result influences resource ordering before any changes are applied. In Ansible, `uri` tasks run at execution time in playbook order — the semantics differ. The team must decide whether the health check should be a pre-task gate (fail-fast) or a post-task verification step.
- **Proprietary `schedulerctl` idempotency**: The Puppet provider implements `exists?`/`create`/`destroy` with idempotent semantics. A raw `command` task in Ansible is not idempotent by default. The migration must implement a query step (`schedulerctl query`) and use `when` conditions or a custom module to replicate idempotent behavior.
- **Custom type/provider for artifact deployment**: `myDeploy1` tracks installed version via `version.txt`. The Ansible replacement (`get_url` + `unarchive`) must replicate this version-check logic explicitly, e.g., using `stat` + `slurp` on `version.txt` and a `when` condition to skip download if the version already matches.
- **Cross-platform package naming**: Redis is packaged as `redis` on RHEL and `redis-server` on Ubuntu/Debian. The Ansible role must use `ansible_os_family` or a `vars/` file per OS family to map the correct package name, mirroring what `puppet-redis` handled transparently.
- **ERB → Jinja2 template conversion**: The `redis.conf.erb` template is straightforward, but the `@facts['networking']['fqdn']` reference must become `{{ ansible_fqdn }}`. All `@variable` references become `{{ variable }}`. The conversion is low-risk but must be validated against a running Redis instance.
- **Facter custom fact → Ansible fact**: `redis_role.rb` runs on every agent. The Ansible equivalent (`set_fact` after a `stat`/`slurp` task) must be placed early in the play so downstream tasks can consume it, replicating the fact's availability throughout the run.

---

### Migration Order

1. **Redis base configuration** (low risk, high value): Migrate `profile_redis_cluster_case2::install` first — package installation, `redis.conf.j2` template, log directory, and service management. This is pure infrastructure with no proprietary dependencies and can be validated immediately on both RHEL and Ubuntu.
2. **Custom Facter fact → Ansible fact task** (low risk): Replace `lib/facter/redis_role.rb` with a `set_fact` task. No external dependencies; validates the primary/replica detection logic early.
3. **ERB template conversion** (low risk): Convert `templates/redis.conf.erb` to `templates/redis.conf.j2` and wire it into the base configuration task. Validate rendered output against a known-good `redis.conf`.
4. **HTTP health check (`myFunction1`)** (medium risk): Replace with an Ansible `uri` task. Decide on pre-task vs. post-task placement. Requires the local health-check sidecar (`http://localhost:8080/health`) to be running in the test environment.
5. **Artifact deployment (`myDeploy1`)** (medium risk): Replace with `get_url` + `unarchive` + version-file idempotency logic. Requires access to the internal artifact server and agreement on HTTPS enforcement and checksum validation.
6. **Secret retrieval (`mySecretFunction1`)** (high risk — blocker): Identify the backing secret store behind `company_internal_lib::SecretStore`, select the appropriate Ansible lookup plugin, and validate credential retrieval. This must be resolved before the role can be used in production. All tasks consuming the secret must set `no_log: true`.
7. **Enterprise Scheduler registration (`mySecretType1`)** (high risk): Replace with idempotent `command` tasks wrapping `schedulerctl`. Requires `schedulerctl` to be present on the Ansible control node or target hosts, and requires the Enterprise Scheduler team to document the CLI's query/register/unregister interface.
8. **PuppetDB cluster discovery → dynamic inventory** (high risk — architectural): Replace `puppetdb_query` with a dynamic inventory solution. This is the last step because it requires agreement on the inventory source of truth and may affect how the entire playbook is structured.

---

### Assumptions

1. **Secret store backend is unknown**: `mySecretFunction1` depends on `company_internal_lib::SecretStore`, which is an internal Ruby library not present in this repository. The actual secret backend (Vault, CyberArk, AWS Secrets Manager, etc.) is unknown and must be confirmed with the Platform Team before a lookup plugin can be selected.
2. **`schedulerctl` availability**: It is assumed that `/usr/local/bin/schedulerctl` will be present on target hosts during Ansible runs, as it is today during Puppet agent runs. If it is only installed by a separate Puppet module, that dependency must be made explicit in the Ansible playbook ordering.
3. **Internal artifact server accessibility**: The artifact URL `http://artifacts.internal/myapp-2.1.0.tar.gz` is assumed to remain reachable from Ansible-managed hosts. The migration plan assumes this URL will be upgraded to HTTPS.
4. **Health-check sidecar is pre-existing**: `myFunction1` calls `http://localhost:8080/health`, implying a sidecar or application process is already running on port 8080. It is assumed this process is managed by a separate module/role and will be present before the Redis role executes.
5. **PuppetDB replacement strategy is TBD**: No dynamic inventory source has been identified to replace `puppetdb_query`. It is assumed the team will decide between static inventory groups, a CMDB query, or a service-discovery lookup (Consul, etc.) as part of this migration.
6. **Single-module repository**: The repository tree contains exactly one Puppet module (the root is the module). There are no nested modules, roles, or profiles beyond `profile_redis_cluster_case2`.
7. **No Hiera data in this repository**: No `data/` directory or `hiera.yaml` was found. It is assumed Hiera data (e.g., per-environment passwords, memory limits) lives in a separate control repository and will need to be migrated to Ansible group/host vars or an external vars source.
8. **OS family branching is required**: Both RHEL and Ubuntu are listed as supported. The Ansible role must handle package name differences (`redis` vs. `redis-server`) and potentially service name differences. It is assumed both OS families will be tested during migration.
9. **Puppet `contain` semantics**: `contain profile_redis_cluster_case2::install` is used to prevent class resource ordering from leaking. In Ansible, task ordering is explicit and sequential, so this concern does not apply — but the migration team should verify no external module depends on ordering anchors provided by `contain`.
10. **`myapp` artifact version is static**: The `myDeploy1` resource hardcodes version `2.1.0` and a specific artifact URL. It is assumed this will be parameterized in the Ansible role (e.g., via a `myapp_version` variable) rather than remaining hardcoded.
