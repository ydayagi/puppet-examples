---
source-path: .
---

# Migration Plan: profile_redis_cluster_case3

**TLDR**: This Puppet profile deploys a Redis node as part of a cluster. It installs and configures Redis (bind `0.0.0.0`, port `6379`, password-protected, AOF persistence, `2048mb` memory cap with `allkeys-lru` eviction), creates the log directory, performs a PuppetDB query to discover peer cluster nodes, fetches a health-check endpoint, deploys a companion application artifact (`myapp` v2.1.0), registers the node with a proprietary Enterprise Scheduler, and writes two entries to a proprietary CompanyApp settings file. Several custom types and functions are involved — some map cleanly to Ansible built-ins, others require custom modules or developer investigation before conversion can proceed.

## Service Type and Instances

**Service Type**: In-memory Cache / Data Store (Redis)

**Configured Instances**:
- **redis-server** (single node, cluster-aware):
  - Listen address: `0.0.0.0`
  - Port: `6379`
  - Auth: password `CHANGEME` (plaintext — must be vault-encrypted before production use)
  - Persistence: AOF (`appendonly yes`, `appendfsync everysec`), RDB snapshots (`save 900 1`, `save 300 10`, `save 60 10000`)
  - Memory: `2048mb`, policy `allkeys-lru`
  - Log file: `/var/log/redis/redis-server.log`
  - PID file: `/var/run/redis/redis-server.pid`
  - Data dir: `/var/lib/redis`

- **myapp** (companion application artifact):
  - Version: `2.1.0`
  - Install directory: `/opt/myapp`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`

## File Structure

```
profile_redis_cluster_case3/
├── manifests/
│   ├── init.pp                                          # entry class profile_redis_cluster_case3
│   └── install.pp                                       # profile_redis_cluster_case3::install
├── templates/
│   └── redis.conf.erb                                   # Redis main configuration file
└── lib/
    ├── facter/
    │   └── redis_role.rb                                # custom fact: primary vs replica
    ├── puppet/
    │   ├── functions/
    │   │   ├── myFunction1.rb                           # HTTP GET returning parsed JSON
    │   │   └── mySecretFunction1.rb                     # fetches secret from CompanyInternal::SecretStore
    │   ├── type/
    │   │   ├── myDeploy1.rb                             # application deployment type
    │   │   ├── myFormatType1.rb                         # CompanyApp settings entry type
    │   │   └── mySecretType1.rb                         # Enterprise Scheduler registration type
    │   └── provider/
    │       ├── myDeploy1/
    │       │   └── myDeployProvider.rb                  # deploy lifecycle (download, extract, version-track)
    │       ├── myFormatType1/
    │       │   └── myFormatProvider1.rb                 # !key=value file format manager
    │       └── mySecretType1/
    │           └── mySecretProvider1.rb                 # schedulerctl CLI wrapper

Hiera data (environment-level, no module-level data directory):
  ../../data/common.yaml
  ../../data/environment/production.yaml
  ../../data/environment/staging.yaml
