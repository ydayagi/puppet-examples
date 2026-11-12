---
source-path: .
---

# Migration Plan: profile_redis_cluster_case3

**TLDR**: This Puppet profile installs and configures a Redis instance as part of a cluster topology. It uses the `puppet-redis` module to manage the Redis package and configuration, writes a health-check JSON file populated via an HTTP call, deploys a companion application artifact (`myapp`), registers the node with a proprietary Enterprise Scheduler, manages two entries in a proprietary CompanyApp settings file, schedules a Redis backup cron job, and creates a log directory. The entry class also performs a PuppetDB query to discover all cluster peers and retrieves a service token from a proprietary internal secrets library. Several custom types/providers are involved — some map cleanly to Ansible built-ins, others require custom modules or are not safely convertible without additional information.

## Service Type and Instances

**Service Type**: In-memory Cache / Redis Cluster Node

**Configured Instances**:
- **Redis server** (single node, cluster-aware via PuppetDB peer discovery):
  - Listen address: `0.0.0.0`
  - Port: `6379` (default; overridable via Hiera `profile_redis_cluster_case3::redis_port`)
  - Auth password: `CHANGEME` (plaintext placeholder — must be vault-encrypted before use)
  - Max memory: `2048mb` (default; overridable via `profile_redis_cluster_case3::maxmemory_mb`)
  - Max memory policy: `allkeys-lru` (default; overridable via `profile_redis_cluster_case3::maxmemory_policy`)
  - Persistence: AOF enabled (`appendonly yes`, `appendfsync everysec`), RDB snapshots enabled
  - Config file: managed by `puppet-redis` module (typically `/etc/redis/redis.conf`)
  - Log directory: `/var/log/redis`

- **myapp deployment**:
  - Version: `2.1.0`
  - Source URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`

- **Redis backup cron job**:
  - Command: `/usr/local/bin/redis-backup.sh`
  - Schedule: `02:30` daily

- **CompanyApp settings** (`/etc/company/app.conf`):
  - `app-mode` entry: `cluster`
  - `health-port` entry: `8080`

- **Enterprise Scheduler registration**:
  - Server name: `redis-node`
  - Schedule: `daily`

## File Structure

```
manifests/
  init.pp                                          — entry class profile_redis_cluster_case3
  install.pp                                       — profile_redis_cluster_case3::install

templates/
  redis.conf.erb                                   — Redis configuration file template

lib/
  puppet/
    type/
      myCronType1.rb                               — cron entry type
      myDeploy1.rb                                 — application deployment type
      myFormatType1.rb                             — proprietary CompanyApp settings file type
      mySecretType1.rb                             — Enterprise Scheduler registration type
    provider/
      myCronType1/
        myCronProvider1.rb                         — cron provider (shells out to crontab)
      myDeploy1/
        myDeployProvider.rb                        — deployment provider (download + extract + version file)
      myFormatType1/
        myFormatProvider1.rb                       — proprietary !key=value file provider
      mySecretType1/
        mySecretProvider1.rb                       — schedulerctl CLI provider
    functions/
      myFunction1.rb                               — HTTP GET returning parsed JSON or raw string
      mySecretFunction1.rb                         — proprietary internal secrets library wrapper
  facter/
    redis_role.rb                                  — determines primary vs replica role

data/
  ../../data/common.yaml                           — profile_redis_cluster_case3::* Hiera keys (no values; all sourced from manifest defaults)

