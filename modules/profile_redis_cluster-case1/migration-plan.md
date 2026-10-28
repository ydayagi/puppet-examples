# MIGRATION FROM PUPPET TO ANSIBLE

## Executive Summary

This repository contains a single Puppet profile module — `profile_redis_cluster_case1` (v3.1.0) — that provisions and configures a Redis cluster node. The module is authored by the Platform Team and targets Red Hat Enterprise Linux 8/9 and Ubuntu 22.04/24.04.

Migration scope is **narrow but technically nuanced**: the module is small in line count, yet it relies on three Puppet-specific extension mechanisms (a custom Facter fact, a custom Puppet function, and a custom Puppet type/provider) that have no direct Ansible equivalents and each require deliberate re-implementation. The hardcoded Redis password in the default parameter value is a security concern that must be resolved before or during migration.

**Estimated migration effort**: 2–3 sprints (4–6 weeks) for a single engineer, including testing on both supported OS families.

---

## Module Migration Plan

This repository contains one Puppet profile module that requires individual migration planning.

### MODULE INVENTORY

**CRITICAL PATH VERIFICATION:**
Only modules whose paths were confirmed in the provided repository tree are listed below.

---

- **profile_redis_cluster_case1**:
  - **Description**: Redis cluster node profile that installs and configures a Redis server instance via the `puppet-redis` Forge module. Manages the Redis package, service, and configuration (bind address, port, authentication password, AOF persistence with `everysec` fsync, RDB snapshots, memory cap and eviction policy). Also creates the `/var/log/redis` log directory with correct ownership. Node discovery for cluster membership is performed at catalog compile time via a live `puppetdb_query()` call that enumerates all nodes classified with this profile. A custom Facter fact (`redis_role`) determines whether the node is a primary or replica by inspecting `/etc/redis/conf.d/replica.conf` at runtime. A custom Puppet function (`myFunction1`) performs an HTTP GET health check against `http://localhost:8080/health` and returns the parsed JSON response. A custom Puppet type/provider (`myType1`/`myProvider1`) enforces that the same health endpoint is reachable, raising a hard error if it is not.
  - **Path**: `.` (module root — `manifests/`, `templates/`, `lib/`)
  - **Technology**: Puppet (≥ 7.0.0 < 9.0.0)
  - **Key Features**:
    - Redis installation and service management via `puppet-redis` (v11.x)
    - `redis.conf.erb` template with FQDN-aware header, AOF + RDB persistence, memory policy, and TCP tuning
    - PuppetDB live node-discovery query (`puppetdb_query()`) for cluster peer enumeration
    - Custom Facter fact `redis_role` — detects primary vs. replica by inspecting replica config file
    - Custom Puppet function `myFunction1` — HTTP GET helper returning parsed JSON (used for health checks)
    - Custom Puppet type `myType1` + provider `myProvider1` — idempotent HTTP reachability enforcement resource
    - Parameterised class interface: `$redis_port`, `$redis_password`, `$maxmemory_mb`, `$maxmemory_policy`

---

### Infrastructure Files

- `Puppetfile`: Declares Forge module pins consumed by this profile. Locks `puppetlabs-stdlib` at 9.6.0, `puppet-redis` at 11.0.0, and `puppetlabs-apt` at 9.4.0 (APT source management for Debian/Ubuntu targets). Must be translated into Ansible Galaxy `requirements.yml` or replaced by direct task logic.
- `metadata.json`: Module metadata (name, version, author, license, OS support matrix, Puppet version bounds, Forge dependencies). Serves as the authoritative source for supported OS versions and dependency version constraints during Ansible role scaffolding.
- `templates/redis.conf.erb`: ERB template producing the full `redis.conf`. Embeds `@facts['networking']['fqdn']`, `@redis_port`, `@redis_password`, `@maxmemory_mb`, and `@maxmemory_policy`. Must be rewritten as a Jinja2 template (`redis.conf.j2`) with equivalent variable substitution.
- `lib/facter/redis_role.rb`: Custom Facter fact that classifies a node as `primary` or `replica` at agent run time. Must be replaced by an Ansible task (e.g., `ansible.builtin.stat` + `ansible.builtin.slurp` or `ansible.builtin.shell`) that sets a host variable or fact with the same semantic.
- `lib/puppet/functions/myFunction1.rb`: Custom Puppet 4 API function performing an HTTP GET and returning parsed JSON. Must be replaced by `ansible.builtin.uri` module calls within tasks.
- `lib/puppet/type/myType1.rb`: Custom resource type declaring an HTTP endpoint as an ensurable Puppet resource. No direct Ansible equivalent — must be replaced by an `ansible.builtin.uri` task with `failed_when` logic.
- `lib/puppet/provider/myType1/myProvider1.rb`: Provider implementing `exists?`/`create`/`destroy` for `myType1` via HTTP GET. Logic collapses into a single `ansible.builtin.uri` task with `register` + `failed_when`.

