---
source-path: manifests
---

# Migration Plan: profile_redis_cluster (role::redis_cluster)

**TLDR**: This module provisions a Redis cluster node on Linux. It applies a base OS profile (NTP, syslog, utility packages, MOTD), then installs and configures a Redis server with authentication, memory limits, and append-only persistence. It also deploys a companion application artifact (`myapp`), registers the node with a proprietary Enterprise Scheduler, performs a health-check HTTP call, and writes the result to a JSON file. Two custom types (`myDeploy1`, `mySecretType1`) and two custom functions (`myFunction1`, `mySecretFunction1`) are involved — one of each is safely convertible to Ansible built-ins, while the other pair requires developer investigation before migration can proceed.

---

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **Redis server**: single Redis instance per node, acting as either primary or replica (determined by `redis_role` custom fact)
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Password: `CHANGEME` (plaintext default — must be replaced with a secure value)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Append-only persistence: enabled, fsync: `everysec`
  - Log directory: `/var/log/redis`
- **myapp companion application**: deployed to `/opt/myapp`, version `2.1.0`, downloaded from `http://artifacts.internal/myapp-2.1.0.tar.gz`
- **Health check endpoint**: `http://localhost:8080/health` — result written to `/var/lib/redis/health_check.json`
- **Enterprise Scheduler registration**: node registered as `redis-node` with schedule `daily` via `schedulerctl` CLI

---

## File Structure

```
../../site/role/manifests/redis_cluster.pp
../../site/profile/manifests/cache/redis.pp
../../site/profile/manifests/base/base.pp
../../site/modules/common/base_utils/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/install.pp
lib/puppet/type/myCronType1.rb
lib/puppet/type/myDeploy1.rb
lib/puppet/type/myFormatType1.rb
lib/puppet/type/mySecretType1.rb
lib/puppet/provider/myCronType1/myCronProvider1.rb
lib/puppet/provider/myDeploy1/myDeployProvider.rb
lib/puppet/provider/myFormatType1/myFormatProvider1.rb
lib/puppet/provider/mySecretType1/mySecretProvider1.rb
lib/facter/redis_role.rb
lib/puppet/functions/myFunction1.rb
lib/puppet/functions/mySecretFunction1.rb
```

---

## Module Explanation

The module performs operations in this order:

**IMPORTANT: Full paths from the File Structure section are used throughout.**

1. **role::redis_cluster** (`../../site/role/manifests/redis_cluster.pp`):
   - Conditional `if $facts['kernel'].downcase == 'linux'` (evaluates `true` on Linux targets): sets `Exec { path => '/usr/bin:/bin:/usr/sbin:/sbin' }` as default PATH for all `exec` resources in scope
   - `include ::profile::base::base` — included (not contained); triggers base OS setup
   - `contain ::profile::cache::redis` — contained; triggers Redis cluster setup
   - Ordering: `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base profile completes before Redis profile starts

2. **profile::base::base** (`../../site/profile/manifests/base/base.pp`):
   - Parameters resolved from `lookup()` with inline defaults (no Hiera data files found): `$manage_ntp` → `true`, `$manage_syslog` → `true`, `$manage_utils` → `true`
   - Conditional `if $manage_utils` (true): `include base_utils` → walks into **base_utils** class (see step 2a)
   - Conditional `if $manage_ntp and $facts['kernel'] == 'Linux'` (true): installs package `chrony` (ensure: `installed`); manages service `chronyd` (ensure: `running`, enable: `true`)
   - Conditional `if $manage_syslog and $facts['kernel'] == 'Linux'` (true): installs package `rsyslog` (ensure: `installed`); manages service `rsyslog` (ensure: `running`, enable: `true`)

3. **base_utils** (`../../site/modules/common/base_utils/manifests/init.pp`):
   - Parameters resolved from `lookup()` with inline defaults: `$manage_motd` → `true`, `$motd_template` → `'base_utils/motd.erb'`, `$utility_packages` → `[]`
   - Conditional `if $manage_motd` (true): manages `file '/etc/motd'` (ensure: `file`, content: rendered from `base_utils/motd.erb` via `template()`, owner: `root`, group: `root`, mode: `0644`)
   - Loop `$utility_packages.each |$pkg|` — **runs 0 times** (empty array default, no Hiera override found); no packages installed via this loop

4. **profile::cache::redis** (`../../site/profile/manifests/cache/redis.pp`):
   - Parameter `$environment_name` resolved at runtime via `fact('environment')` custom function (returns Puppet environment name, e.g., `production`)
   - Instantiates `class { 'profile_redis_cluster': }` (see step 4a)

5. **profile_redis_cluster** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
   - Parameters (manifest defaults, no Hiera overrides found): `$redis_port` → `6379`, `$redis_password` → `'CHANGEME'` ⚠️ plaintext credential, `$maxmemory_mb` → `2048`, `$maxmemory_policy` → `'allkeys-lru'`
   - PuppetDB query: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }")` — queries PuppetDB for all nodes running this class; result used for cluster topology awareness
   - Custom function call: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET, returns parsed JSON or raw string body
   - Manages `file '/var/lib/redis/health_check.json'` (ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `$health_check`)
   - Custom type: `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp', ensure => present }` — downloads artifact tarball, extracts to `/opt/myapp`, writes `/opt/myapp/version.txt` containing `2.1.0`
   - Custom function call: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary internal secret store ⚠️ not safely convertible
   - Custom type: `mySecretType1 { 'redis-node': schedule => 'daily', ensure => present }` — registers node `redis-node` in Enterprise Scheduler with schedule `daily` via `schedulerctl register --schedule daily redis-node` ⚠️ not safely convertible
   - `contain profile_redis_cluster::install` — contained; runs Redis package install (see step 5a)