metadata.json                                      — module metadata and dependency declarations
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case3** (`manifests/init.pp`):
   - Declares class parameters with manifest defaults: `$redis_port = 6379`, `$redis_password = 'CHANGEME'`, `$maxmemory_mb = 2048`, `$maxmemory_policy = 'allkeys-lru'`
   - Executes PuppetDB query at catalog compile time: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }` → stores result in `$redis_nodes` for cluster peer discovery
   - Calls `myFunction1('http://localhost:8080/health')` → stores parsed JSON or raw string in `$health_check`
   - Declares `file '/var/lib/redis/health_check.json'`: ensure=`file`, owner=`redis`, group=`redis`, mode=`0644`, content=JSON-serialized `$health_check`
   - Declares `myDeploy1 'myapp'`: version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`, ensure=`present`
   - Calls `mySecretFunction1('redis_service_token')` → stores result in `$service_token` (downstream use not visible in these manifests)
   - Declares `mySecretType1 'redis-node'`: schedule=`daily`, ensure=`present`
   - Declares `myFormatType1 'app-mode'`: file=`/etc/company/app.conf`, value=`cluster`, ensure=`present`
   - Declares `myFormatType1 'health-port'`: file=`/etc/company/app.conf`, value=`8080`, ensure=`present`
   - Declares `myCronType1 'redis-backup'`: command=`/usr/local/bin/redis-backup.sh`, hour=`2`, minute=`30`, ensure=`present`
   - Invokes `contain profile_redis_cluster_case3::install` (ordering enforced via containment)

2. **profile_redis_cluster_case3::install** (`manifests/install.pp`):
   - Invoked via `contain` from `init.pp`
   - Declares `class { 'redis': }` (from `puppet-redis` >= 11.0.0) with parameters:
     - `bind` = `'0.0.0.0'`
     - `port` = `6379`
     - `requirepass` = `'CHANGEME'`
     - `maxmemory` = `'2048mb'` (constructed as `"${maxmemory_mb}mb"`)
     - `appendonly` = `true`
     - `appendfsync` = `'everysec'`
     - `manage_package` = `true`
   - The `puppet-redis` module installs the `redis` package, renders `templates/redis.conf.erb` to `/etc/redis/redis.conf`, and manages the `redis` service
   - Declares `file '/var/log/redis'`: ensure=`directory`, owner=`redis`, group=`redis`, mode=`0755`

3. **redis.conf.erb** (`templates/redis.conf.erb`):
   - Rendered once per node by the `puppet-redis` module to `/etc/redis/redis.conf`
   - Variables passed: `@facts['networking']['fqdn']` (comment header only), `@redis_port`, `@redis_password`, `@maxmemory_mb`, `@maxmemory_policy`
   - Static values rendered: `bind 0.0.0.0`, `daemonize yes`, `pidfile /var/run/redis/redis-server.pid`, `logfile /var/log/redis/redis-server.log`, `loglevel notice`, `appendonly yes`, `appendfilename "appendonly.aof"`, `appendfsync everysec`, `auto-aof-rewrite-percentage 100`, `auto-aof-rewrite-min-size 64mb`, `save 900 1`, `save 300 10`, `save 60 10000`, `dbfilename dump.rdb`, `dir /var/lib/redis`, `tcp-backlog 511`, `timeout 0`, `tcp-keepalive 300`

## Variables

**Variable Flow Summary**: 4 variables, all sourced exclusively from manifest defaults in `manifests/init.pp`. No Hiera data values found in `../../data/common.yaml` or any other hierarchy level for these keys.

### Variable Definitions

**Manifest defaults (`manifests/init.pp`) — no Hiera overrides**
- `profile_redis_cluster_case3::redis_port`: `6379` (type: integer)
- `profile_redis_cluster_case3::redis_password`: `'CHANGEME'` (type: string) ⚠️ plaintext — must be vault-encrypted before use
- `profile_redis_cluster_case3::maxmemory_mb`: `2048` (type: integer)
- `profile_redis_cluster_case3::maxmemory_policy`: `'allkeys-lru'` (type: string)

**Ansible defaults/main.yml equivalents**:
```yaml
redis_cluster_case3_redis_port: 6379
redis_cluster_case3_redis_password: "CHANGEME"   # MUST be replaced with vault-encrypted value
redis_cluster_case3_maxmemory_mb: 2048
redis_cluster_case3_maxmemory_policy: "allkeys-lru"
```

### Variable Migration Summary

- **Common defaults**: 4 variables from manifest defaults (no Hiera values present in `common.yaml`)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable requiring secure storage (`redis_password` — currently plaintext `'CHANGEME'`)

### Cross-Level Overrides

