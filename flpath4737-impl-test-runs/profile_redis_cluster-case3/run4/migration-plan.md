# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case3` (v3.1.0) — authored by the Platform Team. The module provisions a Redis node that participates in a cluster, using PuppetDB for peer discovery, a proprietary internal secret store, a proprietary application-settings format, a proprietary Enterprise Scheduler integration, and a custom artifact-deployment mechanism.

The migration scope is **one Puppet module** with **moderate-to-high complexity**, driven not by the Redis configuration itself (which is straightforward) but by four custom Puppet types/providers and two custom Puppet functions that encapsulate company-specific integrations. Each of these must be re-implemented as Ansible tasks, modules, or roles before the Redis role can be considered fully migrated.

**Estimated timeline**: 3–5 sprints (6–10 weeks) for a single experienced Ansible engineer, assuming the proprietary back-end APIs (`company_internal_lib`, `schedulerctl`) are documented and accessible.

---

## Module Migration Plan

This repository contains one Puppet profile module that needs individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case3**
  - **Description**: Redis cluster node profile (v3.1.0) for RedHat 8/9 and Ubuntu 22.04/24.04. Installs and configures a Redis server via the `puppet-redis` Forge module, manages the `redis.conf` template (port, password, maxmemory, AOF/RDB persistence, TCP tuning), creates the `/var/log/redis` directory, performs a live HTTP health-check call against `localhost:8080/health`, deploys a companion application artifact (`myapp` v2.1.0) from an internal artifact server, retrieves a service token from a proprietary secret store, registers the node with an Enterprise Scheduler platform, writes two entries into a proprietary `!key=value` application-settings file (`/etc/company/app.conf`), and schedules a nightly Redis backup cron job at 02:30.
  - **Path**: `.` (module root — `manifests/init.pp`, `manifests/install.pp`, `templates/redis.conf.erb`)
  - **Technology**: Puppet
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (bind `0.0.0.0`, configurable port/password/maxmemory, AOF `everysec` + RDB snapshots)
    - `redis.conf.erb` template with full persistence, memory, and network tuning
    - PuppetDB peer-discovery query (`puppetdb_query`) to enumerate all cluster nodes
    - Custom Facter fact `redis_role` — detects `primary` vs `replica` by inspecting `/etc/redis/conf.d/replica.conf`
    - Custom function `myFunction1` — synchronous HTTP GET returning parsed JSON (used for health-check ingestion)
    - Custom function `mySecretFunction1` — fetches a named credential from `CompanyInternal::SecretStore` via `company_internal_lib`
    - Custom type/provider `myDeploy1` / `myDeployProvider` — downloads a versioned `.tar.gz` artifact from an internal URL, extracts it, and tracks the installed version via `version.txt`
    - Custom type/provider `myFormatType1` / `myFormatProvider1` — idempotently manages `!key=value` entries in the proprietary CompanyApp settings file
    - Custom type/provider `mySecretType1` / `mySecretProvider1` — registers/unregisters the node in the Enterprise Scheduler platform via the `/usr/local/bin/schedulerctl` CLI
    - Custom type/provider `myCronType1` / `myCronProvider1` — manages root crontab entries via `crontab -l` / `crontab -`

---

### Infrastructure Files