6. **profile_redis_cluster::install** (`../../site/modules/linux/profile_redis_cluster/manifests/install.pp`):
   - Instantiates `class { 'redis': bind => '0.0.0.0', port => 6379, requirepass => 'CHANGEME', maxmemory => '2048mb', appendonly => true, appendfsync => 'everysec', manage_package => true }` — external/unanalyzed Redis module (not in repo)
   - Manages `file '/var/log/redis'` (ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`)

---

## Variables

**Variable Flow Summary**: 11 variables across manifest parameter defaults only. No Hiera data files were found in the repository. All `lookup()` calls fall back to their inline defaults.

### Variable Definitions

**Manifest parameter defaults (no Hiera data present)** → Migration note: All values are inline defaults from manifest `lookup()` calls; no Hiera hierarchy exists to migrate. These values should be placed in Ansible group_vars or role defaults.

- `profile::base::base::manage_ntp`: `true` (type: Boolean) — sourced from `lookup('profile::base::manage_ntp', Boolean, 'first', true)`
- `profile::base::base::manage_syslog`: `true` (type: Boolean) — sourced from `lookup('profile::base::manage_syslog', Boolean, 'first', true)`
- `profile::base::base::manage_utils`: `true` (type: Boolean) — sourced from `lookup('profile::base::manage_utils', Boolean, 'first', true)`
- `base_utils::manage_motd`: `true` (type: Boolean) — sourced from `lookup('base_utils::manage_motd', Boolean, 'first', true)`
- `base_utils::motd_template`: `'base_utils/motd.erb'` (type: String) — sourced from `lookup('base_utils::motd_template', String, 'first', 'base_utils/motd.erb')`
- `base_utils::utility_packages`: `[]` (type: Array[String]) — sourced from `lookup('base_utils::utility_packages', Array[String], 'first', [])`
- `profile_redis_cluster::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster::redis_password`: `'CHANGEME'` (type: String) ⚠️ plaintext, insecure default — must be replaced before any deployment
- `profile_redis_cluster::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster::maxmemory_policy`: `'allkeys-lru'` (type: String)
- `profile::cache::redis::environment_name`: runtime value of `fact('environment')` (type: String) — not a Hiera-sourced default; resolved at catalog compile time from the Puppet environment name (e.g., `production`, `staging`)

### Variable Migration Summary

- **Common defaults**: 11 variables (all from manifest defaults; no Hiera files present — 10 are inline `lookup()` defaults, 1 is a runtime fact value)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables (credentials stored as plaintext — `CHANGEME` default)

### Cross-Level Overrides

No cross-level overrides detected. No Hiera data files found; all values come from manifest parameter defaults.

### Merge Strategy Notes

- All `lookup()` calls use `'first'` merge strategy (default) — first value found wins, no merging. No hash or deep merge strategies are in use.

---

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **What it does**: Manages a root crontab entry. Provider shells out to `crontab -l` (read) and `crontab -` (write). Supports `exists?`, `create` (appends `minute hour * * *` entry), and `destroy` (removes matching lines).
- **Note**: Defined in the module's `lib/` directory but **not referenced in the execution tree** for `role::redis_cluster`. Present in the module library but unused in this role.

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **What it does**: Manages an application deployment. Idempotency via `version.txt` sentinel file. Downloads artifact tarball, extracts to `install_dir`, writes `version.txt`. On `ensure: absent`, removes the install directory.
- **Used in execution tree**: `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }`

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **What it does**: Manages `!key=value` entries in a proprietary CompanyApp settings file at `/etc/company/app.conf`. Reads and writes lines in `!key=value` format while preserving comments, blank lines, and unrecognized `!`-prefixed lines.
- **Note**: Defined in the module's `lib/` directory but **not referenced in the execution tree** for `role::redis_cluster`. Present in the module library but unused in this role.

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **What it does**: Registers a server in a proprietary Enterprise Scheduler platform using the `schedulerctl` CLI (`schedulerctl register --schedule <schedule> <name>` / `schedulerctl unregister <name>` / `schedulerctl query <name>`).
- **Used in execution tree**: `mySecretType1 { 'redis-node': schedule => 'daily' }`

---

## Dependencies

**External module dependencies**: None (no Puppetfile found)

**Internal module dependencies**:
- `base_utils` — common utility packages and MOTD management (`../../site/modules/common/base_utils/`)
- `profile_redis_cluster` — Redis cluster profile (`../../site/modules/linux/profile_redis_cluster/`)
- `redis` — external Redis Puppet module (called inside `profile_redis_cluster::install`; not present in repo, not analyzed)

**System package dependencies**:
- `chrony` — NTP daemon
- `rsyslog` — syslog daemon
- Redis package (managed by the unanalyzed `redis` class with `manage_package => true`)

**Service dependencies**:
- `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base OS setup must complete before Redis cluster setup begins
- `profile_redis_cluster::install` is contained within `profile_redis_cluster` — install runs as part of the Redis cluster class