```

## Module Explanation

The module performs operations in this order:

**IMPORTANT: Use FULL paths from the File Structure section (e.g., `manifests/config.pp` not just `config.pp`)**

1. **`profile_redis_cluster_case3`** (`manifests/init.pp`):
   - Declares class parameters with manifest defaults: `$redis_port = 6379`, `$redis_password = 'CHANGEME'`, `$maxmemory_mb = 2048`, `$maxmemory_policy = 'allkeys-lru'`
   - Calls `puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }")` → stores result in `$redis_nodes` for cluster peer discovery
   - Calls `myFunction1('http://localhost:8080/health')` → performs HTTP GET, returns parsed JSON; stores result in `$health_check`
   - Manages `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: `stdlib::to_json($health_check)`
   - Manages `myDeploy1 'myapp'` (custom type → `myDeployProvider`):
     - version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider **exists?**: reads `/opt/myapp/version.txt`; skips if content equals `2.1.0`
     - Provider **create – mkdir**: creates `/opt/myapp` directory
     - Provider **create – download**: fetches `http://artifacts.internal/myapp-2.1.0.tar.gz` → `/opt/myapp/artifact.tar.gz`
     - Provider **create – extract**: extracts `/opt/myapp/artifact.tar.gz` in-place
     - Provider **create – version tracking**: writes `2.1.0` to `/opt/myapp/version.txt`
     - Provider **destroy**: removes `/opt/myapp` entirely
   - Calls `mySecretFunction1('redis_service_token')` → fetches secret named `redis_service_token` from `CompanyInternal::SecretStore`; stores result in `$service_token` (downstream usage not visible in analyzed manifests — ⚠️ developer must trace all usages)
   - Manages `mySecretType1 'redis-node'` (custom type → `mySecretProvider1`):
     - schedule: `'daily'`, ensure: `present`
     - Provider **exists?**: runs `/usr/local/bin/schedulerctl query redis-node`
     - Provider **create**: runs `/usr/local/bin/schedulerctl register redis-node --schedule daily`
     - Provider **destroy**: runs `/usr/local/bin/schedulerctl unregister redis-node`
     - ⚠️ NOT SAFELY CONVERTIBLE — see Custom Component Conversion Decisions
   - Manages `myFormatType1 'app-mode'` (custom type → `myFormatProvider1`):
     - file: `/etc/company/app.conf`, value: `'cluster'`, ensure: `present`
     - Provider writes line `!app-mode=cluster` into `/etc/company/app.conf`
     - ⚠️ CUSTOM ANSIBLE MODULE NEEDED — see Custom Component Conversion Decisions
   - Manages `myFormatType1 'health-port'` (custom type → `myFormatProvider1`):
     - file: `/etc/company/app.conf`, value: `'8080'`, ensure: `present`
     - Provider writes line `!health-port=8080` into `/etc/company/app.conf`
     - ⚠️ CUSTOM ANSIBLE MODULE NEEDED — see Custom Component Conversion Decisions
   - Calls `contain profile_redis_cluster_case3::install` — contained subclass runs after all preceding resources in `init.pp`