No cross-level overrides exist. All four parameters are defined only at the manifest default level. No `lookup_options` or merge strategies are configured.

### Merge Strategy Notes

- No Hiera merge strategies are configured for this module. All variables use the default `first` strategy (first value found wins). Since no Hiera values are present, manifest defaults are always used.

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Used in**: `manifests/init.pp` as `myCronType1 'redis-backup'`
- **Parameters in use**: name=`redis-backup`, command=`/usr/local/bin/redis-backup.sh`, hour=`2`, minute=`30`, ensure=`present`
- **Provider behavior**: Reads root crontab via `crontab -l`, writes updated crontab via `crontab -`

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Used in**: `manifests/init.pp` as `myDeploy1 'myapp'`
- **Parameters in use**: name=`myapp`, version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`, ensure=`present`
- **Provider behavior**: Checks `/opt/myapp/version.txt` for `2.1.0`; if absent or mismatched → creates `/opt/myapp`, downloads artifact, extracts with `tar -xzf`, writes `/opt/myapp/version.txt` containing `2.1.0`

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Used in**: `manifests/init.pp` as two instances:
  - `myFormatType1 'app-mode'` → file=`/etc/company/app.conf`, value=`cluster`, ensure=`present`
  - `myFormatType1 'health-port'` → file=`/etc/company/app.conf`, value=`8080`, ensure=`present`
- **Provider behavior**: Reads `/etc/company/app.conf` line by line; finds, replaces, or appends entries in `!key=value` format

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Used in**: `manifests/init.pp` as `mySecretType1 'redis-node'`
- **Parameters in use**: name=`redis-node`, schedule=`daily`, ensure=`present`
- **Provider behavior**: Runs `schedulerctl query redis-node`; if absent → runs `schedulerctl register --schedule daily redis-node`; destroy → `schedulerctl unregister redis-node`

### redis_role (fact)

- **Fact file**: `lib/facter/redis_role.rb`
- **Used in**: Not directly referenced in these manifests; available to all classes on the node
- **Logic**: Returns `'primary'` if `/etc/redis/conf.d/replica.conf` does not exist or does not contain `replicaof`; returns `'replica'` otherwise
- **Confinement**: `kernel == 'Linux'`

### myFunction1 (function)

- **Function file**: `lib/puppet/functions/myFunction1.rb`
- **Used in**: `manifests/init.pp` — `myFunction1('http://localhost:8080/health')`
- **Returns**: Parsed JSON Hash/Array or raw String body from HTTP GET

### mySecretFunction1 (function)

- **Function file**: `lib/puppet/functions/mySecretFunction1.rb`
- **Used in**: `manifests/init.pp` — `mySecretFunction1('redis_service_token')`
- **Returns**: Secret string from proprietary `CompanyInternal::SecretStore`

## Dependencies

**External module dependencies** (from `metadata.json`):
- `puppetlabs-stdlib` >= 9.0.0 < 10.0.0 — provides `stdlib::to_json()` function
- `puppet-redis` >= 11.0.0 < 12.0.0 — manages Redis package, config, and service

**System package dependencies**:
- `redis` (installed by `puppet-redis` with `manage_package: true`)

**Service dependencies**:
- `redis` service managed by `puppet-redis` module
- `puppet-redis` ordering: package → config (`redis.conf.erb`) → service; config changes notify service restart

**Supported OS** (from `metadata.json`):
- RedHat 8, 9
- Ubuntu 22.04, 24.04

## Puppet Facts Used

- `$facts['networking']['fqdn']` — node's fully-qualified domain name; used in `templates/redis.conf.erb` comment header only
- `kernel` (implicit) — `redis_role` custom fact is confined to `kernel == 'Linux'`

## Custom Types Used

- `myCronType1 'redis-backup'` — declared in `manifests/init.pp`; parameters: name=`redis-backup`, command=`/usr/local/bin/redis-backup.sh`, hour=`2`, minute=`30`, ensure=`present`
- `myDeploy1 'myapp'` — declared in `manifests/init.pp`; parameters: name=`myapp`, version=`2.1.0`, url=`http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir=`/opt/myapp`, ensure=`present`
- `myFormatType1 'app-mode'` — declared in `manifests/init.pp`; parameters: entry=`app-mode`, file=`/etc/company/app.conf`, value=`cluster`, ensure=`present`
- `myFormatType1 'health-port'` — declared in `manifests/init.pp`; parameters: entry=`health-port`, file=`/etc/company/app.conf`, value=`8080`, ensure=`present`
- `mySecretType1 'redis-node'` — declared in `manifests/init.pp`; parameters: name=`redis-node`, schedule=`daily`, ensure=`present`

