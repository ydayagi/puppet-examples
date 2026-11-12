# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. It provisions a Redis node that participates in a cluster, performing PuppetDB-driven peer discovery, health-check polling, artifact deployment, cron scheduling, proprietary config-file management, and registration with an internal Enterprise Scheduler platform.

The migration scope is moderate in size but **high in complexity** due to four custom Puppet types/providers that wrap proprietary internal tooling (`company_internal_lib`, `schedulerctl`) and a custom secret-retrieval function. Each of these abstractions must be re-implemented in Ansible before the Redis provisioning logic itself can be migrated.

**Estimated timeline: 4–6 weeks** for a single experienced Ansible engineer, or 2–3 weeks with a two-person team, assuming internal tooling owners are available for consultation.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case3**:
  - Description: Redis cluster node profile (v3.1.0) that installs and configures a Redis server via the `puppet-redis` Forge module, performs PuppetDB-based cluster peer discovery, polls an internal HTTP health-check endpoint, deploys a versioned application artifact (`myapp` v2.1.0) from an internal artifact server, retrieves a service token from a proprietary secret store, registers the node with an Enterprise Scheduler platform on a daily schedule, manages two entries in a proprietary `!key=value` application config file (`/etc/company/app.conf`), and schedules a nightly Redis backup cron job.
  - Path: `manifests/` (root of repository — this repo *is* the module)
  - Technology: Puppet
  - Key Features:
    - Redis installation and configuration via `puppet-redis` (bind `0.0.0.0`, port 6379, `requirepass`, AOF persistence with `appendfsync everysec`, RDB snapshots, `maxmemory` + `allkeys-lru` eviction policy)
    - `redis.conf.erb` template rendering node FQDN, port, password, memory, and policy
    - Custom Facter fact `redis_role` — detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf` for a `replicaof` directive
    - PuppetDB query (`puppetdb_query`) for live cluster node discovery
    - Custom function `myFunction1` — HTTP GET to an internal health endpoint, returns parsed JSON
    - Custom function `mySecretFunction1` — fetches a named credential from `CompanyInternal::SecretStore` via `company_internal_lib` (proprietary Ruby gem)
    - Custom type/provider `myDeploy1` — downloads a versioned `.tar.gz` artifact over HTTP/HTTPS, extracts it, and tracks the installed version via `version.txt`
    - Custom type/provider `mySecretType1` — registers/unregisters the node in an Enterprise Scheduler platform via the `/usr/local/bin/schedulerctl` CLI
    - Custom type/provider `myFormatType1` — manages `!key=value` entries in `/etc/company/app.conf` (proprietary CompanyApp settings format)
    - Custom type/provider `myCronType1` — manages root crontab entries via `crontab -l` / `crontab -` shell commands; schedules `/usr/local/bin/redis-backup.sh` at 02:30 daily
    - `/var/log/redis` directory ownership and permissions management

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be replaced by Ansible Galaxy `requirements.yml` or equivalent role dependencies.
- `metadata.json`: Module metadata declaring OS support (RHEL 8/9, Ubuntu 22.04/24.04), Puppet version requirement (>= 7.0.0 < 9.0.0), and Forge dependencies. Informs target platform matrix for Ansible.
- `templates/redis.conf.erb`: ERB template for `/etc/redis/redis.conf`. Injects FQDN, port, password, maxmemory, and maxmemory-policy. Must be converted to a Jinja2 template (`redis.conf.j2`).
- `lib/facter/redis_role.rb`: Custom Facter fact detecting primary/replica role. Must be replaced by an Ansible task that reads `/etc/redis/conf.d/replica.conf` and sets a host fact (`set_fact`).
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper returning parsed JSON. Replace with Ansible `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval via `company_internal_lib`. Replace with Ansible Vault or a lookup plugin targeting the internal secret store.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron manager (root crontab). Replace with Ansible `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Artifact downloader/extractor with version tracking. Replace with Ansible `get_url` + `unarchive` + `copy` (for `version.txt`).
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` config-file manager. Replace with a custom Ansible module or `lineinfile`/`replace` tasks targeting the `!key=value` format.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration via `schedulerctl` CLI. Replace with Ansible `command` module tasks wrapping `schedulerctl register/unregister/query`, or a dedicated custom module.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9, Ubuntu 22.04 and 24.04 — explicitly declared in `metadata.json`. The Redis configuration and package management patterns (APT dependency via `puppetlabs-apt`) confirm a dual RHEL/Debian family target.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The artifact URL (`http://artifacts.internal/`) and health endpoint (`http://localhost:8080/health`) suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency required.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community Ansible role `geerlingguy.redis` (Galaxy) or equivalent, parameterised to match the existing bind/port/password/persistence/memory settings.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Debian/Ubuntu targets. Replace with the Ansible `apt_repository` module or the `geerlingguy.repo-*` roles for Ubuntu targets.
- **company_internal_lib (Ruby gem — proprietary)**: Used exclusively by `mySecretFunction1` to call `CompanyInternal::SecretStore.fetch()`. This gem and its API must be understood before a replacement lookup plugin or Ansible Vault integration can be designed. **Requires engagement with the internal tooling team.**
- **schedulerctl CLI (`/usr/local/bin/schedulerctl`)**: Proprietary binary used by `mySecretType1` provider. The `register`, `unregister`, and `query` subcommand signatures are known from the provider source; wrap these in an Ansible `command` task block or a lightweight custom module. Idempotency must be re-implemented (query before register/unregister).
- **PuppetDB**: Used for live cluster peer discovery (`puppetdb_query`). Ansible has no native equivalent. Replace with a dynamic inventory plugin, a custom `uri`-based lookup against the PuppetDB API, or — if PuppetDB is being decommissioned — an alternative service-discovery mechanism (e.g., Consul, AWS SSM inventory, or a static group variable).

