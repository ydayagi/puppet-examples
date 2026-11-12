# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case2` — that provisions and manages a Redis cluster node. The module is version 3.1.0, authored by the Platform Team, and targets Red Hat Enterprise Linux 8/9 and Ubuntu 22.04/24.04.

The migration scope is moderate in size (one module, two manifests, one template) but carries **above-average complexity** due to four non-trivial Puppet extension points that have no direct Ansible equivalents:

1. A **PuppetDB live query** used for dynamic cluster node discovery.
2. A **custom Puppet function** (`myFunction1`) that performs an HTTP health-check call at catalog compile time.
3. A **proprietary internal secret-store function** (`mySecretFunction1`) backed by `company_internal_lib`.
4. A **custom Puppet type/provider pair** (`mySecretType1` / `mySecretProvider1`) that registers nodes in an internal Enterprise Scheduler platform via the `schedulerctl` CLI.

Each of these four items requires a deliberate design decision before Ansible playbook authoring can begin. The Redis installation and configuration work itself is straightforward.

**Estimated timeline**: 3–5 sprints (6–10 weeks) for a single engineer, accounting for the integration design work on the four non-trivial items above, testing on both OS families, and documentation.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case2**
  - **Description**: Redis cluster node profile that installs and configures a Redis server (v11 `puppet-redis` wrapper), manages persistence (AOF + RDB snapshots), enforces memory limits and eviction policy, performs a compile-time HTTP health check against a local application endpoint, fetches a service token from a proprietary internal secret store, deploys a versioned application artifact from an internal artifact repository, and registers the node in a proprietary Enterprise Scheduler platform.
  - **Path**: `.` (module root — `manifests/`, `templates/`, `lib/`)
  - **Technology**: Puppet (≥ 7.0.0 < 9.0.0)
  - **Key Features**:
    - Dynamic cluster node discovery via `puppetdb_query()` (live PuppetDB API call)
    - Redis installation and service management delegated to the `puppet-redis` Forge module (bind `0.0.0.0`, configurable port/password/maxmemory)
    - Templated `redis.conf.erb` with AOF persistence (`appendfsync everysec`), RDB snapshots, and memory policy
    - Custom Facter fact `redis_role` (primary vs. replica) derived from presence of `replicaof` in `/etc/redis/conf.d/replica.conf`
    - Custom function `myFunction1` — synchronous HTTP GET at catalog compile time, returns parsed JSON health payload written to `/var/lib/redis/health_check.json`
    - Custom function `mySecretFunction1` — retrieves a named credential (`redis_service_token`) from `CompanyInternal::SecretStore` via `company_internal_lib`
    - Custom type/provider `myDeploy1` — downloads a versioned tarball from an internal artifact URL, extracts it to `/opt/myapp`, and tracks the installed version via `version.txt`
    - Custom type/provider `mySecretType1` — registers/unregisters the node in an Enterprise Scheduler platform using the proprietary `/usr/local/bin/schedulerctl` CLI

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be replaced by Ansible Galaxy `requirements.yml` or equivalent role dependencies.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, dependency version ranges). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency constraints for the migration.
- `manifests/init.pp`: Main class entry point — declares all parameters (port, password, maxmemory, policy), orchestrates PuppetDB query, health check, secret fetch, artifact deploy, and scheduler registration, then contains `profile_redis_cluster_case2::install`.
- `manifests/install.pp`: Subclass that invokes the `puppet-redis` class with all tuning parameters and ensures the `/var/log/redis` directory exists.
- `templates/redis.conf.erb`: ERB template for `redis.conf`; interpolates FQDN, port, password, maxmemory, and maxmemory-policy. Direct equivalent is an Ansible Jinja2 template.
- `lib/facter/redis_role.rb`: Custom Facter fact that detects primary vs. replica role by inspecting `/etc/redis/conf.d/replica.conf`. Must be replaced by an Ansible fact or `set_fact` task.
- `lib/puppet/functions/myFunction1.rb`: Compile-time HTTP GET function. Must be replaced by an Ansible `uri` module task.
- `lib/puppet/functions/mySecretFunction1.rb`: Proprietary secret-store lookup via `company_internal_lib`. Must be replaced by an Ansible Vault lookup or a supported secrets-manager integration (HashiCorp Vault, AWS Secrets Manager, etc.).
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom resource type for versioned artifact deployment. Must be replaced by Ansible tasks using `get_url`, `unarchive`, and `copy`/`stat` for version tracking.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom resource type for Enterprise Scheduler registration via `schedulerctl`. Must be replaced by Ansible tasks using the `command` module (or a custom Ansible module if idempotency is required).

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary); Ubuntu 22.04 and 24.04 (secondary). Explicitly declared in `metadata.json` `operatingsystem_support`. Package management differs between families (`yum`/`dnf` vs. `apt`) — the `puppetlabs-apt 9.4.0` dependency in the Puppetfile confirms apt handling is currently abstracted away; Ansible roles must handle both families explicitly.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified in the repository. The internal artifact URL (`http://artifacts.internal/`) and internal health-check endpoint (`http://localhost:8080/health`) suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Abstracts Redis package installation, service management, and configuration. Replace with the community Ansible role `geerlingguy.redis` (Ansible Galaxy) or equivalent, supplemented by the Jinja2-templated `redis.conf` already present in this repo.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu. Replace with the Ansible `apt_repository` module or the `geerlingguy.repo-*` roles for Ubuntu targets.
- **company_internal_lib (internal, version unknown)**: Ruby gem backing `mySecretFunction1`. There is no Ansible equivalent — the secrets integration must be re-implemented using a supported Ansible secrets backend (see Security Considerations).
- **schedulerctl CLI (/usr/local/bin/schedulerctl, proprietary)**: Used by `mySecretType1` provider. The CLI itself is not replaced; Ansible will invoke it via the `command` or `shell` module. Idempotency logic (query-before-register) must be re-implemented explicitly in the playbook.
- **PuppetDB (live query API)**: Used for dynamic cluster node discovery. Replace with Ansible dynamic inventory (a custom inventory plugin or script querying the same or an equivalent CMDB/service-discovery endpoint).

