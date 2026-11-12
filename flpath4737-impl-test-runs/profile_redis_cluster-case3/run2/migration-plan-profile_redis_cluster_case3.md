---
source-path: .
---

# Migration Plan: profile_redis_cluster

**TLDR**: This module configures a Redis cluster node on Linux. It installs and configures the Redis service via a community `redis` class, manages a health-check JSON file, deploys a companion application artifact (`myapp` v2.1.0), registers the node with a proprietary Enterprise Scheduler platform, fetches a service token from a proprietary secret store, and ensures base OS services (NTP via chrony, syslog via rsyslog) are running. The role entry point is `role::redis_cluster`, which chains `profile::base::base` before `profile::cache::redis`, which in turn delegates entirely to the `profile_redis_cluster` module.

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **Redis**: single Redis node per host, acting as either primary or replica (determined by custom fact `redis_role`)
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Password: `CHANGEME` (hardcoded insecure default — must be replaced)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Append-only persistence: enabled, fsync: `everysec`
  - Log directory: `/var/log/redis`
- **myapp**: companion application deployed to `/opt/myapp`, version `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Health check endpoint: `http://localhost:8080/health`
  - Health check result written to: `/var/lib/redis/health_check.json`
- **Enterprise Scheduler registration**: node `redis-node` registered with schedule `daily` via proprietary `schedulerctl` CLI

## File Structure

```
../../site/role/manifests/redis_cluster.pp
../../site/profile/manifests/cache/redis.pp
../../site/profile/manifests/base/base.pp
../../site/modules/linux/profile_redis_cluster/manifests/init.pp
../../site/modules/linux/profile_redis_cluster/manifests/install.pp
lib/puppet/type/myDeploy1.rb
lib/puppet/type/mySecretType1.rb
lib/puppet/type/myCronType1.rb
lib/puppet/type/myFormatType1.rb
lib/puppet/provider/myDeploy1/myDeployProvider.rb
lib/puppet/provider/mySecretType1/mySecretProvider1.rb
lib/puppet/provider/myCronType1/myCronProvider1.rb
lib/puppet/provider/myFormatType1/myFormatProvider1.rb
lib/puppet/functions/myFunction1.rb
lib/puppet/functions/mySecretFunction1.rb
lib/facter/redis_role.rb
../../data/common.yaml
../../data/environment/production.yaml
../../data/environment/staging.yaml
../../test/data/common.yaml
```

## Module Explanation

The module performs operations in this order:

**IMPORTANT: Full paths from the File Structure section are used throughout.**

1. **role::redis_cluster** (`../../site/role/manifests/redis_cluster.pp`):
   - Conditional (kernel == `linux`): sets default `Exec` resource `path` to `/usr/bin:/bin:/usr/sbin:/sbin` for all `exec` resources in the catalog
   - `include ::profile::base::base` — included (not contained; runs independently)
   - `contain ::profile::cache::redis` — contained
   - Sets ordering: `Class['::profile::base::base'] -> Class['::profile::cache::redis']`

2. **profile::base::base** (`../../site/profile/manifests/base/base.pp`):
   - Parameters resolved from Hiera (all keys absent from all data files → fall back to manifest defaults):
     - `$manage_ntp` = `true`
     - `$manage_syslog` = `true`
     - `$manage_utils` = `true`
   - Conditional (`$manage_utils` = `true`): `include base_utils` — class not analyzed; assumed to install common utility packages
   - Conditional (`$manage_ntp` = `true` AND kernel == `Linux`):
     - `package 'chrony'` → ensure: `installed`
     - `service 'chronyd'` → ensure: `running`, enable: `true`
   - Conditional (`$manage_syslog` = `true` AND kernel == `Linux`):
     - `package 'rsyslog'` → ensure: `installed`
     - `service 'rsyslog'` → ensure: `running`, enable: `true`

3. **profile::cache::redis** (`../../site/profile/manifests/cache/redis.pp`):
   - Parameter: `$environment_name` = result of `fact('environment')` (Puppet environment name at catalog compile time, e.g., `production`)
   - `class { 'profile_redis_cluster': }` — instantiates the module with all defaults (no parameter overrides passed)

