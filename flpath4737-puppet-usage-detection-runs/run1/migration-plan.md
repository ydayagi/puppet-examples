# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. The module provisions a Redis node that participates in a cluster, performing PuppetDB-driven peer discovery, health-check polling, artifact deployment, cron scheduling, proprietary configuration-file management, and registration with an internal Enterprise Scheduler platform.

The migration scope is moderate-to-high in complexity. The Redis installation and configuration work maps cleanly to Ansible, but the module relies on **four custom Puppet types/providers** and **two custom Puppet functions** that implement company-specific integrations (a secret store, a proprietary config-file format, and a proprietary scheduler CLI). Each of these must be re-implemented as Ansible modules, lookup plugins, or task integrations before the Redis role can be considered fully migrated.

**Estimated timeline**: 4–7 weeks for a single experienced engineer, or 2–3 weeks with a two-person team, accounting for custom-integration re-implementation, testing, and handover.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case3**
  - **Description**: Redis cluster node profile (v3.1.0) that installs and configures a Redis server via the `puppet-redis` Forge module, performs PuppetDB-based cluster peer discovery, polls an internal HTTP health-check endpoint, deploys a versioned application artifact (`myapp` v2.1.0) from an internal artifact server, retrieves a service token from a proprietary secret store, registers the node with an Enterprise Scheduler platform on a daily schedule, manages two entries in a proprietary `!key=value` application config file (`/etc/company/app.conf`), and schedules a nightly Redis backup cron job.
  - **Path**: `.` (repository root — the module is the repository itself)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis installation with `puppet-redis` (bind `0.0.0.0`, port 6379, `requirepass`, AOF persistence with `appendfsync everysec`, RDB snapshots, `maxmemory` / `maxmemory-policy` tuning)
    - `redis.conf.erb` template rendered with FQDN, port, password, memory settings
    - Custom Facter fact `redis_role` — detects primary vs. replica by inspecting `/etc/redis/conf.d/replica.conf`
    - PuppetDB query for live cluster peer discovery (`puppetdb_query`)
    - Custom function `myFunction1` — HTTP GET to an internal health endpoint, returns parsed JSON
    - Custom function `mySecretFunction1` — fetches a named credential from `CompanyInternal::SecretStore` (requires internal Ruby gem `company_internal_lib`)
    - Custom type/provider `myDeploy1` / `myDeployProvider` — downloads a `.tar.gz` artifact over HTTP/HTTPS, extracts it, and tracks the installed version via `version.txt`
    - Custom type/provider `myFormatType1` / `myFormatProvider1` — manages `!key=value` entries in the proprietary CompanyApp settings file
    - Custom type/provider `myCronType1` / `myCronProvider1` — manages root crontab entries via `crontab -l` / `crontab -`
    - Custom type/provider `mySecretType1` / `mySecretProvider1` — registers/unregisters nodes in the Enterprise Scheduler platform via `/usr/local/bin/schedulerctl`
    - Log directory `/var/log/redis` managed with `redis:redis 0755` ownership
    - Health-check JSON written to `/var/lib/redis/health_check.json`

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). These must be replaced with equivalent Ansible Galaxy collections or roles.
- `metadata.json`: Module metadata — version 3.1.0, Apache-2.0 license, supports RHEL 8/9 and Ubuntu 22.04/24.04, requires Puppet ≥ 7.0.0. Provides the authoritative OS target matrix for the Ansible role.
- `templates/redis.conf.erb`: ERB template for `redis.conf`. Must be converted to a Jinja2 template (`.j2`) for use with Ansible's `template` module. Variable names (`@redis_port`, `@redis_password`, `@maxmemory_mb`, `@maxmemory_policy`, `@facts['networking']['fqdn']`) map directly to Ansible variables and `ansible_fqdn`.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica`. Must be re-implemented as an Ansible custom fact script or a `set_fact` task that inspects `/etc/redis/conf.d/replica.conf` at runtime.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper returning parsed JSON. Replace with Ansible's built-in `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval via `CompanyInternal::SecretStore` (Ruby gem `company_internal_lib`). Must be replaced with an Ansible lookup plugin targeting the same secret store, or migrated to HashiCorp Vault / AWS Secrets Manager / Azure Key Vault depending on the underlying store implementation.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Artifact download, extraction, and version tracking. Replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` config-file manager. Replace with a custom Ansible module or `lineinfile`/`replace` tasks using a regex pattern matching `!<key>=<value>` lines.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Root crontab management. Replace with Ansible's built-in `cron` module.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration via `schedulerctl` CLI. Replace with an Ansible `command`/`shell` task wrapping `schedulerctl`, or a custom Ansible module if idempotency is required.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary targets per `metadata.json`); Ubuntu 22.04 and 24.04 also supported. The `puppetlabs-apt` dependency in the `Puppetfile` confirms Debian/Ubuntu support is active. The Ansible role should use `ansible_os_family` conditionals to handle both `RedHat` and `Debian` families.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified. The artifact URL (`http://artifacts.internal/`) and health endpoint (`http://localhost:8080/health`) are internal, suggesting an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the community Ansible role [`geerlingguy.redis`](https://galaxy.ansible.com/geerlingguy/redis) or [`community.general`](https://docs.ansible.com/ansible/latest/collections/community/general/) tasks. Verify that bind address, password, AOF, and memory parameters are all exposed by the chosen role.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu/Debian. Replace with Ansible's built-in `apt_repository` module or the `ansible.builtin.apt` module for package management on Debian-family hosts.
- **company_internal_lib (Ruby gem — version unknown)**: Required by `mySecretFunction1` to access `CompanyInternal::SecretStore`. This is the highest-risk dependency: the underlying secret store technology must be identified before a replacement lookup plugin can be written. Engage the security/platform team early.
- **`/usr/local/bin/schedulerctl` (proprietary CLI — version unknown)**: Required by the `mySecretType1` provider to register nodes with the Enterprise Scheduler. The CLI must be present on target hosts before the Ansible role runs, or its installation must be added to the role. Idempotency logic (the `exists?` check via `schedulerctl query`) must be replicated in Ansible.