---

### Security Considerations

- **Hardcoded default password**: `init.pp` declares `String $redis_password = 'CHANGEME'` as a class parameter default. This plaintext default must never be used in production. In Ansible, this variable must be sourced exclusively from Ansible Vault or an external secrets manager — it must not appear in any unencrypted variable file.
- **Proprietary secret store (`mySecretFunction1` / `company_internal_lib`)**: The `redis_service_token` credential is fetched at Puppet catalog compile time from an internal secret store. The migration team must identify the backing secret store (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.) and implement the corresponding Ansible lookup plugin (`community.hashi_vault.hashi_vault`, `azure_keyvault`, etc.) before any playbook can be considered production-ready.
- **Redis `requirepass` in template**: The `redis.conf.erb` template writes the Redis password in plaintext into the configuration file on disk. The Ansible equivalent Jinja2 template carries the same risk — ensure the rendered file has mode `0600` and is owned by the `redis` user, and that the source variable is always Vault-encrypted.
- **Artifact download over plain HTTP**: `myDeploy1` fetches the application tarball from `http://artifacts.internal/myapp-2.1.0.tar.gz` (unencrypted HTTP). The Ansible `get_url` replacement should enforce HTTPS and, ideally, validate a checksum (`checksum` parameter) to prevent tampering.
- **Health-check endpoint over plain HTTP**: `myFunction1` calls `http://localhost:8080/health` over plain HTTP. If this endpoint is ever exposed beyond localhost, it should be migrated to HTTPS.
- **`schedulerctl` CLI trust**: The `mySecretType1` provider invokes an internal binary at a fixed path with no integrity verification. The Ansible replacement should document the expected binary version and, if possible, verify a checksum or signature before execution.

---

### Technical Challenges

- **PuppetDB node discovery → Ansible dynamic inventory**: The `puppetdb_query()` call in `init.pp` discovers all cluster members at catalog compile time. Ansible has no compile-time equivalent. This must be replaced with a dynamic inventory source (custom plugin, Ansible Tower/AWX smart inventory, or a pre-play task that queries a CMDB). This is the highest-risk architectural gap and should be resolved in the design phase before any code is written.
- **Compile-time HTTP health check (`myFunction1`)**: Puppet evaluates this function during catalog compilation, before any resources are applied. In Ansible, the `uri` module runs as a task in sequence. The migration team must decide whether the health check is a pre-condition gate (use `uri` + `fail` in a pre-task block) or a data-collection step (use `uri` + `set_fact`), and handle failure modes explicitly.
- **Proprietary secret-store integration (`mySecretFunction1`)**: The `company_internal_lib` Ruby gem is Puppet-specific. The Ansible replacement depends entirely on what backend the gem wraps — this must be investigated with the Platform/Security team before migration begins. If the backend is not natively supported by an Ansible lookup plugin, a custom lookup plugin will need to be developed.
- **Custom type/provider idempotency (`myDeploy1`)**: The Puppet provider implements `exists?`/`create`/`destroy` for idempotent artifact deployment. The Ansible equivalent using `get_url` + `unarchive` + `stat` is straightforward but must replicate the version-file check logic carefully to avoid re-deploying on every run.
- **Enterprise Scheduler registration (`mySecretType1` / `schedulerctl`)**: The Puppet provider wraps `schedulerctl` with idempotent `exists?` (query), `create` (register), and `destroy` (unregister) semantics. Ansible's `command` module is not inherently idempotent — the replacement tasks must explicitly call `schedulerctl query` first and conditionally call `schedulerctl register`, or use `changed_when`/`failed_when` guards. If `schedulerctl` exit codes are not reliable, a custom Ansible module may be warranted.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact (primary/replica) is available to all Puppet resources on the node. In Ansible, this must be replaced with a `set_fact` task or a custom fact script deployed via `ansible.builtin.setup`/`ansible.builtin.script`, and any conditional logic that consumes it must be updated accordingly.
- **Dual OS-family support**: The module targets both RHEL (dnf/yum) and Ubuntu (apt). Ansible roles must use `ansible_os_family` conditionals or separate task files for package installation and service management. The `puppetlabs-apt` dependency signals that APT source management is non-trivial on Ubuntu and must be explicitly handled.
- **`puppet-redis` abstraction gap**: The `puppet-redis` Forge module abstracts a large surface area (package, service, config, user, directories). The Ansible replacement role must be audited to confirm it covers the same parameters — particularly `bind`, `requirepass`, `maxmemory`, `appendonly`, and `appendfsync` — before it can be considered a drop-in replacement.