---

### Target Details

- **Operating System**: Red Hat Enterprise Linux 8 and 9 (primary); Ubuntu 22.04 and 24.04 (secondary). Both families are explicitly declared in `metadata.json` `operatingsystem_support`. The `puppetlabs-apt` dependency in the `Puppetfile` confirms active Ubuntu/Debian support. Ansible tasks must branch on `ansible_os_family` (`RedHat` vs. `Debian`) for package manager differences.
- **Virtual Machine Technology**: Not specified in the repository.
- **Cloud Platform**: Not specified in the repository.

---

## Migration Approach

### Key Dependencies to Address

- **puppetlabs-stdlib (9.6.0)**: Provides utility functions (e.g., `contain`, data validation). Replace with native Ansible module capabilities and Jinja2 filters; no direct Galaxy equivalent is needed.
- **puppet-redis (11.0.0)**: Wraps Redis package installation, service management, and `redis.conf` generation. Replace with `ansible.builtin.package` (with OS-family branching for `redis` vs. `redis-server` package names), `ansible.builtin.template` for `redis.conf.j2`, and `ansible.builtin.service` for service lifecycle management.
- **puppetlabs-apt (9.4.0)**: Manages APT source configuration on Ubuntu/Debian targets. Replace with `ansible.builtin.apt_repository` or the `geerlingguy.repo-epel` / distro-specific tasks as appropriate.
- **puppetdb_query() (PuppetDB API)**: Used for live cluster node discovery at compile time. Replace with Ansible dynamic inventory (e.g., a static group `redis_cluster` in inventory, or a dynamic inventory plugin) so that cluster peer lists are resolved before playbook execution rather than inside a task.

### Security Considerations

- **Hardcoded Redis password (`redis_password` default: `'CHANGEME'`)**: The `init.pp` class parameter default and the `redis.conf.erb` template both expose the Redis `requirepass` value as a plain-text string. During migration, this credential **must** be moved to Ansible Vault (`ansible-vault encrypt_string`) or a secrets manager integration (HashiCorp Vault via `community.hashi_vault`, AWS Secrets Manager, etc.). The variable should be referenced as `{{ redis_password }}` in the Jinja2 template and never committed in plaintext.
- **Redis bind address `0.0.0.0`**: Both `install.pp` and `redis.conf.erb` bind Redis on all interfaces. This should be reviewed and tightened to a specific management interface in the Ansible role variables, with the bind address exposed as a role variable defaulting to a safer value.
- **HTTP health-check endpoint (unauthenticated, `http://`)**: `myFunction1` and `myType1` target `http://localhost:8080/health` over plain HTTP with no authentication. When re-implementing as `ansible.builtin.uri` tasks, evaluate whether TLS and/or token-based authentication should be enforced.
- **Log directory permissions**: `/var/log/redis` is created with mode `0755`, owner/group `redis`. Replicate exactly with `ansible.builtin.file` and validate against the organisation's hardening baseline.
- **AOF + RDB persistence files**: `appendonly.aof` and `dump.rdb` are written to `/var/lib/redis`. Ensure the Ansible role enforces correct ownership (`redis:redis`) on that directory, consistent with the source module's intent.

### Technical Challenges

- **PuppetDB node-discovery → Ansible inventory**: The `puppetdb_query()` call dynamically enumerates all cluster members at Puppet catalog compile time. Ansible has no equivalent compile-time query mechanism. This must be redesigned: either use a dynamic inventory plugin (PuppetDB inventory plugin, cloud provider plugin, or a custom script) or maintain a static `[redis_cluster]` inventory group. This is the highest-complexity migration item and requires coordination with the team that owns inventory management.
- **Custom Facter fact (`redis_role`)**: The `redis_role` fact is set per-node at agent run time and may be consumed by other profiles or Hiera data in the broader control repo. In Ansible, replace with a task early in the play that uses `ansible.builtin.stat` to check for `/etc/redis/conf.d/replica.conf` and `ansible.builtin.set_fact` to set `redis_role`. Ensure any downstream consumers of this fact are identified before migration.
- **Custom Puppet function (`myFunction1`) and type/provider (`myType1`/`myProvider1`)**: These three Ruby extensions implement HTTP GET logic that is idiomatic in Puppet but trivially replaced by `ansible.builtin.uri`. The challenge is ensuring the same failure semantics (hard error on non-2xx) are preserved via `failed_when: response.status not in [200]` or equivalent.
- **ERB → Jinja2 template conversion**: `redis.conf.erb` uses `<%= @facts['networking']['fqdn'] %>` (Puppet facts syntax). The Ansible equivalent is `{{ ansible_fqdn }}`. All ERB interpolation tags must be systematically converted; a line-by-line review of the template is required to catch any conditional blocks (`<% if %>`) that may be added in future.
- **OS-family branching**: The module currently relies on `puppet-redis` to abstract RedHat vs. Debian package differences. In Ansible, this abstraction must be made explicit — either via `vars/RedHat.yml` / `vars/Debian.yml` variable files loaded with `ansible.builtin.include_vars`, or via `when: ansible_os_family == 'RedHat'` task conditionals.
- **`contain` vs. Ansible role structure**: Puppet's `contain` ensures the `install` subclass is scoped within the profile. In Ansible, this maps naturally to task includes (`ansible.builtin.include_tasks`) or a flat task list within the role's `tasks/main.yml`. No functional risk, but the structural mapping must be documented for the team.

