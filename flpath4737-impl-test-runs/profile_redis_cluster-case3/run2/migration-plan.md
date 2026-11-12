# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. The module provisions a Redis node that participates in a cluster, performing: Redis installation and configuration, application artifact deployment, health-check polling, cron-based backup scheduling, proprietary config-file management, and registration with an internal Enterprise Scheduler platform. Secret retrieval is handled through a proprietary internal Ruby library (`company_internal_lib`).

The migration scope is **one Puppet module** with **four custom types/providers**, **two custom functions**, and **one custom Facter fact**, all of which must be re-implemented as native Ansible constructs. The primary complexity drivers are:

- Replacing four bespoke Puppet types/providers with Ansible modules or tasks
- Replacing the proprietary `mySecretFunction1` / `CompanyInternal::SecretStore` secret-retrieval mechanism with an Ansible-compatible vault or secrets-manager integration
- Replacing the PuppetDB-based node-discovery query with Ansible inventory/group logic
- Replacing the proprietary `schedulerctl` Enterprise Scheduler integration

**Estimated migration effort**: 3–5 sprints (6–10 weeks) for a small team, accounting for the custom provider re-implementation and secrets-management integration work.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case3**:
  - Description: Redis cluster node profile (v3.1.0) that installs and configures a Redis server via the `puppet-redis` Forge module, manages a templated `redis.conf`, deploys an internal application artifact (`myapp` v2.1.0) from an internal artifact server, polls a local HTTP health-check endpoint and writes the result to disk, manages cron-based Redis backup scheduling, writes proprietary `!key=value` entries to `/etc/company/app.conf`, retrieves a Redis service token from an internal secret store, and registers the node with a proprietary Enterprise Scheduler platform via `schedulerctl`.
  - Path: `.` (module root — `manifests/`, `templates/`, `lib/`)
  - Technology: Puppet
  - Key Features:
    - Redis installation via `puppet-redis` (bind `0.0.0.0`, port 6379, `requirepass`, AOF persistence, RDB snapshots, `maxmemory` / `maxmemory-policy`)
    - Templated `redis.conf.erb` rendered with FQDN, port, password, memory settings
    - PuppetDB node-discovery query (`puppetdb_query`) to enumerate cluster peers
    - Custom Facter fact `redis_role` (detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf`)
    - `myFunction1`: HTTP GET function that fetches and parses a JSON health-check endpoint
    - `mySecretFunction1`: Retrieves named credentials from `CompanyInternal::SecretStore` (proprietary Ruby library)
    - `myDeploy1` custom type/provider: Downloads a versioned `.tar.gz` artifact from an internal URL, extracts it to an install directory, and tracks the installed version via `version.txt`
    - `myFormatType1` custom type/provider: Manages `!key=value` entries in the proprietary CompanyApp settings file (`/etc/company/app.conf`)
    - `myCronType1` custom type/provider: Manages root crontab entries via `crontab -l` / `crontab -` (runs `/usr/local/bin/redis-backup.sh` at 02:30 daily)
    - `mySecretType1` custom type/provider: Registers/unregisters the node in the Enterprise Scheduler platform via `/usr/local/bin/schedulerctl`

---

### Infrastructure Files

- `Puppetfile`: Declares Forge module pins — `puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`. These are build-time dependencies resolved by r10k/librarian-puppet; they have no direct Ansible equivalent but inform which Ansible collections/roles are needed.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraints, Forge dependencies). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency version requirements.
- `templates/redis.conf.erb`: ERB template for `/etc/redis/redis.conf`. Injects `fqdn`, `redis_port`, `redis_password`, `maxmemory_mb`, and `maxmemory_policy`. Must be converted to a Jinja2 template (`.j2`) for Ansible.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica` by checking for `replicaof` in `/etc/redis/conf.d/replica.conf`. Must be replaced with an Ansible fact (`set_fact` or a custom fact module).
- `lib/puppet/functions/myFunction1.rb`: Puppet function performing an HTTP GET and returning parsed JSON. Replace with Ansible's `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Puppet function calling `CompanyInternal::SecretStore.fetch(credential_name)` via the proprietary `company_internal_lib` Ruby gem. Must be replaced with an Ansible secrets-management lookup (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, or equivalent).
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron type managing root crontab via shell. Replace with Ansible's built-in `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom artifact-deployment type (download → extract → version-track). Replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Custom type managing `!key=value` lines in `/etc/company/app.conf`. Replace with Ansible `lineinfile` (with a `regexp` matching `^!<key>=`) or a custom Jinja2 template for the full file.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Custom type wrapping the proprietary `schedulerctl` CLI for Enterprise Scheduler registration. Replace with Ansible `command`/`shell` tasks (or a custom Ansible module) that invoke `schedulerctl register`/`unregister` with idempotency guards.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary targets per `metadata.json`); Ubuntu 22.04 and 24.04 also supported. Package management uses both `yum`/`dnf` (RHEL) and `apt` (Ubuntu) — the `puppetlabs-apt` Forge dependency confirms Debian-family support is active.
- **Virtual Machine Technology**: Not specified in the repository. No cloud-init configs, VM tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud-provider SDK configurations, metadata endpoint references, or IAM role files are present. The internal artifact URL (`http://artifacts.internal/`) and secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides `stdlib::to_json()` used in `init.pp`. Replace with Ansible's built-in `to_json` Jinja2 filter (`{{ variable | to_json }}`).
- **puppet-redis (11.0.0)**: Manages Redis package installation, service, and base configuration. Replace with the `community.general` collection or the `geerlingguy.redis` Ansible role (available on Ansible Galaxy), or implement directly with `package`, `template`, and `service` tasks.
- **puppetlabs-apt (9.4.0)**: Manages APT repository sources on Ubuntu. Replace with Ansible's `ansible.builtin.apt_repository` module for Ubuntu targets.
- **puppetdb_query (PuppetDB API)**: Used in `init.pp` to discover all cluster peer nodes. Replace with Ansible dynamic inventory, group variables, or a `set_fact` task that reads from a static/dynamic inventory group. This is a **critical architectural change** — cluster topology must be encoded in Ansible inventory rather than queried at runtime from PuppetDB.
- **company_internal_lib (Ruby gem — proprietary)**: Used by `mySecretFunction1` to fetch credentials from `CompanyInternal::SecretStore`. The target Ansible secrets backend must be identified and agreed upon with the security team before migration begins (see Security Considerations).
- **schedulerctl CLI (/usr/local/bin/schedulerctl)**: Proprietary binary for Enterprise Scheduler registration. Must be present on target nodes; Ansible tasks will invoke it directly. Idempotency must be implemented explicitly (query before register/unregister).

---

### Security Considerations

- **Redis `requirepass` / `$redis_password`**: The class parameter defaults to the plaintext string `'CHANGEME'`. In Ansible, this must be stored in Ansible Vault (`ansible-vault encrypt_string`) or retrieved from a secrets manager at play time. The string must never appear in plaintext in inventory, group_vars, or playbooks.
- **`mySecretFunction1` / `CompanyInternal::SecretStore`**: The `redis_service_token` credential is fetched at Puppet catalog compile time via a proprietary internal library. The Ansible equivalent lookup plugin must be identified (HashiCorp Vault `community.hashi_vault.hashi_vault`, AWS SSM Parameter Store `amazon.aws.aws_ssm`, or a custom lookup). The secret store endpoint, authentication method, and token path must be documented before migration.
- **`redis.conf.erb` — password in template**: The `requirepass` directive is rendered directly into the Redis configuration file from the `$redis_password` variable. The rendered file on disk contains the password in plaintext; ensure file permissions (`0600`, owner `redis`) are enforced in the Ansible task, and consider using Redis ACL files (Redis 6+) as a more secure alternative.
- **Artifact download over HTTP**: `myDeployProvider` downloads `myapp-2.1.0.tar.gz` from `http://artifacts.internal/` (plain HTTP, not HTTPS). The Ansible replacement should use HTTPS and validate checksums (`get_url` with `checksum` parameter) to prevent tampering.
- **`mySecretType1` / `schedulerctl`**: The provider calls `schedulerctl register <name> --schedule <schedule>`. If `schedulerctl` accepts or embeds credentials, those must be managed securely (environment variables or a secrets lookup) rather than hardcoded in task arguments.
- **`redis_role` Facter fact**: Reads `/etc/redis/conf.d/replica.conf` to determine node role. This file path and its `replicaof` directive may contain the primary node's IP/hostname. Ensure this information is treated as infrastructure-sensitive data in Ansible inventory.

---

### Technical Challenges

1. **PuppetDB node-discovery replacement**: `puppetdb_query` dynamically enumerates all nodes that have applied the `Profile_redis_cluster_case3` class. Ansible has no direct equivalent at task runtime. Mitigation: encode the Redis cluster membership in a dedicated Ansible inventory group (e.g., `[redis_cluster]`) and pass peer addresses via group variables. If dynamic discovery is required, implement a custom dynamic inventory script or use a service-discovery backend (Consul, AWS EC2 tags, etc.).

2. **Proprietary secret store integration (`company_internal_lib`)**: The Ruby gem `company_internal_lib` is an internal dependency with no public documentation. The Ansible secrets lookup strategy depends entirely on what backend this library wraps. This must be reverse-engineered or documented by the security/platform team before migration can proceed. This is the **highest-risk blocker**.

3. **Custom `myFormatType1` provider — proprietary config format**: The `!key=value` format in `/etc/company/app.conf` is non-standard. Ansible's `lineinfile` can manage individual lines with a regexp (`^!app-mode=`), but if the full file structure is complex, a Jinja2 template rendering the entire file from variables is safer and more idiomatic. The full schema of `app.conf` must be understood before choosing an approach.

4. **`mySecretType1` / Enterprise Scheduler idempotency**: The Puppet provider uses `schedulerctl query` to check existence before registering. Ansible `command`/`shell` tasks are not inherently idempotent. A wrapper task using `changed_when` / `failed_when` conditions, or a custom Ansible module, must replicate this idempotency logic.

5. **`myDeploy1` version-tracking**: The provider tracks the installed version via a `version.txt` sentinel file. The Ansible replacement must implement the same guard (`stat` + `slurp`/`command` to read `version.txt`, then conditionally run `get_url` + `unarchive`) to avoid re-deploying on every run.

6. **ERB → Jinja2 template conversion**: `redis.conf.erb` uses `<%= @facts['networking']['fqdn'] %>` (Puppet fact syntax). The Ansible equivalent is `{{ ansible_fqdn }}`. All ERB interpolations must be mapped to their Ansible/Jinja2 counterparts, and the template must be validated against both RHEL and Ubuntu targets.

7. **Dual OS support (RHEL + Ubuntu)**: The module supports four OS versions across two families. Ansible tasks must use `when` conditionals or role defaults to handle `dnf` vs `apt`, service names, and file paths that may differ between distributions. The `puppetlabs-apt` dependency confirms that APT-specific logic exists and must be ported.

8. **`redis_role` fact migration**: The custom Facter fact determines node role at runtime by inspecting a file. In Ansible, this can be replaced with a `stat` + `set_fact` task block early in the play, or by pre-classifying nodes in inventory with a `redis_role` host variable. The latter is preferred for clarity and auditability.

---

### Migration Order

1. **Infrastructure prerequisites** — Confirm the Ansible secrets-management backend (replacement for `CompanyInternal::SecretStore`), establish Ansible Vault conventions for `redis_password` and `redis_service_token`, and encode Redis cluster topology in Ansible inventory. This unblocks all subsequent work.

2. **Redis installation and configuration** (`manifests/install.pp` + `templates/redis.conf.erb`) — Straightforward replacement using `ansible.builtin.package`, a Jinja2 `redis.conf.j2` template, and `ansible.builtin.service`. Low risk; validates the basic Ansible role skeleton and OS-family conditionals.

3. **`redis_role` fact** (`lib/facter/redis_role.rb`) — Replace with a `stat` + `set_fact` task block. Low complexity; establishes the pattern for fact migration.

4. **Health-check HTTP fetch** (`myFunction1`) — Replace with `ansible.builtin.uri` + `ansible.builtin.copy` (writing JSON to `/var/lib/redis/health_check.json`). Low complexity.

5. **Cron backup scheduling** (`myCronType1`) — Replace with `ansible.builtin.cron`. Straightforward one-to-one mapping.

6. **Artifact deployment** (`myDeploy1`) — Replace with `ansible.builtin.get_url` + `ansible.builtin.unarchive` + version-sentinel guard tasks. Medium complexity due to idempotency logic.

7. **Proprietary config-file management** (`myFormatType1`) — Replace with `ansible.builtin.lineinfile` tasks (one per `!key=value` entry) or a full Jinja2 template for `/etc/company/app.conf`. Medium complexity; requires full schema of `app.conf` to be documented first.

8. **Enterprise Scheduler registration** (`mySecretType1`) — Replace with `ansible.builtin.command` tasks wrapping `schedulerctl`, with explicit idempotency guards. Medium complexity; depends on `schedulerctl` being available on target nodes and its query/register/unregister interface being documented.

9. **Secret retrieval** (`mySecretFunction1`) — Implement the agreed Ansible secrets lookup plugin for `redis_service_token`. High complexity; blocked on secret-store backend identification (Step 1). Integrate last, after all other tasks are validated with placeholder values.

---

### Assumptions

1. The `company_internal_lib` Ruby gem wraps an internal secrets management system (e.g., HashiCorp Vault, CyberArk, or a bespoke API). The exact backend is unknown from the repository alone and must be confirmed with the Platform/Security team before migration begins.

2. The `schedulerctl` binary (`/usr/local/bin/schedulerctl`) will be pre-installed on target nodes by a separate process (OS image, bootstrap script, or another Ansible role). Its CLI interface (specifically the `query`, `register`, and `unregister` subcommands and their exit codes) is assumed to be stable and documented internally.

3. The internal artifact server (`http://artifacts.internal/`) is assumed to remain accessible from Ansible control nodes and managed hosts during migration. It is assumed that an HTTPS endpoint can be made available to replace the current plain-HTTP URL.

4. PuppetDB is used solely for cluster peer discovery in this module. It is assumed that the full cluster membership can be statically or dynamically encoded in Ansible inventory without loss of functionality.

5. The `redis_role` fact (`primary` vs `replica`) is used for informational/classification purposes within this module. It is assumed that the role is either pre-assigned in inventory or determinable at play time via the same file-inspection logic.

6. The `puppetlabs-apt` Forge dependency implies that APT repository management (adding the Redis PPA or a custom repo) is required on Ubuntu targets. The exact repository source is not visible in this module's files and may be defined in a higher-level control repo or profile. This must be confirmed.

7. The `myapp` artifact (`myapp-2.1.0.tar.gz`) is assumed to be a long-lived internal application whose version will continue to be managed as a variable in the Ansible role. The artifact URL structure (`http://artifacts.internal/<app>-<version>.tar.gz`) is assumed to be stable.

8. The `maxmemory_mb` default of 2048 MB and `maxmemory_policy` of `allkeys-lru` are assumed to be appropriate defaults for the Ansible role variables. Environment-specific overrides will be managed via Ansible group_vars or host_vars.

9. It is assumed that Ansible will be run with sufficient privileges (become/sudo) to manage Redis packages, service files, crontab entries for root, and files under `/etc/`, `/var/lib/redis/`, `/var/log/redis/`, and `/opt/myapp/`.

10. The `redis.conf.erb` template is assumed to be the authoritative Redis configuration source. Any additional configuration managed by the `puppet-redis` Forge module (beyond what is visible in `install.pp`) must be audited in the Forge module's source before the Ansible template is finalised.