## Custom Providers Used

- `myCronProvider1` — implements `myCronType1`; shells out to `crontab -l` / `crontab -`; used for `myCronType1 'redis-backup'` in `manifests/init.pp`
- `myDeployProvider` — implements `myDeploy1`; uses `mkdir`, HTTP download, `tar -xzf`, file write for version tracking; used for `myDeploy1 'myapp'` in `manifests/init.pp`
- `myFormatProvider1` — implements `myFormatType1`; reads/writes proprietary `!key=value` format in `/etc/company/app.conf`; used for `myFormatType1 'app-mode'` and `myFormatType1 'health-port'` in `manifests/init.pp`
- `mySecretProvider1` — implements `mySecretType1`; wraps `/usr/local/bin/schedulerctl query/register/unregister`; used for `mySecretType1 'redis-node'` in `manifests/init.pp`

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `manifests/init.pp`; returns parsed JSON or raw string from HTTP GET; result serialized to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `manifests/init.pp`; returns secret string from `CompanyInternal::SecretStore`; assigned to `$service_token` (downstream use not visible in these manifests)
- `stdlib::to_json($health_check)` — called in `manifests/init.pp`; serializes `$health_check` to JSON string for file content

## Custom Component Conversion Decisions

### myCronType1 + myCronProvider1
- **Decision**: Existing Ansible modules
- **Mapping**: `ansible.builtin.cron`
  ```yaml
  - name: Manage redis-backup cron entry
    ansible.builtin.cron:
      name: "redis-backup"
      job: "/usr/local/bin/redis-backup.sh"
      hour: "2"
      minute: "30"
      user: "root"
      state: present
  ```

### myDeploy1 + myDeployProvider
- **Decision**: Existing Ansible modules
- **Mapping**: Combination of `ansible.builtin.slurp`, `ansible.builtin.file`, `ansible.builtin.get_url`, `ansible.builtin.unarchive`, `ansible.builtin.copy`
  ```yaml
  - name: Check installed version of myapp
    ansible.builtin.slurp:
      src: /opt/myapp/version.txt
    register: myapp_version_file
    ignore_errors: true

  - name: Create install directory for myapp
    ansible.builtin.file:
      path: /opt/myapp
      state: directory
      mode: "0755"

  - name: Download myapp artifact
    ansible.builtin.get_url:
      url: "http://artifacts.internal/myapp-2.1.0.tar.gz"
      dest: "/tmp/myapp-2.1.0.tar.gz"
    when: >
      myapp_version_file.failed or
      (myapp_version_file.content | b64decode | trim) != '2.1.0'

  - name: Extract myapp artifact
    ansible.builtin.unarchive:
      src: "/tmp/myapp-2.1.0.tar.gz"
      dest: "/opt/myapp"
      remote_src: true
    when: >
      myapp_version_file.failed or
      (myapp_version_file.content | b64decode | trim) != '2.1.0'

  - name: Write myapp version file
    ansible.builtin.copy:
      content: "2.1.0"
      dest: "/opt/myapp/version.txt"
    when: >
      myapp_version_file.failed or
      (myapp_version_file.content | b64decode | trim) != '2.1.0'
  ```