---

## Puppet Facts Used

- `$facts['kernel']` — used in `role::redis_cluster` to set default `Exec` PATH (Linux only), and in `profile::base::base` to gate NTP and syslog management; provides the OS kernel name (e.g., `Linux`)
- `fact('environment')` — used in `profile::cache::redis` to capture the Puppet environment name (e.g., `production`, `staging`) as `$environment_name`; this is a custom function call wrapping the built-in `$environment` variable
- `redis_role` (custom fact, `lib/facter/redis_role.rb`) — determines whether the node is a Redis `primary` or `replica` by checking for `/etc/redis/conf.d/replica.conf` and the string `replicaof` within it; Linux-only (confine constraint); **not directly referenced in the execution tree** but present in the module library

---

## Custom Types Used

- `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`
- `mySecretType1 { 'redis-node': schedule => 'daily' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`

---

## Custom Providers Used

- `myDeployProvider` — implements `myDeploy1`; used via `myDeploy1 { 'myapp': ... }` in `profile_redis_cluster`
- `mySecretProvider1` — implements `mySecretType1`; used via `mySecretType1 { 'redis-node': ... }` in `profile_redis_cluster`

---

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; fetches secret `redis_service_token` from proprietary internal secret store; result stored in `$service_token` (likely passed to `mySecretType1` or used in a template; downstream usage not visible in the execution tree)
- `fact('environment')` — called in `../../site/profile/manifests/cache/redis.pp`; returns the current Puppet environment name
- `template('base_utils/motd.erb')` — called in `../../site/modules/common/base_utils/manifests/init.pp`; renders the MOTD template to produce `/etc/motd` content