4. **profile_redis_cluster** (`../../site/modules/linux/profile_redis_cluster/manifests/init.pp`):
   - Parameters (all resolved from manifest defaults — no Hiera overrides present):
     - `$redis_port` = `6379`
     - `$redis_password` = `'CHANGEME'`
     - `$maxmemory_mb` = `2048`
     - `$maxmemory_policy` = `'allkeys-lru'`
   - PuppetDB query: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }")` — fetches list of all certnames that have the `Profile_redis_cluster` class applied; result stored in `$redis_nodes` for cluster topology awareness
   - Custom function call: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body (or raw string on parse failure)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `myFunction1('http://localhost:8080/health')`
   - `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
   - Custom function call: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary `CompanyInternal::SecretStore`; value stored in `$service_token`
   - `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present` — registers this node in the Enterprise Scheduler platform via `schedulerctl register redis-node --schedule daily`
   - `contain profile_redis_cluster::install`

5. **profile_redis_cluster::install** (`../../site/modules/linux/profile_redis_cluster/manifests/install.pp`):
   - `class { 'redis': }` (community Redis class — not analyzed, parameters passed):
     - `bind` = `'0.0.0.0'`
     - `port` = `6379` (from `$profile_redis_cluster::redis_port`)
     - `requirepass` = `'CHANGEME'` (from `$profile_redis_cluster::redis_password`)
     - `maxmemory` = `'2048mb'` (from `"${profile_redis_cluster::maxmemory_mb}mb"`)
     - `appendonly` = `true`
     - `appendfsync` = `'everysec'`
     - `manage_package` = `true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 15 target lookup keys; 0 resolved from Hiera data files; all 15 resolved from manifest parameter defaults. Hiera data files contain only unrelated keys (ntp, ssh, syslog, haproxy).

### Variable Definitions

**Manifest defaults (no Hiera overrides at any level)** → Migration note: All module parameters fall back to manifest defaults; no Hiera data files contribute values for this module's keys.

- `profile::base::manage_ntp`: `true` (type: Boolean) — controls chrony installation
- `profile::base::manage_syslog`: `true` (type: Boolean) — controls rsyslog installation
- `profile::base::manage_utils`: `true` (type: Boolean) — controls base_utils inclusion
- `profile_redis_cluster::redis_port`: `6379` (type: Integer) — Redis listen port
- `profile_redis_cluster::redis_password`: `'CHANGEME'` (type: String) — **INSECURE HARDCODED DEFAULT — must be replaced with a secret**
- `profile_redis_cluster::maxmemory_mb`: `2048` (type: Integer) — Redis maxmemory in MB
- `profile_redis_cluster::maxmemory_policy`: `'allkeys-lru'` (type: String) — Redis eviction policy
- `profile::cache::redis::environment_name`: result of `fact('environment')` at compile time (type: String) — Puppet environment name

**common.yaml (unrelated keys only)** → Migration note: No module keys present; these keys belong to other profiles and require no migration action for this module.

- `ntp::servers` (type: array) — unrelated
- `ssh::client_alive_interval` (type: Integer) — unrelated
- `ssh::permit_root_login` (type: String) — unrelated
- `syslog::server` (type: String) — unrelated
- `syslog::facility` (type: String) — unrelated

**environment/production.yaml (unrelated keys only)** → Migration note: Overrides for ntp and syslog; no module keys present.

- `ntp::servers` (type: array) — override of common.yaml value; unrelated
- `syslog::server` (type: String) — override of common.yaml value; unrelated
- `syslog::facility` (type: String) — override of common.yaml value; unrelated

**environment/staging.yaml (unrelated keys only)** → Migration note: Single syslog override; no module keys present.

- `syslog::server` (type: String) — override of common.yaml value; unrelated

**test/data/common.yaml (test-environment only)** → Migration note: Contains one eyaml-encrypted value for an unrelated profile; no module keys present.

- `profile_haproxy::stats_password`: `ENC[PKCS7,...]` (type: String, eyaml-encrypted) — test-only, unrelated to this module

### Variable Migration Summary

- **Common defaults**: 0 variables (all module keys absent from common.yaml)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable needing secure storage — `profile_haproxy::stats_password` (test env only, unrelated to this module); `redis_password` is plaintext `'CHANGEME'` and **must** be migrated to a vault/secret store before production use

### Cross-Level Overrides

- No cross-level overrides exist for any of the 15 target module keys
- `ntp::servers`: defined at common.yaml and production.yaml — unrelated to this module
- `syslog::server`: defined at common.yaml, production.yaml, and staging.yaml — unrelated to this module
- `syslog::facility`: defined at common.yaml and production.yaml — unrelated to this module