2. **`profile_redis_cluster_case3::install`** (`manifests/install.pp`):
   - Invoked via `contain` from `manifests/init.pp` — runs after all resources in `init.pp` that precede the `contain` call
   - Declares `class { 'redis': ... }` (from `puppet-redis` 11.0.0 forge module) with:
     - bind: `'0.0.0.0'`, port: `6379`, requirepass: `'CHANGEME'`, maxmemory: `'2048mb'` (integer `2048` concatenated with `'mb'`), appendonly: `true`, appendfsync: `'everysec'`, manage_package: `true`
   - The `puppet-redis` module internally manages:
     - `package 'redis'` (or `redis-server` on Debian/Ubuntu) → ensure: `present`
     - `file '/etc/redis/redis.conf'` (rendered from `templates/redis.conf.erb`) → owner: `redis`, group: `redis`, mode: `0640`
       - Template variables: `@redis_port`=`6379`, `@redis_password`=`'CHANGEME'`, `@maxmemory_mb`=`2048`, `@maxmemory_policy`=`'allkeys-lru'`, `@facts['networking']['fqdn']`=node FQDN at runtime
     - `service 'redis'` (or `redis-server`) → ensure: `running`, enable: `true`
     - Notification chain: `file[redis.conf] ~> service[redis]`
   - Manages `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 variables across 1 effective Hiera level (all resolved from manifest class defaults — no Hiera data file overrides exist for any `profile_redis_cluster_case3::*` key)

### Variable Definitions

**Manifest class defaults** (`manifests/init.pp`) — effective values at runtime:
- `profile_redis_cluster_case3::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case3::redis_password`: `'CHANGEME'` (type: String — **plaintext credential, must be replaced with vault-encrypted value**)
- `profile_redis_cluster_case3::maxmemory_mb`: `2048` (type: Integer — rendered as `'2048mb'` when passed to Redis config)
- `profile_redis_cluster_case3::maxmemory_policy`: `'allkeys-lru'` (type: String)

**common.yaml** (`../../data/common.yaml`) → Migration note: Contains only unrelated NTP/SSH/syslog settings; no `profile_redis_cluster_case3::*` keys present — no overrides

**environment/production.yaml** (`../../data/environment/production.yaml`) → Migration note: No `profile_redis_cluster_case3::*` keys present — no overrides

**environment/staging.yaml** (`../../data/environment/staging.yaml`) → Migration note: No `profile_redis_cluster_case3::*` keys present — no overrides

### Variable Migration Summary

- **Common defaults**: 4 variables (all from manifest defaults)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable requiring secure storage (`redis_password` — currently plaintext `'CHANGEME'`)

**Target Ansible file**: `defaults/main.yml` only. No `group_vars/` or `host_vars/` files are needed.

**Critical string interpolation note**: `maxmemory_mb` is an Integer in Puppet but is always rendered as `"{{ redis_cluster_maxmemory_mb }}mb"` (e.g., `2048mb`) when written to `redis.conf`. Ansible templates must replicate this concatenation explicitly.

### Cross-Level Overrides

No cross-level overrides exist. All four variables are defined only at the manifest default level and are never overridden in any Hiera data file.

### Merge Strategy Notes

- Variables using `first` (default) — First value found wins, no merging. All four variables in this module use this strategy.

## Custom Types and Providers

### `myDeploy1` / `myDeployProvider`
- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Parameters**: `name` (namevar), `version` (non-empty String), `url` (HTTP/HTTPS URL), `install_dir` (String), `ensure` (present/absent, default: present)
- **Provider lifecycle**: idempotency via `version.txt`, mkdir, download via HTTP, tar.gz extract, version file write; destroy removes `install_dir`

### `myFormatType1` / `myFormatProvider1`
- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Parameters**: `entry` (namevar, non-empty String), `file` (default: `/etc/company/app.conf`), `value` (String), `ensure` (present/absent)
- **Format**: proprietary `!key=value` per-line syntax

### `mySecretType1` / `mySecretProvider1`
- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Parameters**: `name` (namevar), `schedule` (String), `ensure` (present/absent, default: present)
- **Provider lifecycle**: `schedulerctl query <name>` / `schedulerctl register <name> --schedule <schedule>` / `schedulerctl unregister <name>`

## Dependencies

**External module dependencies**:
- `puppetlabs-stdlib` 9.6.0 — provides `stdlib::to_json()` used in `manifests/init.pp`
- `puppet-redis` 11.0.0 — manages Redis package, config, and service
- `puppetlabs-apt` 9.4.0 — apt repository management (used by `puppet-redis` on Debian/Ubuntu)

**System package dependencies**:
- `redis` / `redis-server` — managed by `puppet-redis` module (`manage_package: true`)

**Service dependencies**:
- Redis service must start after config file is written (`file[redis.conf] ~> service[redis]`)
- `/var/log/redis` directory should exist before Redis service starts
- `myapp` artifact deployment is independent of Redis service ordering (no explicit `->` or `~>` to Redis)

## Puppet Facts Used

- `$facts['networking']['fqdn']` — used in `templates/redis.conf.erb` as a comment header identifying the node; provides the fully-qualified domain name of the target host at catalog compile time; Ansible equivalent: `ansible_fqdn`
- `kernel` (confine in `lib/facter/redis_role.rb`) — restricts the `redis_role` custom fact to Linux kernels only; Ansible equivalent: `ansible_kernel` or `ansible_os_family`

## Custom Types Used

- `myDeploy1 'myapp'` — declared in `manifests/init.pp`; parameters: version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`, ensure=`present`
- `myFormatType1 'app-mode'` — declared in `manifests/init.pp`; parameters: file=`/etc/company/app.conf`, value=`'cluster'`, ensure=`present`
- `myFormatType1 'health-port'` — declared in `manifests/init.pp`; parameters: file=`/etc/company/app.conf`, value=`'8080'`, ensure=`present`
- `mySecretType1 'redis-node'` — declared in `manifests/init.pp`; parameters: schedule=`'daily'`, ensure=`present`