---

## Custom Component Conversion Decisions

### myCronType1 + myCronProvider1
- **Conversion**: Existing Ansible modules
- **Mapping**: `ansible.builtin.cron`
  ```yaml
  - name: Manage cron entry
    ansible.builtin.cron:
      name: "{{ cron_name }}"
      job: "{{ command }}"
      hour: "{{ hour | default('2') }}"
      minute: "{{ minute | default('30') }}"
      user: root
      state: present   # or absent
  ```
- **Note**: Not used in this role's execution tree; include only if other roles reference it.

### myDeploy1 + myDeployProvider
- **Conversion**: Existing Ansible modules
- **Mapping**: Combination of `ansible.builtin.stat` (idempotency check via `version.txt`), `ansible.builtin.file` (create directory), `ansible.builtin.get_url` (download artifact), `ansible.builtin.unarchive` (extract tar.gz), `ansible.builtin.copy` (write `version.txt`), and `ansible.builtin.file` with `state: absent` (removal path).
  ```yaml
  - name: Check deployed version
    ansible.builtin.stat:
      path: /opt/myapp/version.txt
    register: version_file

  - name: Read current version
    ansible.builtin.slurp:
      src: /opt/myapp/version.txt
    register: current_version
    when: version_file.stat.exists

  - name: Deploy myapp artifact
    when: not version_file.stat.exists or (current_version.content | b64decode | trim) != '2.1.0'
    block:
      - name: Ensure install directory exists
        ansible.builtin.file:
          path: /opt/myapp
          state: directory
          mode: '0755'

      - name: Download artifact
        ansible.builtin.get_url:
          url: http://artifacts.internal/myapp-2.1.0.tar.gz
          dest: /tmp/myapp-2.1.0.tar.gz

      - name: Extract artifact
        ansible.builtin.unarchive:
          src: /tmp/myapp-2.1.0.tar.gz
          dest: /opt/myapp
          remote_src: true

      - name: Write version sentinel
        ansible.builtin.copy:
          content: "2.1.0"
          dest: /opt/myapp/version.txt
  ```

### myFormatType1 + myFormatProvider1
- **Conversion**: Custom Ansible module needed — flagged for developer review
- **Reason**: Manages entries in a proprietary `!key=value` CompanyApp settings format at `/etc/company/app.conf`. No standard Ansible module handles this format natively.
- **Required behavior**: The custom Ansible module must read and write `!key=value` lines in `/etc/company/app.conf` while preserving comments, blank lines, and unrecognized `!`-prefixed lines. It must support `state: present` (upsert a `!key=value` entry) and `state: absent` (remove a matching `!key=value` line). The module must be idempotent.
- **Interface**:
  - `path` (string, required): path to the settings file (default: `/etc/company/app.conf`)
  - `key` (string, required): the key portion of the `!key=value` entry
  - `value` (string, required for `present`): the value portion
  - `state` (string, default `present`): `present` or `absent`
- **Note**: This type is **not used in this role's execution tree** but is present in the module library. The automation developer must implement this Python module before any role that references `myFormatType1` can be migrated.

### mySecretType1 + mySecretProvider1
- **Conversion**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: Wraps the proprietary `schedulerctl` CLI (`/usr/local/bin/schedulerctl`). The CLI's subcommand semantics (`query`, `register --schedule`, `unregister`), output format, exit codes, and `--schedule` parameter format are entirely undocumented. The automation developer must obtain `schedulerctl` documentation or binary access before implementing equivalent tasks.

### redis_role (custom fact)
- **Conversion**: Existing Ansible modules
- **Mapping**: Reproduce inline using `ansible.builtin.stat` to check for `/etc/redis/conf.d/replica.conf`, then `ansible.builtin.command` (grep) to check for the `replicaof` string. Register result as a variable:
  ```yaml
  - name: Check for replica config file
    ansible.builtin.stat:
      path: /etc/redis/conf.d/replica.conf
    register: replica_conf

  - name: Check for replicaof directive
    ansible.builtin.command: grep -q replicaof /etc/redis/conf.d/replica.conf
    register: replicaof_check
    failed_when: false
    changed_when: false
    when: replica_conf.stat.exists

  - name: Set redis_role fact
    ansible.builtin.set_fact:
      redis_role: "{{ 'replica' if (replica_conf.stat.exists and replicaof_check.rc == 0) else 'primary' }}"
  ```