---

### Migration Order

1. **Redis installation and configuration** (low risk, high value): Migrate `manifests/install.pp` and `templates/redis.conf.erb` first. This is a well-understood Redis setup with a direct Ansible role equivalent (`geerlingguy.redis` or similar) and a straightforward Jinja2 template conversion. Validates the dual-OS approach early.
2. **Custom Facter fact → Ansible fact** (low risk): Convert `lib/facter/redis_role.rb` to a `set_fact` task or a deployed custom fact script. No external dependencies; confirms the primary/replica detection logic works in the Ansible execution model.
3. **HTTP health check → `uri` task** (low-to-medium risk): Replace `myFunction1` with an Ansible `uri` module task. Requires a decision on pre-task gate vs. data-collection pattern, but has no proprietary dependencies.
4. **Artifact deployment → `get_url` + `unarchive`** (medium risk): Replace the `myDeploy1` custom type/provider with Ansible tasks. Requires careful replication of the version-file idempotency check and resolution of the HTTP→HTTPS artifact URL issue.
5. **Secret store integration** (high risk, blocking): Replace `mySecretFunction1` and the `redis_password` default. This is a hard blocker for production readiness — must be completed in parallel with or immediately after step 1. Requires coordination with the Platform/Security team to identify the backing secret store and implement the correct Ansible lookup plugin or Vault integration.
6. **Enterprise Scheduler registration → `schedulerctl` tasks** (high risk): Replace `mySecretType1`/`mySecretProvider1` with Ansible tasks wrapping `schedulerctl`. Requires investigation of CLI exit codes and idempotency guarantees; may require a custom Ansible module.
7. **PuppetDB node discovery → dynamic inventory** (highest architectural risk): Replace the `puppetdb_query()` call with an Ansible dynamic inventory source. This is an architectural decision that affects how the entire playbook is invoked and should be designed early, even if implemented last.

---

### Assumptions

1. The `company_internal_lib` Ruby gem wraps a secrets backend that is accessible from Ansible (e.g., HashiCorp Vault, CyberArk, AWS Secrets Manager). If the backend is entirely proprietary with no API, a custom Ansible lookup plugin will need to be developed from scratch.
2. The `/usr/local/bin/schedulerctl` binary will be pre-installed on target nodes before the Ansible playbook runs, as it is today with Puppet. The migration plan does not cover deploying `schedulerctl` itself.
3. The `puppetdb_query()` result is used only for cluster awareness (e.g., knowing peer node FQDNs). If it is used to drive Redis replication configuration (e.g., setting `replicaof`), additional tasks will be needed in the Ansible role to configure replication topology — this is not currently visible in the manifests reviewed.
4. The internal artifact server at `http://artifacts.internal/` will remain available during and after migration. The migration plan assumes the URL scheme can be upgraded to HTTPS without changing the artifact path.
5. The health-check endpoint at `http://localhost:8080/health` is a sidecar application running on the same host as Redis. Its availability is assumed to be a pre-condition for the health-check task.
6. The `redis_password` parameter is currently supplied via Hiera (or an equivalent ENC) in production — the `'CHANGEME'` default in `init.pp` is never used in live environments. If this assumption is wrong, a secrets audit is required before migration begins.
7. The `puppetlabs-apt` dependency is used solely for APT source management on Ubuntu targets. No custom APT pinning or signed repository keys beyond what `geerlingguy.redis` or `ansible.builtin.apt_repository` handles are assumed to be required.
8. Puppet's `contain` semantics (used for `profile_redis_cluster_case2::install`) enforce ordering and scoping. The Ansible equivalent is task ordering within a role or playbook — no special `include_role` scoping is assumed to be necessary.
9. The `redis_role` Facter fact (primary vs. replica) is consumed only within this module. If other modules or node classifiers depend on it, those consumers are out of scope for this migration plan.
10. Target nodes run a supported systemd-based OS. Redis service management via `ansible.builtin.service` (systemd) is assumed to be valid for all targets.