---

### Security Considerations

- **Hardcoded Redis password**: `$redis_password` defaults to the literal string `'CHANGEME'` in `manifests/init.pp` and is rendered directly into `redis.conf.erb` as `requirepass`. In Ansible, this variable must be stored in Ansible Vault or retrieved from a secrets manager — it must never appear in plaintext in a variable file or inventory.
- **`mySecretFunction1` / `CompanyInternal::SecretStore`**: The module fetches a `redis_service_token` credential at catalog-apply time from a proprietary internal secret store. The Ansible equivalent must integrate with the same (or a replacement) secrets backend. The secret store API, authentication method, and network reachability from Ansible control nodes must be confirmed before migration begins.
- **Artifact download over plain HTTP**: `myDeployProvider` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (no TLS). The Ansible replacement should enforce HTTPS and optionally validate a checksum (`get_url` supports `checksum`). Coordinate with the artifact server team to enable TLS if not already available.
- **Redis bound to `0.0.0.0`**: Both `manifests/install.pp` and `redis.conf.erb` bind Redis on all interfaces. The Ansible role should expose this as a configurable variable and document the network-level controls (firewall, security groups) required to restrict access.
- **Health-check JSON written world-readable**: `/var/lib/redis/health_check.json` is created with mode `0644`. Verify whether the health-check response contains sensitive data; if so, tighten permissions in the Ansible task.
- **`mySecretType1` / `schedulerctl`**: The provider calls `schedulerctl register <name> --schedule <schedule>` as root. Ensure the Ansible task runs with appropriate privilege escalation (`become: true`) and that the `schedulerctl` binary itself is integrity-verified before use.

---

### Technical Challenges

1. **PuppetDB cluster peer discovery**: `init.pp` uses `puppetdb_query()` to dynamically enumerate all nodes that have applied this class. Ansible has no built-in equivalent. Mitigation: use a dynamic inventory plugin (e.g., querying a CMDB, cloud provider, or a custom PuppetDB inventory script) to populate a host group, then reference `groups['redis_cluster']` within the role. This architectural change must be agreed upon before migration starts.

2. **`mySecretFunction1` and `company_internal_lib`**: The Ruby gem backing the secret store is entirely internal and undocumented in this repository. Identifying the underlying technology (e.g., HashiCorp Vault, CyberArk, an internal REST API) is a prerequisite for writing the Ansible lookup plugin. This is the single largest unknown in the migration.

3. **`myFormatType1` proprietary config format**: The `!key=value` format used by `/etc/company/app.conf` is non-standard. Ansible's `lineinfile` can manage individual lines with a carefully crafted regex (`^!app-mode=.*`), but a custom Ansible module would provide cleaner idempotency and be easier to maintain long-term. The decision between `lineinfile` and a custom module should be made early.

4. **Custom Facter fact `redis_role`**: The `redis_role` fact (primary/replica detection) is consumed by other parts of the Puppet infrastructure (implied by its presence in `lib/facter/`). In Ansible, this logic must be replicated as a `set_fact` task or a custom fact script deployed to `/etc/ansible/facts.d/`. Any other roles or playbooks that consume `redis_role` must be updated to reference the Ansible fact.

5. **`myDeploy1` version-tracking idempotency**: The provider checks `version.txt` to determine whether a re-deploy is needed. The Ansible replacement (`get_url` + `unarchive`) must replicate this idempotency check — for example, using `stat` on `version.txt` and a `when` condition — to avoid re-downloading and re-extracting the artifact on every run.

6. **`mySecretType1` idempotency via `schedulerctl query`**: The provider's `exists?` method calls `schedulerctl query <name>` and treats a non-zero exit code as "not registered." The Ansible `command` task must use `failed_when` / `changed_when` conditions to replicate this behaviour without marking every run as changed.

7. **Cross-platform package management**: The module targets both RHEL (yum/dnf) and Ubuntu (apt). The Ansible role must use `ansible_os_family` or `ansible_pkg_mgr` conditionals, or rely on a Redis Galaxy role that already handles both families. The `puppetlabs-apt` dependency confirms that APT repository configuration is actively used and must be reproduced.