### myFormatType1 + myFormatProvider1
- **Decision**: CUSTOM ANSIBLE MODULE NEEDED
- **Module name (suggested)**: `company_app_conf`
- **Full behavior and interface**:
  - Manages `!key=value` entries in a proprietary CompanyApp settings file
  - Parameters:
    - `file` (str, required): Absolute path to the settings file (e.g., `/etc/company/app.conf`)
    - `entry` (str, required): The key name to manage (matched against `!key=value` lines)
    - `value` (str, required when `state=present`): The value to set
    - `state` (str, default: `present`): `present` to ensure entry exists with given value; `absent` to remove it
  - Idempotency: Read file, parse `!key=value` lines; if key already exists with correct value → no change; otherwise update and report `changed=true`
  - File format rules: Lines starting with `#` are comments; valid entries start with `!` and contain `=`; all other lines (blanks, unrecognized) are preserved as-is
  - Error handling: Raise error if parent directory does not exist; raise error if file is not readable/writable
  - Usage in this module:
    ```yaml
    - name: Set app-mode in CompanyApp config
      company_app_conf:
        file: /etc/company/app.conf
        entry: app-mode
        value: cluster
        state: present

    - name: Set health-port in CompanyApp config
      company_app_conf:
        file: /etc/company/app.conf
        entry: health-port
        value: "8080"
        state: present
    ```

### mySecretType1 + mySecretProvider1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Note to automation developer**: This type registers a server in a proprietary Enterprise Scheduler platform using the `schedulerctl` CLI (`/usr/local/bin/schedulerctl query`, `schedulerctl register --schedule <schedule> <name>`, `schedulerctl unregister <name>`). The semantics of these subcommands — including expected output format, exit codes, side effects, and the scheduler platform's API — are entirely opaque. No Ansible module or documented CLI wrapper exists for this tool. Before migration can proceed, the developer must: (1) obtain documentation or source for the Enterprise Scheduler platform, (2) determine whether a REST API or SDK is available as an alternative to the CLI, (3) decide whether to wrap `schedulerctl` with `ansible.builtin.command` (fragile, non-idempotent without careful output parsing) or write a custom Ansible module against a documented API.

### redis_role (fact)
- **Decision**: Existing Ansible modules
- **Mapping**: Inline variable using `ansible.builtin.stat` + `ansible.builtin.slurp`
  ```yaml
  - name: Check if replica.conf exists
    ansible.builtin.stat:
      path: /etc/redis/conf.d/replica.conf
    register: replica_conf_stat

  - name: Read replica.conf content
    ansible.builtin.slurp:
      src: /etc/redis/conf.d/replica.conf
    register: replica_conf_content
    when: replica_conf_stat.stat.exists

  - name: Set redis_role fact
    ansible.builtin.set_fact:
      redis_role: >-
        {{ 'replica'
           if (replica_conf_stat.stat.exists and
               'replicaof' in (replica_conf_content.content | default('') | b64decode))
           else 'primary' }}
  ```
  - Alternatively, deploy `/etc/ansible/facts.d/redis_role.fact` for persistent `ansible_local.redis_role` availability.

### myFunction1 (function)
- **Decision**: Existing Ansible modules
- **Mapping**: `ansible.builtin.uri` + `ansible.builtin.copy`
  ```yaml
  - name: Fetch health check data
    ansible.builtin.uri:
      url: "http://localhost:8080/health"
      method: GET
      return_content: true
    register: health_check_response

  - name: Write health check JSON to file
    ansible.builtin.copy:
      content: "{{ health_check_response.json | to_json }}"
      dest: /var/lib/redis/health_check.json
      owner: redis
      group: redis
      mode: "0644"
  ```
  - Note: If the endpoint returns non-JSON, use `health_check_response.content` instead of `.json`.

### mySecretFunction1 (function)
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Note to automation developer**: This function is a thin wrapper around `CompanyInternal::SecretStore.fetch('redis_service_token')` from the proprietary `company_internal_lib` Ruby library. The underlying secret store backend, authentication mechanism, network/API dependencies, and error semantics are entirely opaque — no source is available. The correct Ansible equivalent could be `community.hashi_vault.hashi_vault`, `azure.azcollection.azure_keyvault_secret`, AWS Secrets Manager lookup, or another provider, but this cannot be determined without knowing what `SecretStore` targets. Additionally, the downstream use of `$service_token` is not visible in these manifests — the developer must trace all consumers of this variable before migrating. All secret values must be handled with `no_log: true` in Ansible tasks to prevent exposure in logs.