- `Puppetfile`: Declares three Forge module dependencies pinned to exact versions (`puppetlabs-stdlib 9.6.0`, `puppet-redis 11.0.0`, `puppetlabs-apt 9.4.0`). Must be replaced by Ansible Galaxy `requirements.yml` or equivalent community roles.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version constraints, Forge dependencies). Provides the authoritative OS target list (RHEL 8/9, Ubuntu 22.04/24.04) and dependency version requirements for the Ansible role's `meta/main.yml`.
- `templates/redis.conf.erb`: ERB template for `redis.conf`. Must be converted to a Jinja2 template (`.j2`) for Ansible. Variable references (`@redis_port`, `@redis_password`, `@maxmemory_mb`, `@maxmemory_policy`, `@facts['networking']['fqdn']`) map directly to Ansible variables and `ansible_fqdn`.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica` by checking for `replicaof` in `/etc/redis/conf.d/replica.conf`. Must be replaced by an Ansible task that sets a host fact (e.g., `set_fact`) using the same file-inspection logic.
- `lib/puppet/functions/myFunction1.rb`: HTTP GET helper returning parsed JSON. Replace with Ansible's built-in `uri` module.
- `lib/puppet/functions/mySecretFunction1.rb`: Credential retrieval from `CompanyInternal::SecretStore` via `company_internal_lib`. Requires integration with Ansible Vault or a secrets-manager lookup plugin (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.) depending on what `company_internal_lib` wraps.
- `lib/puppet/type/myCronType1.rb` + `lib/puppet/provider/myCronType1/myCronProvider1.rb`: Custom cron type managing root crontab entries. Replace with Ansible's built-in `cron` module.
- `lib/puppet/type/myDeploy1.rb` + `lib/puppet/provider/myDeploy1/myDeployProvider.rb`: Custom artifact-deployment type (download tarball, extract, write `version.txt`). Replace with Ansible `get_url` + `unarchive` + `copy`/`template` tasks.
- `lib/puppet/type/myFormatType1.rb` + `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`: Proprietary `!key=value` settings-file manager. Replace with Ansible `lineinfile` (regex `^!<key>=`) or a custom `ini_file`-style task.
- `lib/puppet/type/mySecretType1.rb` + `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`: Enterprise Scheduler registration via `/usr/local/bin/schedulerctl`. Replace with Ansible `command` module tasks (register/unregister) wrapped in `changed_when` / `failed_when` guards, or a custom Ansible module if idempotency logic is complex.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary targets per `metadata.json`); Ubuntu 22.04 and 24.04 also supported. Package management uses the `puppetlabs-apt` Forge module for Debian-family nodes, implying `apt`-based installation on Ubuntu. Ansible role must branch on `ansible_os_family` (`RedHat` vs `Debian`) for package manager tasks.
- **Virtual Machine Technology**: Not specified in the repository. No cloud-init configs, VM tools packages, or hypervisor-specific files are present.
- **Cloud Platform**: Not specified. No cloud-provider SDK configurations, metadata endpoint references, or cloud-specific IAM/credential files are present. The internal artifact URL (`http://artifacts.internal/`) and secret store suggest an on-premises or private-cloud environment.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Used for `stdlib::to_json()`. Replace with Ansible's built-in `to_json` Jinja2 filter — no external dependency needed.
- **puppet-redis (11.0.0)**: Wraps Redis package installation, service management, and `redis.conf` deployment. Replace with the community Ansible role [`geerlingguy.redis`](https://galaxy.ansible.com/geerlingguy/redis) or equivalent, supplemented by the converted `redis.conf.j2` template for site-specific tuning parameters not exposed by the role's defaults.
- **puppetlabs-apt (9.4.0)**: Manages APT sources for Redis on Ubuntu. Replace with Ansible's built-in `apt_repository` module or the `geerlingguy.redis` role's built-in repo management.
- **PuppetDB (`puppetdb_query`)**: Used to discover all cluster peer nodes at catalog-compile time. Ansible has no direct equivalent; replace with Ansible dynamic inventory groups (e.g., all hosts in the `redis_cluster` group), `hostvars` lookups, or a dynamic inventory plugin querying the CMDB/cloud provider.
- **`company_internal_lib` / `CompanyInternal::SecretStore`**: A proprietary Ruby gem used by `mySecretFunction1`. The target Ansible secrets back-end must be identified (HashiCorp Vault, CyberArk, AWS Secrets Manager, etc.) before migration can be completed. This is the highest-risk dependency.
- **`/usr/local/bin/schedulerctl`**: Proprietary CLI for the Enterprise Scheduler platform. Must be present on managed nodes (or a jump host) for the Ansible `command`-based replacement tasks to function. API documentation should be obtained to assess whether a proper Ansible module is warranted.

---

### Security Considerations

- **Hardcoded default password**: `manifests/init.pp` declares `String $redis_password = 'CHANGEME'` as a Puppet class parameter default. In Ansible, this variable must be stored in Ansible Vault (`ansible-vault encrypt_string`) or sourced from a secrets manager lookup — never in plaintext in `defaults/main.yml` or inventory.
- **Redis `requirepass` in template**: `templates/redis.conf.erb` renders `requirepass <%= @redis_password %>` directly into the configuration file. The Jinja2 replacement must ensure the rendered file has restrictive permissions (`0600`, owned by `redis`) and that the password value is always sourced from Vault at render time.
- **`mySecretFunction1` / `redis_service_token`**: A named credential (`redis_service_token`) is fetched from `CompanyInternal::SecretStore` at catalog-compile time and written to `/var/lib/redis/health_check.json` (mode `0644`). Two concerns: (1) the secret store integration must be mapped to an Ansible Vault or lookup plugin; (2) the output file's world-readable permissions (`0644`) should be reviewed — if the health-check JSON contains the token value, the mode should be tightened to `0640` or `0600`.
- **Artifact download over plain HTTP**: `myDeploy1` fetches `http://artifacts.internal/myapp-2.1.0.tar.gz` over unencrypted HTTP. The Ansible `get_url` replacement should enforce HTTPS and optionally validate a checksum (`checksum` parameter) to prevent tampering.
- **`schedulerctl` CLI trust**: The `mySecretType1` provider invokes `/usr/local/bin/schedulerctl` with node names and schedule strings. Ensure the binary path is integrity-checked and that no user-controlled input can inject shell arguments (use Ansible `command` list form, not `shell`).
- **`redis.conf` bind address**: Redis is bound to `0.0.0.0`. Confirm that network-level controls (firewall rules, security groups) restrict port 6379 access to cluster peers only. Add an `iptables`/`firewalld` task to the Ansible role if not managed elsewhere.

---

### Technical Challenges

- **PuppetDB peer-discovery replacement**: `puppetdb_query` runs at Puppet catalog-compile time and injects a live list of cluster peers into the catalog. Ansible has no compile-time equivalent. The replacement strategy — dynamic inventory groups, `hostvars` iteration, or a pre-task that queries a CMDB — must be agreed upon before the role is written, as it affects how `redis.conf` cluster topology is rendered.
- **Proprietary secret store integration**: `mySecretFunction1` depends on `company_internal_lib`, an internal Ruby gem whose API is not publicly documented. The Ansible secrets back-end must be identified and a lookup plugin (or `vars_plugin`) must be implemented or configured before any secret-bearing tasks can be tested. This is the single largest migration blocker.
- **Custom `!key=value` file format (`myFormatType1`)**: The proprietary CompanyApp settings format is not a standard INI, YAML, or JSON file. Ansible's `lineinfile` can manage individual `!key=value` lines with a carefully crafted `regexp`, but the full idempotency logic (insert if absent, update if changed, leave comments untouched) must be validated against the actual file format. A custom Ansible module may be cleaner than multiple `lineinfile` tasks.
- **Enterprise Scheduler registration (`mySecretType1` / `schedulerctl`)**: The `schedulerctl` CLI is proprietary. Idempotency (the `exists?` check via `schedulerctl query`) must be replicated in Ansible using `command` with `register` + `changed_when` / `failed_when`. If `schedulerctl query` returns non-zero for "not registered" vs. "error", the Ansible task logic must distinguish these cases. Full CLI documentation is required.
- **Custom artifact deployment (`myDeploy1`)**: The version-tracking mechanism (`version.txt`) is simple and can be replicated with `stat` + `slurp` + conditional `get_url`/`unarchive` tasks. However, the internal artifact server URL uses plain HTTP and may require VPN or internal DNS resolution from the Ansible control node or target hosts — network reachability must be confirmed.
- **Facter fact `redis_role`**: Puppet's `redis_role` fact is available throughout the catalog. In Ansible, the equivalent `set_fact` task must run early in the play (before any task that consumes it) and must be explicitly included in the role's task order — it is not automatically available like a Facter fact.
- **Cross-platform package management**: The module supports both RHEL (yum/dnf) and Ubuntu (apt). The Ansible role must use `ansible_os_family` conditionals or the `package` module's abstraction layer, and must replicate the APT repository configuration that `puppetlabs-apt` currently handles on Ubuntu nodes.
- **`company_internal_lib` Ruby gem availability**: This gem is required at Puppet agent runtime. Its absence on a node would cause catalog compilation to fail silently for the secret-fetch step. In Ansible, the equivalent lookup plugin or module must be installable on the control node (or execution environment) without requiring the gem.

---

### Migration Order

1. **Redis installation and configuration** (`manifests/install.pp`, `templates/redis.conf.erb`): Lowest risk, maps directly to `geerlingguy.redis` + a Jinja2 template. Delivers immediate value and validates the Ansible role skeleton, variable structure, and OS-family branching. No proprietary dependencies.
2. **`redis_role` fact and health-check file** (`lib/facter/redis_role.rb`, `myFunction1`): Replace the Facter fact with a `set_fact` task and the HTTP health-check with Ansible's `uri` module. Low complexity; validates the dynamic fact pattern before tackling harder integrations.
3. **Cron job** (`myCronType1` / `myCronProvider1`): Direct replacement with Ansible's `cron` module. Trivial complexity; completes the "no proprietary dependency" tier.
4. **Artifact deployment** (`myDeploy1` / `myDeployProvider`): Replace with `get_url` + `unarchive` + `copy` tasks. Moderate complexity due to version-idempotency logic and HTTP→HTTPS upgrade. Requires internal artifact server reachability from the Ansible control node.
5. **Proprietary settings file** (`myFormatType1` / `myFormatProvider1`): Replace with `lineinfile` tasks or a custom Ansible module. Moderate complexity; requires access to a real `/etc/company/app.conf` sample to validate the regex patterns.
6. **Enterprise Scheduler registration** (`mySecretType1` / `mySecretProvider1`): Replace with `command`-based tasks wrapping `schedulerctl`. Requires full CLI documentation and a test environment with `schedulerctl` installed. High complexity due to idempotency edge cases.
7. **Secret store integration** (`mySecretFunction1`, `redis_password`): Implement Ansible Vault or secrets-manager lookup plugin to replace `CompanyInternal::SecretStore`. This is the highest-risk item and should be prototyped in parallel with steps 1–3 so that the secrets back-end is ready when steps 6–7 are reached. Requires Platform/Security team involvement.

---

### Assumptions

1. **Secret store back-end is undocumented**: `company_internal_lib` and `CompanyInternal::SecretStore` are internal Ruby libraries with no public documentation in this repository. It is assumed that the Platform/Security team can provide API documentation or a migration path to a supported secrets manager (e.g., HashiCorp Vault).
2. **`schedulerctl` CLI will remain available**: It is assumed that `/usr/local/bin/schedulerctl` will be present on target nodes (or accessible from the Ansible control node) during and after migration. If the Enterprise Scheduler platform is being decommissioned concurrently, this task block may be dropped entirely.
3. **Internal artifact server will be reachable**: It is assumed that `http://artifacts.internal/` is resolvable and reachable from the Ansible control node or target hosts. The migration plan assumes an HTTPS upgrade is feasible; if the server only supports HTTP, a checksum verification step becomes mandatory.
4. **PuppetDB will not be available post-migration**: The `puppetdb_query` call for cluster peer discovery is assumed to be replaced by Ansible dynamic inventory or static group membership. If PuppetDB is retained alongside Ansible during a transition period, a PuppetDB inventory plugin could be used temporarily.
5. **`redis_role` fact is informational only in this module**: The `redis_role` Facter fact is defined in this module but is not consumed within `init.pp` or `install.pp`. It is assumed it is used by other profiles or reports. Its Ansible equivalent (`set_fact`) should still be implemented for parity, but it is not on the critical path for this role's functionality.
6. **`myapp` artifact version is managed externally**: The version `2.1.0` is hardcoded in `init.pp`. It is assumed this will be parameterised as an Ansible variable (`myapp_version`) in the migrated role, with the value supplied via inventory or a pipeline variable.
7. **Redis cluster topology is managed by this module alone**: It is assumed that no other Puppet module or external system manages Redis replication configuration. If `replica.conf` is written by a separate process, the `redis_role` fact logic and any cluster-topology tasks must be coordinated with that process owner.
8. **Target nodes run systemd**: Redis service management via `puppet-redis` implies systemd on both RHEL 8/9 and Ubuntu 22.04/24.04. The Ansible role will use the `service` module with `enabled: true` / `state: started`; this assumption should be confirmed for any non-standard node images.
9. **`/etc/company/app.conf` pre-exists on target nodes**: The `myFormatType1` provider reads and rewrites the file in place. It is assumed the file exists before the Ansible role runs (created by another role or base image). If it may be absent, an Ansible `file` task to create it must be added.
10. **No Hiera data layer in this module**: The module uses Puppet class parameters with inline defaults rather than a `data/` Hiera directory. All variable values are assumed to be supplied via Ansible inventory `group_vars` / `host_vars` in the migrated role, with no Hiera-to-Ansible data-layer mapping required.