## Custom Providers Used

- `myDeployProvider` — implements `myDeploy1`; used for `myDeploy1['myapp']` in `manifests/init.pp`
- `myFormatProvider1` — implements `myFormatType1`; used for both `myFormatType1['app-mode']` and `myFormatType1['health-port']` in `manifests/init.pp`
- `mySecretProvider1` — implements `mySecretType1`; used for `mySecretType1['redis-node']` in `manifests/init.pp`

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON (or raw string); result written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `manifests/init.pp`; fetches secret named `redis_service_token` from `CompanyInternal::SecretStore`; result stored in `$service_token` (downstream usage not visible in analyzed manifests — may be passed to a resource not shown, or may be unused)
- `stdlib::to_json($health_check)` — called in `manifests/init.pp`; serialises the health-check result to JSON string for the file content; provided by `puppetlabs-stdlib` 9.6.0

## Custom Component Conversion Decisions

### `myDeploy1` + `myDeployProvider` → Existing Ansible modules

Map to the following task sequence in Ansible:

```yaml
- name: Read version.txt (idempotency check)
  ansible.builtin.slurp:
    src: /opt/myapp/version.txt
  register: myapp_version_file
  ignore_errors: true

- name: Deploy myapp 2.1.0
  when: >
    myapp_version_file.failed or
    (myapp_version_file.content | b64decode | trim) != '2.1.0'
  block:
    - name: Ensure install directory exists
      ansible.builtin.file:
        path: /opt/myapp
        state: directory

    - name: Download artifact
      ansible.builtin.get_url:
        url: http://artifacts.internal/myapp-2.1.0.tar.gz
        dest: /opt/myapp/artifact.tar.gz

    - name: Extract artifact
      ansible.builtin.unarchive:
        src: /opt/myapp/artifact.tar.gz
        dest: /opt/myapp
        remote_src: true

    - name: Write version.txt
      ansible.builtin.copy:
        content: "2.1.0"
        dest: /opt/myapp/version.txt
```

For `ensure: absent`: use `ansible.builtin.file` with `state: absent` targeting `/opt/myapp`.

### `myFormatType1` + `myFormatProvider1` → Custom Ansible module required

A custom Ansible module must be written to manage `!key=value` entries in the proprietary CompanyApp settings file.

**Module name**: `company_app_conf` (suggested)

**Parameters**:
- `file` (str, required): Absolute path to the settings file (e.g., `/etc/company/app.conf`)
- `entry` (str, required): The key name to manage (matched against `!key=value` lines)
- `value` (str, required when `state=present`): The value to set
- `state` (str, default `present`): `present` to ensure the entry exists with the given value; `absent` to remove it

**Behavior**:
1. Read the file line by line (treat missing file as empty)
2. Parse each line: a valid entry starts with `!`, contains `=`, yields a stripped key and value
3. `state=present`: if a matching key line already exists with the correct value → no change (idempotent); otherwise remove all lines matching the key and append `!entry=value`
4. `state=absent`: remove all lines matching the key; if none exist → no change (idempotent)
5. Preserve all non-entry lines (comments `#`, blank lines, unrecognized lines) exactly as-is
6. Overwrite the file with the resulting lines
7. Raise a clear error if the file is not writable or cannot be read
8. Return `changed: true` only when file content is actually modified

**Invocations needed**:

```yaml
- company_app_conf:
    file: /etc/company/app.conf
    entry: app-mode
    value: cluster
    state: present

- company_app_conf:
    file: /etc/company/app.conf
    entry: health-port
    value: "8080"
    state: present
```

### `mySecretType1` + `mySecretProvider1` → NOT SAFELY CONVERTIBLE — flagged for developer review

The provider wraps the proprietary CLI tool `/usr/local/bin/schedulerctl` with subcommands `query`, `register`, and `unregister`. The semantics of these subcommands — expected output format, exit codes, side effects, authentication, and the Enterprise Scheduler platform's API — are fully opaque. No Ansible module or documented CLI wrapper exists for this tool.

**Action required**: The automation developer must:
1. Obtain documentation or source access for `schedulerctl` and the Enterprise Scheduler platform
2. Determine whether a REST API or Ansible collection exists for the scheduler
3. If only the CLI is available, implement an idempotent `ansible.builtin.command` task sequence that replicates `query`/`register`/`unregister` — but only after confirming exit codes and output format
4. Consider whether `ansible.builtin.command: /usr/local/bin/schedulerctl register redis-node --schedule daily` with a `creates:` guard is sufficient, or whether a full custom module is needed

### `myFunction1` → Existing Ansible modules

Replace with `ansible.builtin.uri`:

```yaml
- name: Fetch health check
  ansible.builtin.uri:
    url: http://localhost:8080/health
    method: GET
    return_content: true
  register: health_check_result

- name: Write health_check.json
  ansible.builtin.copy:
    content: "{{ health_check_result.json | to_json }}"
    dest: /var/lib/redis/health_check.json
    owner: redis
    group: redis
    mode: "0644"
```

If the endpoint returns non-JSON, fall back to `health_check_result.content`.

### `mySecretFunction1` → NOT SAFELY CONVERTIBLE — flagged for developer review

The function delegates entirely to `CompanyInternal::SecretStore.fetch`, a method from the proprietary `company_internal_lib` Ruby library. The library's authentication mechanism, backend (Vault? HSM? internal DB?), error handling, and return format are fully opaque.

**Action required**: The automation developer must:
1. Identify what backend `CompanyInternal::SecretStore` connects to
2. Check whether a corresponding Ansible lookup plugin already exists (e.g., `community.hashi_vault.hashi_vault`, `azure.azcollection.azure_keyvault_secret`, `amazon.aws.aws_secret`)
3. If the backend is custom, implement a `lookup_plugins/company_secret_store.py` Ansible lookup plugin
4. Note: `$service_token` is fetched but its downstream usage is not visible in the analyzed manifests — the developer must trace all usages before deciding on the conversion approach

### `redis_role` custom fact → Existing Ansible modules

Reproduce inline in Ansible:

```yaml
- name: Check replica.conf existence
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
         'replicaof' in (replica_conf_content.content | b64decode))
         else 'primary' }}
  when: ansible_kernel is defined
```

Alternatively, deploy a script to `/etc/ansible/facts.d/redis_role.fact` so that `ansible_local.redis_role` is populated automatically during fact gathering.

### `stdlib::to_json` → Existing Ansible modules

No custom conversion needed. Use the Jinja2 `to_json` filter directly: `"{{ health_check_result.json | to_json }}"`.

## Template Conversion Notes

### `templates/redis.conf.erb` → `templates/redis.conf.j2`

**Rendered**: once per node, to `/etc/redis/redis.conf` (managed by `puppet-redis`)

**Variables used**:
- `@facts['networking']['fqdn']` → `{{ ansible_fqdn }}` — used only in the comment header line
- `@redis_port` → `{{ redis_cluster_redis_port }}` (default: `6379`)
- `@redis_password` → `{{ redis_cluster_redis_password }}` (default: `CHANGEME` — **must be vaulted**)
- `@maxmemory_mb` → `{{ redis_cluster_maxmemory_mb }}` (default: `2048`) — rendered as `{{ redis_cluster_maxmemory_mb }}mb` (no space)
- `@maxmemory_policy` → `{{ redis_cluster_maxmemory_policy }}` (default: `allkeys-lru`)