## Template Conversion Notes

### `templates/redis.conf.erb` → `/etc/redis/redis.conf`

- **Render count**: 1 per node (rendered by `puppet-redis` module)
- **Variables used**:
  - `@facts['networking']['fqdn']` → `ansible_fqdn` (comment line only)
  - `@redis_port` → `redis_cluster_case3_redis_port` (default: `6379`)
  - `@redis_password` → `redis_cluster_case3_redis_password` (default: `CHANGEME`) ⚠️ must be vault-encrypted
  - `@maxmemory_mb` → `redis_cluster_case3_maxmemory_mb` (default: `2048`); rendered inline as `{{ redis_cluster_case3_maxmemory_mb }}mb`
  - `@maxmemory_policy` → `redis_cluster_case3_maxmemory_policy` (default: `allkeys-lru`)
- **Ruby logic blocks**: None — all substitutions are simple `<%= @var %>` interpolations
- **Conditional rendering**: None
- **Iterations**: None
- **Ansible Jinja2 equivalent**: Direct variable substitution; no complex logic required

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
- Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }`
- Purpose: Discovers all cluster peer nodes that have this profile applied; result stored in `$redis_nodes`
- Migration impact: This query is used for cluster peer discovery at catalog compile time. In Ansible, the equivalent is the `ansible_play_hosts` or `groups['redis_cluster']` inventory group variable. The developer must:
  1. Define an Ansible inventory group (e.g., `redis_cluster`) containing all Redis cluster nodes
  2. Replace `$redis_nodes` references with `groups['redis_cluster']` or `ansible_play_hosts`
  3. Note that `$redis_nodes` is assigned but its downstream use within these manifests is not visible — the developer must search the full role/profile chain for all consumers of this variable

**No exported resources (`@@`) or collectors (`<<| |>>`) found.**

## Checks for the Migration

**Files to verify**:
- `/etc/redis/redis.conf` — rendered from `templates/redis.conf.erb`; verify port, requirepass, maxmemory, appendonly settings
- `/var/log/redis/` — directory exists, owner `redis`, group `redis`, mode `0755`
- `/var/lib/redis/health_check.json` — exists, owner `redis`, group `redis`, mode `0644`, valid JSON content
- `/opt/myapp/version.txt` — contains `2.1.0`
- `/opt/myapp/` — directory exists with extracted artifact contents
- `/etc/company/app.conf` — contains `!app-mode=cluster` and `!health-port=8080`

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health endpoint: `curl http://localhost:8080/health` → should return valid JSON

**Templates rendered**:
- `templates/redis.conf.erb` → `/etc/redis/redis.conf` — rendered 1 time per node

## Pre-flight checks:
```bash
# Redis service status
systemctl status redis

# Redis replication role (verify against redis_role fact)
redis-cli -p 6379 -a <password> info replication

# Redis config file present and readable
test -f /etc/redis/redis.conf && echo "redis.conf present"

# Redis log directory
ls -ld /var/log/redis

# Health check endpoint reachable
curl -sf http://localhost:8080/health && echo "health endpoint OK"

# Health check JSON file
test -f /var/lib/redis/health_check.json && cat /var/lib/redis/health_check.json

# myapp deployment version
cat /opt/myapp/version.txt

# myapp install directory contents
ls /opt/myapp/

# CompanyApp settings entries
grep -E '^!(app-mode|health-port)=' /etc/company/app.conf

# Redis backup cron entry
crontab -l | grep redis-backup

# Enterprise Scheduler CLI present (required before mySecretType1 migration)
ls -l /usr/local/bin/schedulerctl

# Enterprise Scheduler registration status for redis-node
/usr/local/bin/schedulerctl query redis-node

# Artifact server reachable
curl -sf --head http://artifacts.internal/myapp-2.1.0.tar.gz && echo "artifact server reachable"
```