### Merge Strategy Notes

- No merge strategies are configured for this module's keys (all are scalar types resolved by `first` lookup)
- Variables using `first` (default) — first value found wins, no merging; applies to all 8 module parameter keys

## Custom Types and Providers

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Used in**: `profile_redis_cluster` init.pp — `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }`
- **What it does**: Checks `/opt/myapp/version.txt` for the current version; if absent or mismatched, creates `/opt/myapp`, downloads `http://artifacts.internal/myapp-2.1.0.tar.gz`, extracts with `tar -xzf`, writes `2.1.0` to `/opt/myapp/version.txt`. On `ensure: absent`, removes `/opt/myapp` entirely.

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Used in**: `profile_redis_cluster` init.pp — `mySecretType1 { 'redis-node': schedule => 'daily' }`
- **What it does**: Calls `/usr/local/bin/schedulerctl query redis-node` to check registration; calls `schedulerctl register redis-node --schedule daily` to create; calls `schedulerctl unregister redis-node` to destroy.

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Used in**: Not present in this execution tree. Declared in the module's `lib/` directory but not instantiated by any class in the role chain.

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Used in**: Not present in this execution tree. Declared in the module's `lib/` directory but not instantiated by any class in the role chain.

## Dependencies

**External module dependencies**: None (no Puppetfile found)

**Internal module dependencies**:
- `redis` community class (called from `profile_redis_cluster::install`) — not analyzed; assumed to install the `redis` package, write `/etc/redis/redis.conf`, and manage the `redis` service
- `base_utils` class (called from `profile::base::base`) — not analyzed; assumed to install common OS utility packages

**System package dependencies**:
- `chrony` — NTP daemon
- `rsyslog` — syslog daemon
- `redis` — installed by the community `redis` class via `manage_package => true`

**Service dependencies** (ordering):
- `Class['::profile::base::base'] -> Class['::profile::cache::redis']` — base OS setup must complete before Redis cluster configuration begins

## Puppet Facts Used

- `$facts['kernel']` — used in `role::redis_cluster` to set default `Exec` path; used in `profile::base::base` to gate chrony and rsyslog management; used in `redis_role` custom fact confine. Provides the OS kernel name (e.g., `Linux`).
- `fact('environment')` — used in `profile::cache::redis` to capture the Puppet environment name (e.g., `production`, `staging`) at compile time.
- `redis_role` (custom fact, `lib/facter/redis_role.rb`) — determines whether this node is a Redis `primary` or `replica` by checking existence of `/etc/redis/conf.d/replica.conf` and whether it contains the string `replicaof`. Available as `$facts['redis_role']`. Only evaluated on Linux.

## Custom Types Used

- `myDeploy1 { 'myapp': version => '2.1.0', url => 'http://artifacts.internal/myapp-2.1.0.tar.gz', install_dir => '/opt/myapp' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`
- `mySecretType1 { 'redis-node': schedule => 'daily' }` — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`

## Custom Providers Used

- `myDeployProvider` (`lib/puppet/provider/myDeploy1/myDeployProvider.rb`) — implements `myDeploy1`; used for the `myapp` deployment resource in `profile_redis_cluster` init.pp
- `mySecretProvider1` (`lib/puppet/provider/mySecretType1/mySecretProvider1.rb`) — implements `mySecretType1`; used for the `redis-node` scheduler registration resource in `profile_redis_cluster` init.pp

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`; fetches secret `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token`
- `fact('environment')` — called in `../../site/profile/manifests/cache/redis.pp`; returns the current Puppet environment name as a string

## Custom Component Conversion Decisions

### myDeploy1 + myDeployProvider → Existing Ansible modules

Map to the following task sequence:

```yaml
- name: Read installed version of myapp
  ansible.builtin.slurp:
    src: /opt/myapp/version.txt
  register: installed_version_raw
  ignore_errors: true

- name: Set installed version fact
  ansible.builtin.set_fact:
    myapp_installed_version: "{{ installed_version_raw.content | default('') | b64decode | trim }}"

- name: Create install directory /opt/myapp
  ansible.builtin.file:
    path: /opt/myapp
    state: directory
    mode: '0755'
  when: myapp_installed_version != '2.1.0'

- name: Download myapp artifact
  ansible.builtin.get_url:
    url: http://artifacts.internal/myapp-2.1.0.tar.gz
    dest: /tmp/myapp-2.1.0.tar.gz
  when: myapp_installed_version != '2.1.0'

- name: Extract myapp artifact
  ansible.builtin.unarchive:
    src: /tmp/myapp-2.1.0.tar.gz
    dest: /opt/myapp
    remote_src: yes
  when: myapp_installed_version != '2.1.0'

- name: Write version file
  ansible.builtin.copy:
    content: "2.1.0"
    dest: /opt/myapp/version.txt
  when: myapp_installed_version != '2.1.0'
```