**No Ruby logic blocks, conditionals, or iterations** — the template is purely substitution-based. Direct ERB-to-Jinja2 conversion is straightforward.

**Critical note**: The `maxmemory` line must render as `maxmemory 2048mb` — the `mb` suffix is appended directly to the integer value with no space. In Jinja2: `maxmemory {{ redis_cluster_maxmemory_mb }}mb`.

## PuppetDB Dependencies

**Exported resources**: None detected.

**Collectors**: None detected.

**`puppetdb_query()` calls** (1):
- **Query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }`
- **Location**: `manifests/init.pp`, stored in `$redis_nodes`
- **Purpose**: Discovers all certnames (hostnames) in the infrastructure that have this Redis profile applied — used for cluster peer discovery
- **Result usage**: `$redis_nodes` is assigned but its downstream usage within the analyzed manifests is not explicit (no resource in the analyzed files consumes it directly — it may be passed to a template or used in a conditional not shown)
- **Migration note**: PuppetDB queries have no direct Ansible equivalent. Recommended approach:
  1. Use Ansible inventory groups — all hosts in the Redis cluster should be members of a group (e.g., `redis_cluster`); peer addresses are then available as `groups['redis_cluster']`
  2. Alternatively, use a dynamic inventory plugin (e.g., AWS EC2, Consul, Netbox) that populates the group automatically
  3. The developer must identify exactly how `$redis_nodes` is consumed (template variable? conditional?) before finalizing the Ansible equivalent

## Checks for the Migration

**Files to verify**:
- `/etc/redis/redis.conf` — Redis main configuration (rendered from `templates/redis.conf.erb`)
- `/var/log/redis/` — log directory (owner: `redis`, group: `redis`, mode: `0755`)
- `/var/lib/redis/health_check.json` — health check output (owner: `redis`, group: `redis`, mode: `0644`)
- `/opt/myapp/version.txt` — artifact version tracking file (content: `2.1.0`)
- `/opt/myapp/` — extracted artifact directory
- `/etc/company/app.conf` — CompanyApp settings file (entries: `!app-mode=cluster`, `!health-port=8080`)

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → expect `PONG`
- Health check source: `curl -s http://localhost:8080/health` → expect JSON response

**Templates rendered**:
- `templates/redis.conf.erb` → `/etc/redis/redis.conf` — rendered **1 time** per node

## Pre-flight checks:

```bash
# Redis service status
systemctl status redis
systemctl status redis-server

# Redis connectivity and replication role
redis-cli -p 6379 -a CHANGEME ping
redis-cli -p 6379 -a CHANGEME info replication

# Redis configuration file presence
test -f /etc/redis/redis.conf && echo "redis.conf present" || echo "MISSING"

# Log directory
test -d /var/log/redis && ls -ld /var/log/redis || echo "MISSING /var/log/redis"

# Health check endpoint
curl -s http://localhost:8080/health

# Health check JSON file
test -f /var/lib/redis/health_check.json && cat /var/lib/redis/health_check.json || echo "MISSING health_check.json"

# myapp artifact deployment
cat /opt/myapp/version.txt
test -d /opt/myapp && ls /opt/myapp || echo "MISSING /opt/myapp"

# CompanyApp settings entries
grep -E '^!(app-mode|health-port)=' /etc/company/app.conf

# Enterprise Scheduler registration (requires schedulerctl present and functional)
/usr/local/bin/schedulerctl query redis-node

# Redis role fact (inline check)
test -f /etc/redis/conf.d/replica.conf && grep -q 'replicaof' /etc/redis/conf.d/replica.conf && echo "role: replica" || echo "role: primary"
```