---

### Security Considerations

- **Hardcoded Redis password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp` and is rendered directly into `redis.conf.erb` as `requirepass`. This credential must be migrated to Ansible Vault (`ansible-vault encrypt_string`) or a secrets-management backend (HashiCorp Vault, AWS Secrets Manager) before any playbook is run in production.
- **Proprietary secret store (`mySecretFunction1`)**: The `redis_service_token` credential is fetched at catalog-compile time via `CompanyInternal::SecretStore`. The equivalent Ansible lookup must preserve at-rest encryption and in-transit security. The token's purpose and rotation policy should be documented before migration.
- **Artifact download over plain HTTP**: `myDeploy1` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (no TLS). The Ansible replacement should use HTTPS and validate checksums (`get_url` with `checksum` parameter) to prevent supply-chain tampering.
- **Redis bound to `0.0.0.0`**: The module explicitly binds Redis on all interfaces. This should be reviewed during migration; if only cluster-internal traffic is required, binding to a specific interface or using firewall rules (`ansible.posix.firewalld` / `ufw`) is recommended.
- **`/var/log/redis` permissions**: Directory is set `0755` owned by `redis:redis`. Verify this is intentional and not overly permissive for the target environment's logging policy.
- **`schedulerctl` privilege**: The provider calls `schedulerctl` without explicit privilege escalation context. The Ansible equivalent task will need `become: true` or a dedicated service account depending on the binary's permission requirements.

---

### Technical Challenges

1. **Proprietary `company_internal_lib` Ruby gem**: The secret-store integration has no Ansible equivalent out of the box. The internal tooling team must provide either a REST API, a CLI wrapper, or documentation sufficient to write an Ansible lookup plugin. This is the highest-risk dependency and should be resolved first.

2. **PuppetDB cluster peer discovery**: `puppetdb_query` provides dynamic, real-time node discovery at catalog compile time. Ansible does not have a direct equivalent. The migration team must decide between: (a) a dynamic inventory script/plugin querying PuppetDB's REST API, (b) migrating to a different service-discovery tool, or (c) accepting static group-based inventory. This architectural decision affects the entire cluster topology and must be made before playbook design begins.

3. **Custom `myFormatType1` config-file format**: The `!key=value` format used by `/etc/company/app.conf` is proprietary. Ansible's `lineinfile` can handle it with carefully crafted regexes, but a custom Ansible module would be more robust and maintainable. The migration team should assess whether the CompanyApp configuration format is documented and stable.

4. **Idempotency re-implementation for all custom providers**: All four custom providers implement their own `exists?`/`create`/`destroy` idempotency logic. Each must be faithfully reproduced in Ansible tasks using `stat`, `command` with `changed_when`/`failed_when`, or dedicated modules. Missing idempotency will cause repeated re-runs to make unintended changes.

5. **Dual OS family support (RHEL + Ubuntu)**: The module targets both RPM-based and APT-based systems. Ansible tasks for package installation, service management, and repository configuration will need `when: ansible_os_family == 'RedHat'` / `'Debian'` conditionals or separate variable files per OS family.

6. **`redis_role` Facter fact replacement**: The primary/replica detection logic reads a file at runtime. In Ansible this becomes a `stat` + `slurp`/`command` task early in the play to set a host fact, which downstream tasks can then consume. The fact must be gathered before any Redis-role-conditional logic runs.

7. **`myDeploy1` version-tracking pattern**: The provider uses a `version.txt` sentinel file to determine whether a re-deploy is needed. This pattern is straightforward to replicate with `stat` + `slurp` in Ansible, but care must be taken to handle partial deployments (e.g., failed mid-extract) that leave a stale `version.txt`.

---

### Migration Order

The following order minimises risk by resolving infrastructure blockers before tackling application logic:

1. **Secrets integration** — Engage the internal tooling team to document or expose `CompanyInternal::SecretStore`. Implement an Ansible Vault strategy or lookup plugin for `redis_service_token` and `redis_password`. This unblocks all subsequent work.

2. **Cluster discovery strategy** — Decide on and implement the PuppetDB replacement (dynamic inventory plugin, Consul, or static groups). This decision shapes the overall playbook structure.

3. **OS-family variable scaffolding** — Create the Ansible role skeleton with `vars/RedHat.yml` and `vars/Debian.yml`, and confirm the target inventory covers both RHEL 8/9 and Ubuntu 22.04/24.04 hosts.

4. **Redis installation and configuration** — Migrate `manifests/install.pp` and `templates/redis.conf.erb` using `geerlingguy.redis` or equivalent, with a Jinja2 `redis.conf.j2` template. Validate Redis starts and accepts connections.

5. **`redis_role` fact** — Implement the primary/replica detection task (`stat` + `set_fact`) as an early play task, replacing the Facter custom fact.

6. **Health-check polling** (`myFunction1`) — Replace with an Ansible `uri` task writing the JSON result to `/var/lib/redis/health_check.json` via the `copy` module with `content`.

7. **Artifact deployment** (`myDeploy1`) — Implement `get_url` + `unarchive` + version-file tracking tasks for `myapp` v2.1.0. Add checksum validation and HTTPS enforcement.

8. **Cron job** (`myCronType1`) — Replace with the Ansible `cron` module for the `redis-backup` entry (02:30 daily, root user).

9. **Proprietary config-file management** (`myFormatType1`) — Implement `lineinfile`-based tasks (or a custom module) for the two `/etc/company/app.conf` entries (`app-mode=cluster`, `health-port=8080`).

10. **Enterprise Scheduler registration** (`mySecretType1`) — Implement `command`-based tasks wrapping `schedulerctl query/register` with proper idempotency guards (`changed_when`, `failed_when`).

11. **End-to-end integration testing** — Run the complete playbook against a staging environment covering both OS families, validate Redis cluster formation, health-check output, artifact version, cron entry, config file, and scheduler registration.

---

### Assumptions

1. The repository root **is** the Puppet module (there is no wrapping control repo or environment directory). The Ansible equivalent will be a single role.
2. `company_internal_lib` is a proprietary Ruby gem not available publicly. Its API, authentication mechanism, and network requirements are unknown and must be obtained from the internal tooling team.
3. `/usr/local/bin/schedulerctl` is pre-installed on target nodes by a separate provisioning process not covered by this module. The Ansible role will assume the binary is present; if not, a prerequisite task or separate role must install it.
4. `/usr/local/bin/redis-backup.sh` is similarly pre-installed on target nodes. Its installation is out of scope for this module/role.
5. The PuppetDB instance used for `puppetdb_query` peer discovery will remain available during the transition period. A parallel Ansible inventory strategy must be in place before PuppetDB is decommissioned.
6. The `redis_password` default value `'CHANGEME'` is a placeholder only and is overridden via Hiera or an external node classifier in production. The actual production credential must be sourced before the Ansible Vault equivalent is populated.
7. The `myapp` artifact at `http://artifacts.internal/myapp-2.1.0.tar.gz` is accessible from Ansible control node or target nodes at migration time. The URL scheme (HTTP, no TLS) is assumed to be an oversight that will be corrected during migration.
8. The `mySecretType1` resource name `'redis-node'` is used as the scheduler registration identifier for all nodes. If per-node unique names are required, the Ansible task will need to use `inventory_hostname` or a derived value.
9. The `myFormatType1` entries (`app-mode` and `health-port`) are the only managed entries in `/etc/company/app.conf`. Other entries in that file must not be disturbed; `lineinfile` tasks will be scoped accordingly.
10. Target nodes run systemd. Redis service management in the Ansible role will use the `systemd` / `service` module with `enabled: true`.
11. No Hiera data directory exists in this repository. Any Hiera-sourced overrides for `redis_port`, `redis_password`, `maxmemory_mb`, or `maxmemory_policy` in the broader Puppet environment must be identified and migrated to Ansible group/host variables before cutover.
12. The `puppetlabs-apt` dependency implies Ubuntu targets use a non-default APT source for Redis packages. The equivalent APT repository configuration must be replicated in the Ansible role for Ubuntu hosts.