### mySecretType1 + mySecretProvider1 → NOT SAFELY CONVERTIBLE — flagged for developer review

This type registers the node `redis-node` with schedule `daily` in a proprietary Enterprise Scheduler platform via the `schedulerctl` CLI at `/usr/local/bin/schedulerctl`. The CLI's subcommands (`query`, `register`, `unregister`), `--schedule` flag semantics, exit codes, and the underlying platform are entirely undocumented and proprietary. No existing Ansible module or combination of modules can reproduce this behavior.

**What the automation developer must do before conversion**:
1. Obtain the source or documentation for `/usr/local/bin/schedulerctl`
2. Identify the Enterprise Scheduler platform's interface (REST API, SDK, or CLI contract)
3. Determine exit codes for `query` (exists vs. not-registered vs. error)
4. Only then decide: wrap with `ansible.builtin.command` tasks, use `ansible.builtin.uri` against a REST API, or write a custom Ansible module

### myCronType1 + myCronProvider1 → Existing Ansible modules (not used in this execution tree)

If instantiated elsewhere, map directly to `ansible.builtin.cron`:

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

### myFormatType1 + myFormatProvider1 → Custom Ansible module required (not used in this execution tree)

The provider manages entries in a proprietary `!key=value` file format at `/etc/company/app.conf`. No standard Ansible module handles this format safely. A custom module is required with the following specification:

**Module name**: `company_app_conf` (suggested)

**Parameters**:
- `file` (string, default: `/etc/company/app.conf`) — path to the settings file
- `entry` (string, required) — the key name (must not be empty)
- `value` (string, required for `state: present`) — the desired value
- `state` (enum: `present`/`absent`, default: `present`)

**Behavior**:
- Read all lines from `file` (treat missing file as empty)
- Lines starting with `#` are comments — leave untouched
- Lines starting with `!` followed by `key=value` are managed entries — parse by stripping `!`, splitting on first `=`, trimming whitespace from key and value
- For `state: present`: if `!entry=value` already exists with exact target value → no change; otherwise remove any existing line with matching key and append `!entry=value`
- For `state: absent`: if no line with matching key exists → no change; otherwise remove all matching lines and rewrite file
- Rewrite entire file only when a change is needed
- Handle missing files gracefully (create on write); report I/O errors as module failures
- Return standard `changed` flag

### myFunction1 → Existing Ansible modules

Map to `ansible.builtin.uri`:

```yaml
- name: Fetch health check from http://localhost:8080/health
  ansible.builtin.uri:
    url: http://localhost:8080/health
    method: GET
    return_content: yes
    status_code: "2xx"
  register: health_check_result

- name: Write health check JSON to /var/lib/redis/health_check.json
  ansible.builtin.copy:
    content: "{{ health_check_result.json | to_json }}"
    dest: /var/lib/redis/health_check.json
    owner: redis
    group: redis
    mode: '0644'
```

### mySecretFunction1 → NOT SAFELY CONVERTIBLE — flagged for developer review

This function calls `CompanyInternal::SecretStore.fetch('redis_service_token')` from the proprietary `company_internal_lib` Ruby library. The secrets backend, authentication mechanism, network dependencies, and error semantics are entirely opaque — no source is available.

**What the automation developer must do before conversion**:
1. Identify what `CompanyInternal::SecretStore` connects to (HashiCorp Vault, AWS Secrets Manager, CyberArk, a custom HTTP API, etc.)
2. Once the backend is known, select the appropriate Ansible lookup plugin (e.g., `community.hashi_vault.hashi_vault`, `amazon.aws.aws_secret`, or a custom lookup plugin)
3. Apply `no_log: true` to any task that consumes the returned secret value to prevent exposure in logs

### redis_role custom fact → Existing Ansible modules

Reproduce in Ansible using:

```yaml
- name: Check if replica.conf exists
  ansible.builtin.stat:
    path: /etc/redis/conf.d/replica.conf
  register: replica_conf_stat

- name: Read replica.conf if present
  ansible.builtin.slurp:
    src: /etc/redis/conf.d/replica.conf
  register: replica_conf_content
  when: replica_conf_stat.stat.exists

- name: Set redis_role fact
  ansible.builtin.set_fact:
    redis_role: >-
      {{ 'replica' if (replica_conf_stat.stat.exists and
         (replica_conf_content.content | b64decode) is search('replicaof'))
         else 'primary' }}
```

## PuppetDB Dependencies

**Context**: PuppetDB provides a centralized data store for cross-node resource sharing, node facts, and infrastructure queries.

- **PuppetDB Query** — declared in `../../site/modules/linux/profile_redis_cluster/manifests/init.pp`:
  - Exact query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster' }`
  - Returned data: list of all certnames (hostnames) in the Puppet infrastructure that have the `Profile_redis_cluster` class applied
  - Result stored in: `$redis_nodes`
  - Usage: `$redis_nodes` is populated but no explicit downstream resource in the visible execution tree consumes it directly (no `.each` loop, no template reference); likely used for cluster topology awareness or passed to the community `redis` class for cluster peer configuration
  - Migration note: PuppetDB queries have no direct Ansible equivalent. The cluster node list must be managed via Ansible inventory groups. Replace `$redis_nodes` with the Ansible inventory group `redis_cluster` (or equivalent). Any logic that iterates over `$redis_nodes` must be rewritten to iterate over `groups['redis_cluster']`.

## Credentials

- **`redis_password`** (`profile_redis_cluster::redis_password`): Hardcoded plaintext default `'CHANGEME'` in the manifest. **Critical security issue.** Must be migrated to a vault secret (e.g., `ansible_vault`, HashiCorp Vault lookup, or AWS Secrets Manager) before production use. Apply `no_log: true` to any task that passes this value to Redis configuration.
- **`redis_service_token`**: Fetched at compile time via `mySecretFunction1('redis_service_token')` from `CompanyInternal::SecretStore`. Backend is unknown — see conversion decision for `mySecretFunction1` above.
- **`profile_haproxy::stats_password`**: eyaml-encrypted (`ENC[PKCS7,...]`) in `../../test/data/common.yaml`. Test-environment only; unrelated to this module. Migrate using `ansible-vault encrypt_string` or equivalent if the HAProxy profile is also being migrated.

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned by `redis:redis`, mode `0644`, contains valid JSON from `http://localhost:8080/health`
- `/var/log/redis` — exists as directory, owned by `redis:redis`, mode `0755`
- `/opt/myapp/version.txt` — exists, contains `2.1.0`
- `/opt/myapp` — directory exists with extracted artifact contents
- `/etc/redis/redis.conf` (or equivalent path managed by community `redis` class) — contains `bind 0.0.0.0`, `port 6379`, `requirepass CHANGEME`, `maxmemory 2048mb`, `appendonly yes`, `appendfsync everysec`

**Service endpoints to check**:
- Redis on port `6379`: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check endpoint: `curl -s http://localhost:8080/health` → should return valid JSON

**Templates rendered**: None — no `.erb` or `.epp` templates are used in this module. The only dynamic file content is the health check JSON written directly from the `myFunction1` return value.

## Pre-flight checks:

```bash
# Redis service status
systemctl status redis

# NTP daemon status (chrony)
systemctl status chronyd

# Syslog daemon status
systemctl status rsyslog

# Verify Redis is responding on port 6379
redis-cli -p 6379 -a CHANGEME ping

# Verify health check endpoint is reachable
curl -s http://localhost:8080/health

# Verify health check JSON file exists and is valid
cat /var/lib/redis/health_check.json | python3 -m json.tool

# Verify health check JSON file ownership and permissions
stat /var/lib/redis/health_check.json

# Verify Redis log directory exists with correct permissions
stat /var/log/redis

# Verify myapp deployment
cat /opt/myapp/version.txt

# Verify myapp directory exists
ls /opt/myapp

# Verify Enterprise Scheduler registration for redis-node
/usr/local/bin/schedulerctl query redis-node

# Verify node Redis role (primary or replica)
facter redis_role

# Validate Redis configuration file
grep -E 'bind|port|requirepass|maxmemory|appendonly|appendfsync' /etc/redis/redis.conf
```