---

### Migration Order

1. **Redis installation and configuration** *(low risk, high value)*
   Migrate `manifests/install.pp` and `templates/redis.conf.erb` first. This is a straightforward mapping to `geerlingguy.redis` (or equivalent) plus a Jinja2 template. Delivers a working Redis node early and validates the Ansible role skeleton, variable structure, and OS-family conditionals.

2. **Cron job and log directory** *(low risk)*
   Replace `myCronType1 { 'redis-backup' }` with Ansible's `cron` module and the `file` resource for `/var/log/redis` with Ansible's `file` module. Both are trivial one-to-one mappings.

3. **Artifact deployment (`myDeploy1`)** *(moderate risk)*
   Replace with `get_url` + `unarchive` + a `copy` task writing `version.txt`. Implement the idempotency check via `stat`. Requires confirming TLS availability on the artifact server.

4. **Health-check polling (`myFunction1`)** *(low-moderate risk)*
   Replace with Ansible's `uri` module. Write the response body to `/var/lib/redis/health_check.json` using the `copy` module with `content`. Straightforward once the Redis service is running.

5. **Proprietary config-file management (`myFormatType1`)** *(moderate risk)*
   Implement as `lineinfile` tasks with `regexp: '^!{{ item.key }}='` and `line: '!{{ item.key }}={{ item.value }}'`, looping over the two entries. Alternatively, write a small custom Ansible module for full idempotency. Validate against the actual `/etc/company/app.conf` format on a real host.

6. **`redis_role` Facter fact** *(moderate risk)*
   Re-implement as a custom fact script in `/etc/ansible/facts.d/redis_role.fact` (a shell script that checks for `replicaof` in `/etc/redis/conf.d/replica.conf`). Update any downstream playbooks that reference this fact.

7. **Cluster peer discovery (PuppetDB replacement)** *(high risk)*
   Design and implement the dynamic inventory strategy. This is an architectural decision that affects all Redis cluster roles, not just this one. Requires coordination with the infrastructure and operations teams.

8. **Secret store integration (`mySecretFunction1`)** *(high risk)*
   Identify the underlying secret store, write or adopt an Ansible lookup plugin, and migrate the `redis_service_token` and `redis_password` credentials into it. Requires security team sign-off.

9. **Enterprise Scheduler registration (`mySecretType1`)** *(high risk)*
   Wrap `schedulerctl` in an Ansible `command` task with proper `changed_when` / `failed_when` guards, or write a custom Ansible module. Requires the `schedulerctl` binary to be pre-installed or added to the role. Coordinate with the scheduler platform team.

---

### Assumptions

1. **Secret store technology is unknown**: `mySecretFunction1` depends on `company_internal_lib` / `CompanyInternal::SecretStore`. The underlying technology (Vault, CyberArk, a REST API, etc.) is not documented in this repository. This must be clarified before the secrets migration step can begin.

2. **`schedulerctl` binary availability**: It is assumed that `/usr/local/bin/schedulerctl` is already installed on target hosts by a separate process. If not, its installation must be added to the Ansible role or a prerequisite role.

3. **`myapp` artifact server TLS**: The artifact URL uses plain HTTP. It is assumed that an HTTPS endpoint either already exists or can be enabled. If not, the `get_url` checksum validation becomes the primary integrity control.

4. **PuppetDB is not available post-migration**: The migration assumes that PuppetDB will not be retained as an inventory source for Ansible. If PuppetDB is kept, a PuppetDB dynamic inventory plugin could be used as a transitional measure.

5. **`redis_role` fact consumers**: It is assumed that the `redis_role` Facter fact may be consumed by other Puppet modules not present in this repository. A full audit of the broader Puppet codebase should be performed to identify all consumers before the fact is removed.

6. **`/etc/company/app.conf` pre-exists**: The `myFormatType1` provider reads and modifies an existing file. It is assumed this file is created by another process or module. The Ansible role must either create it if absent or use `stat` + `fail` to enforce the precondition.

7. **Redis cluster topology is external**: The `puppetdb_query` result is stored in `$redis_nodes` but is not visibly used within this module's manifests (no replication configuration is applied based on it). It is assumed the query result is used for informational purposes or consumed by a template/resource not shown. This should be verified before the discovery logic is dropped.

8. **`geerlingguy.redis` or equivalent covers all required parameters**: It is assumed that the chosen Ansible Redis role exposes `bind`, `port`, `requirepass`, `maxmemory`, `appendonly`, `appendfsync`, and `manage_package` equivalents. If not, the role will need to be forked or supplemented with direct `template` tasks.

9. **Target Ansible version**: Ansible 2.14+ (or `ansible-core` 2.14+) is assumed, as it provides all built-in modules referenced in this plan (`uri`, `cron`, `get_url`, `unarchive`, `lineinfile`, `template`, `file`).

10. **`myapp` version is static**: The artifact version `2.1.0` is hardcoded in `init.pp`. It is assumed this will be parameterised as an Ansible variable (`myapp_version`) in the migrated role rather than remaining hardcoded.