### myFunction1
- **Conversion**: Existing Ansible modules
- **Mapping**: `ansible.builtin.uri`
  ```yaml
  - name: Perform health check
    ansible.builtin.uri:
      url: http://localhost:8080/health
      method: GET
      return_content: true
    register: health_check_result
  # Use health_check_result.json for parsed JSON, health_check_result.content for raw body
  ```

### mySecretFunction1
- **Conversion**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: Delegates entirely to `CompanyInternal::SecretStore.fetch` from the proprietary `company_internal_lib` Ruby library. The backing secret store (Vault, AWS Secrets Manager, CyberArk, custom database, etc.) is unknown. The automation developer must identify what system `company_internal_lib` connects to and substitute the appropriate Ansible lookup plugin before this migration can proceed.

---

## Template Conversion Notes

### `base_utils/motd.erb`
- **Destination**: `/etc/motd`
- **Render count**: 1 (once per node)
- **Variables used**: Not directly visible in the analyzed manifests — the template file itself was not read. The template is referenced as `'base_utils/motd.erb'` and rendered via the `template()` function.
- **Migration note**: Locate `base_utils/motd.erb` in the `base_utils` module's `templates/` directory. Convert to a Jinja2 template (`.j2`) and deploy with `ansible.builtin.template`. Identify all `<%= @variable %>` and `<% if ... %>` blocks and map them to Ansible variables.

---

## PuppetDB Dependencies

**Context**: PuppetDB provides a centralized data store for cross-node resource sharing, node facts, and infrastructure queries.

- **PuppetDB Query in `profile_redis_cluster`** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Returns: list of all certnames (hostnames) in the Puppet infrastructure that have the `profile_redis_cluster` class applied
  - Used as: `$redis_nodes` — represents the full cluster membership list for topology awareness
  - Migration note: PuppetDB queries have no direct Ansible equivalent. In Ansible, cluster membership must be managed through a static or dynamic inventory group (e.g., `[redis_cluster]`) listing all Redis nodes, using `groups['redis_cluster']` to enumerate cluster members, or a dynamic inventory plugin querying a CMDB or cloud provider for nodes with a specific tag or role. The `$redis_nodes` variable should be replaced with `groups['redis_cluster']` in Ansible playbooks and templates.

---

## Checks for the Migration

**Files to verify**:
- `/etc/motd` — MOTD file rendered from `base_utils/motd.erb`
- `/var/lib/redis/health_check.json` — health check result JSON, owned by `redis:redis`, mode `0644`
- `/var/log/redis` — log directory, owned by `redis:redis`, mode `0755`
- `/opt/myapp/version.txt` — deployment sentinel file containing `2.1.0`
- `/opt/myapp/` — extracted application artifact directory

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check endpoint: `curl http://localhost:8080/health` → should return JSON

**Templates rendered**:
- `base_utils/motd.erb` → `/etc/motd` (rendered once per node)

## Pre-flight checks:
```bash
# NTP daemon
systemctl status chronyd

# Syslog daemon
systemctl status rsyslog

# Redis service
systemctl status redis

# Redis replication role
redis-cli -p 6379 -a CHANGEME info replication

# Deployed myapp version
cat /opt/myapp/version.txt
# Expected: 2.1.0

# Redis log directory ownership and permissions
ls -la /var/log/redis

# Enterprise Scheduler registration
/usr/local/bin/schedulerctl query redis-node
# Note: requires schedulerctl to be available and documented

# Health check JSON
cat /var/lib/redis/health_check.json

# MOTD content
cat /etc/motd

# Security: confirm redis_password has been changed from CHANGEME default
grep -r 'CHANGEME' /etc/redis/

# Security: confirm mySecretFunction1 secret source has been identified
# and migrated to an appropriate Ansible lookup plugin before playbook execution
```