### Migration Order

1. **Jinja2 template (`redis.conf.j2`)** — Low risk, high value. Convert `redis.conf.erb` to Jinja2 first; this is self-contained and validates the variable interface before any task logic is written.
2. **Core installation and configuration tasks** — Translate `install.pp` into `tasks/main.yml`: package install (with OS-family branching), template deployment, log directory creation, and service management. Wire in Ansible Vault for `redis_password`.
3. **Health-check tasks (replacing `myFunction1` + `myType1`/`myProvider1`)** — Implement `ansible.builtin.uri` tasks with appropriate `failed_when` conditions. Low complexity once the core tasks are in place.
4. **`redis_role` fact replacement** — Add a pre-task or early role task that sets `redis_role` via `ansible.builtin.stat` + `ansible.builtin.set_fact`. Validate that no other roles or playbooks in the broader estate depend on this fact before removing the Facter source.
5. **Inventory / node-discovery redesign (replacing `puppetdb_query()`)** — Highest complexity; requires cross-team coordination. Design and validate the dynamic inventory strategy independently of the role tasks, then integrate.
6. **End-to-end integration testing** — Run the completed role against both RHEL 9 and Ubuntu 22.04 test instances (Molecule recommended) before promoting to production.

### Assumptions

1. This repository is a **standalone Puppet module**, not a control repo. There is no `environment.conf`, `hiera.yaml`, or `site/` directory present. It is assumed the module is consumed by a separate control repo whose Hiera data and other profiles are out of scope for this migration.
2. The `puppetdb_query()` call is assumed to be used **solely for cluster peer discovery** within this module. If the result is passed to Redis replication configuration (e.g., `replicaof` directives), that logic is not visible in the reviewed files and must be confirmed before finalising the inventory design.
3. The `redis_role` Facter fact is assumed to be **consumed only within this module or its direct dependents**. If it is referenced in Hiera keys or other profiles in the control repo, those consumers must be identified and migrated in parallel.
4. The `myFunction1` function and `myType1` type are assumed to be **local to this module** (no cross-module usage). Their names suggest placeholders; the actual production names should be confirmed with the Platform Team before migration.
5. The health-check target `http://localhost:8080/health` is assumed to be a **sidecar or application process** running on the Redis node. Its identity and availability during Ansible runs must be confirmed — if it is not guaranteed to be up during provisioning, the health-check task may need a `retries`/`delay` loop or a `ignore_errors` guard.
6. **No Hiera-encrypted secrets** are present in this repository. The only credential is the `redis_password` default value in `init.pp`. It is assumed that in the live environment this default is overridden by Hiera (possibly with `eyaml` encryption). The actual production secret storage mechanism must be confirmed with the Platform Team to select the correct Ansible Vault / secrets-manager integration.
7. The `puppetlabs-apt` dependency is assumed to be used **transitively** by `puppet-redis` for Ubuntu APT source management, not directly by this profile. If the profile directly manages APT sources, additional tasks will be required.
8. **Molecule** (or an equivalent Ansible testing framework) is assumed to be available for integration testing. If not, the testing strategy must be agreed upon before migration begins.
9. The target Ansible version is assumed to be **Ansible Core 2.15+**, which provides all required modules (`ansible.builtin.uri`, `ansible.builtin.template`, `ansible.builtin.package`, `ansible.builtin.service`, `ansible.builtin.file`, `ansible.builtin.set_fact`, `ansible.builtin.stat`).
10. The migrated Ansible role will follow the **standard role directory layout** (`tasks/`, `templates/`, `vars/`, `defaults/`, `handlers/`). The role name will be `redis_cluster` or equivalent, to be confirmed with the Platform Team.
