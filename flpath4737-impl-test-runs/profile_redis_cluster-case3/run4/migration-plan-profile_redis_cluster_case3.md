---
source-path: .
---

# Migration Plan: profile_redis_cluster_case3

**TLDR**: This Puppet module configures a Redis cluster node. It installs and configures Redis via a community `redis` class (binding to all interfaces, port 6379, password-protected, 2 GB memory limit with `allkeys-lru` eviction, append-only persistence), manages a log directory, deploys a companion application artifact (`myapp` v2.1.0), writes two entries into a proprietary CompanyApp settings file, registers the node with a proprietary Enterprise Scheduler, schedules a nightly Redis backup cron job, and writes a health-check JSON file populated by a live HTTP call. It also performs a PuppetDB query to discover all peer nodes running this same profile. Several custom types and functions are **not safely convertible** and require manual developer review before migration can be completed.

## Service Type and Instances

**Service Type**: Cache / In-Memory Data Store (Redis Cluster Node)

**Configured Instances**:
- **Redis**: single Redis server instance
  - Port: `6379`
  - Bind: `0.0.0.0` (all interfaces)
  - Password: `CHANGEME` (plaintext — must be replaced with Ansible Vault secret)
  - Max memory: `2048mb` with eviction policy `allkeys-lru`
  - Persistence: append-only (`appendonly yes`, `appendfsync everysec`)
  - Log directory: `/var/log/redis`
- **myapp**: companion application deployment
  - Version: `2.1.0`
  - Install directory: `/opt/myapp`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
- **redis-backup cron**: nightly backup job
  - Command: `/usr/local/bin/redis-backup.sh`
  - Schedule: `02:30` daily
- **CompanyApp settings**: `/etc/company/app.conf`
  - Entry `app-mode` = `cluster`
  - Entry `health-port` = `8080`
- **Enterprise Scheduler registration**: node `redis-node`, schedule `daily`
- **Health check JSON**: `/var/lib/redis/health_check.json` populated from `http://localhost:8080/health`

## File Structure

```
manifests/
  init.pp
  install.pp
lib/
  puppet/
    type/
      myCronType1.rb
      myDeploy1.rb
      myFormatType1.rb
      mySecretType1.rb
    provider/
      myCronType1/
        myCronProvider1.rb
      myDeploy1/
        myDeployProvider.rb
      myFormatType1/
        myFormatProvider1.rb
      mySecretType1/
        mySecretProvider1.rb
    functions/
      myFunction1.rb
      mySecretFunction1.rb
  facter/
    redis_role.rb
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case3** (`manifests/init.pp`):
   - Class parameters (all resolved from manifest defaults — no Hiera overrides exist at any level):
     - `$redis_port` = `6379`
     - `$redis_password` = `'CHANGEME'`
     - `$maxmemory_mb` = `2048`
     - `$maxmemory_policy` = `'allkeys-lru'`
   - **PuppetDB query**: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }")` — collects the list of all certnames that have this class applied; result is used as cluster peer discovery data
   - **Custom function call**: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body (or raw string on parse failure)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialised value of `$health_check`
   - **Custom type** `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
     - Provider (`myDeployProvider`): checks `/opt/myapp/version.txt`; if content ≠ `2.1.0`, downloads `http://artifacts.internal/myapp-2.1.0.tar.gz`, extracts into `/opt/myapp`, writes `2.1.0` to `/opt/myapp/version.txt`
   - **Custom function call**: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from a proprietary internal secret store; result stored in `$service_token` (**NOT SAFELY CONVERTIBLE**)
   - **Custom type** `mySecretType1 'redis-node'` → schedule: `'daily'`, ensure: `present`
     - Provider (`mySecretProvider1`): runs `schedulerctl query redis-node`; if not registered, runs `schedulerctl register redis-node --schedule daily`; destroy runs `schedulerctl unregister redis-node` (**NOT SAFELY CONVERTIBLE**)
   - **Custom type** `myFormatType1 'app-mode'` → file: `/etc/company/app.conf`, value: `'cluster'`, ensure: `present`
     - Provider (`myFormatProvider1`): reads `/etc/company/app.conf`, finds/replaces/appends line `!app-mode=cluster` using proprietary `!key=value` format (**requires custom Ansible module**)
   - **Custom type** `myFormatType1 'health-port'` → file: `/etc/company/app.conf`, value: `'8080'`, ensure: `present`
     - Provider (`myFormatProvider1`): reads `/etc/company/app.conf`, finds/replaces/appends line `!health-port=8080` using proprietary `!key=value` format (**requires custom Ansible module**)
   - **Custom type** `myCronType1 'redis-backup'` → command: `/usr/local/bin/redis-backup.sh`, hour: `'2'`, minute: `'30'`, ensure: `present`
     - Provider (`myCronProvider1`): shells out to `crontab -l` to check existence, appends `30 2 * * * /usr/local/bin/redis-backup.sh` to root's crontab if absent; destroy removes matching line via `crontab -`
   - `contain profile_redis_cluster_case3::install`

2. **profile_redis_cluster_case3::install** (`manifests/install.pp`):
   - `class 'redis'` (external community class, not analysed) → configured with:
     - `bind`: `0.0.0.0`
     - `port`: `6379`
     - `requirepass`: `CHANGEME`
     - `maxmemory`: `2048mb`
     - `appendonly`: `true`
     - `appendfsync`: `'everysec'`
     - `manage_package`: `true` (the class installs the Redis package itself)
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

## Variables

**Variable Flow Summary**: 4 variables; all resolved from class parameter defaults in `manifests/init.pp`. No Hiera overrides exist at common, production, or staging levels.

### Variable Definitions

**Class parameter defaults (`manifests/init.pp`) — no Hiera data overrides these at any level**
- `profile_redis_cluster_case3::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case3::redis_password`: `'CHANGEME'` (type: String — **plaintext credential, must be replaced with Ansible Vault**)
- `profile_redis_cluster_case3::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster_case3::maxmemory_policy`: `'allkeys-lru'` (type: String)

### Variable Migration Summary

- **Common defaults**: 0 variables (no `common.yaml` entries for this module)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (neither `production.yaml` nor `staging.yaml` override any key)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables currently encrypted — `redis_password` is plaintext and **must** be migrated to Ansible Vault

### Cross-Level Overrides

No cross-level overrides. All four variables are defined only at the manifest default level and are never overridden in any Hiera data file.

### Merge Strategy Notes

- No Hiera merge strategies apply — all variables are resolved from manifest parameter defaults only.

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Parameters**: `name` (namevar), `command` (String, required, non-empty), `hour` (String, default `'2'`), `minute` (String, default `'30'`), `ensure` (present/absent)
- **Provider behaviour**: reads root crontab via `crontab -l`, appends or removes `minute hour * * * command` lines via `crontab -`

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Parameters**: `name` (namevar), `version` (String, required, non-empty), `url` (String, must match `^https?://`), `install_dir` (String), `ensure` (present/absent, default present)
- **Provider behaviour**: idempotency via `install_dir/version.txt`; on mismatch: downloads `artifact.tar.gz` from `url`, extracts to `install_dir`, writes `version.txt`; destroy removes `install_dir`

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Parameters**: `entry` (namevar, non-empty), `file` (String, default `/etc/company/app.conf`), `value` (String), `ensure` (present/absent)
- **Provider behaviour**: manages `!key=value` lines in a proprietary CompanyApp settings file; preserves all non-matching lines verbatim; rewrites file in-place on change

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Parameters**: `name` (namevar), `schedule` (String), `ensure` (present/absent)
- **Provider behaviour**: wraps `schedulerctl query/register/unregister` CLI against a proprietary Enterprise Scheduler platform

## Dependencies

**External module dependencies**:
- `redis` community class (no Puppetfile present; class is included but not analysed — assumed to be a standard community Redis module such as `puppet-redis`)

**System package dependencies**:
- Redis server package (managed by the `redis` community class via `manage_package: true`)
- `/usr/local/bin/redis-backup.sh` — must exist on the node before the cron job runs (not installed by this module)
- `/usr/local/bin/schedulerctl` — proprietary CLI binary; must be pre-installed on the node

**Service dependencies**:
- `profile_redis_cluster_case3::install` is `contain`-ed inside `profile_redis_cluster_case3`, so all resources in `init.pp` are ordered relative to it via Puppet's containment semantics
- No explicit `->` or `~>` ordering arrows are declared between resources in `init.pp`

## Puppet Facts Used

- **`redis_role`** (`lib/facter/redis_role.rb`): custom fact; returns `'primary'` if `/etc/redis/conf.d/replica.conf` does not exist or does not contain the string `replicaof`; returns `'replica'` otherwise. Confined to Linux kernels. This fact is defined in the module but is **not referenced** in any manifest in the execution tree — it is available for use by other profiles or conditional logic.

## Custom Types Used

- `myDeploy1 'myapp'` — declared in `manifests/init.pp`; version `2.1.0`, url `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir `/opt/myapp`
- `mySecretType1 'redis-node'` — declared in `manifests/init.pp`; schedule `daily`
- `myFormatType1 'app-mode'` — declared in `manifests/init.pp`; file `/etc/company/app.conf`, value `cluster`
- `myFormatType1 'health-port'` — declared in `manifests/init.pp`; file `/etc/company/app.conf`, value `8080`
- `myCronType1 'redis-backup'` — declared in `manifests/init.pp`; command `/usr/local/bin/redis-backup.sh`, hour `2`, minute `30`

## Custom Providers Used

- `myCronProvider1` — implements `myCronType1`; used for the `redis-backup` cron entry
- `myDeployProvider` — implements `myDeploy1`; used for the `myapp` deployment
- `myFormatProvider1` — implements `myFormatType1`; used for both `app-mode` and `health-port` entries in `/etc/company/app.conf`
- `mySecretProvider1` — implements `mySecretType1`; used for the `redis-node` scheduler registration

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `manifests/init.pp`; performs HTTP GET, returns parsed JSON or raw string body; result written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `manifests/init.pp`; fetches secret `redis_service_token` from proprietary internal secret store; result stored in `$service_token` (usage of `$service_token` beyond assignment is not visible in the execution tree)

## Custom Component Conversion Decisions

### myCronType1 + myCronProvider1
- **Decision**: Existing Ansible modules — use `ansible.builtin.cron`
- **Mapping**:
  ```yaml
  - name: Manage redis-backup cron entry
    ansible.builtin.cron:
      name: "redis-backup"
      job: "/usr/local/bin/redis-backup.sh"
      hour: "2"
      minute: "30"
      user: root
      state: present
  ```

### myDeploy1 + myDeployProvider
- **Decision**: Existing Ansible modules — combine `ansible.builtin.slurp`, `ansible.builtin.get_url`, `ansible.builtin.unarchive`, and `ansible.builtin.copy`
- **Mapping**:
  ```yaml
  - name: Read current myapp version
    ansible.builtin.slurp:
      src: /opt/myapp/version.txt
    register: current_version_b64
    ignore_errors: true

  - name: Download myapp artifact
    ansible.builtin.get_url:
      url: "http://artifacts.internal/myapp-2.1.0.tar.gz"
      dest: "/tmp/myapp-2.1.0.tar.gz"
    when: >
      current_version_b64.failed or
      (current_version_b64.content | b64decode | trim) != '2.1.0'

  - name: Extract myapp artifact
    ansible.builtin.unarchive:
      src: "/tmp/myapp-2.1.0.tar.gz"
      dest: "/opt/myapp"
      remote_src: true
    when: >
      current_version_b64.failed or
      (current_version_b64.content | b64decode | trim) != '2.1.0'

  - name: Write myapp version file
    ansible.builtin.copy:
      content: "2.1.0"
      dest: "/opt/myapp/version.txt"
    when: >
      current_version_b64.failed or
      (current_version_b64.content | b64decode | trim) != '2.1.0'
  ```
  - URL validation (`^https?://`) and non-empty version should be enforced via `ansible.builtin.assert` before these tasks run.

### myFormatType1 + myFormatProvider1
- **Decision**: **Custom Ansible module required**
- **Module name (suggested)**: `company_app_conf`
- **Behavior**: Manages `!key=value` entries in a proprietary CompanyApp settings file
- **Parameters**:
  - `file` (str, required): Absolute path to the settings file
  - `entry` (str, required): The key name to manage
  - `value` (str, optional): Desired value; required when `state=present`
  - `state` (str, default `present`): `present` ensures `!entry=value` line exists; `absent` removes any line whose key matches `entry`
- **Idempotency**:
  - `state=present`: if exact `!entry=value` line already exists → no change; otherwise remove all lines matching key and append `!entry=value`
  - `state=absent`: if no line matches key → no change; otherwise remove all matching lines and rewrite
- **Error handling**:
  - File absent + `state=absent` → report no change
  - File absent + `state=present` → create file with single entry line
  - File not writable → fail with clear error
  - Non-entry lines (comments, unrecognised `!`-prefixed lines) must be preserved verbatim
- **Side effects**: rewrites entire file in-place when a change is needed; all non-matching lines preserved in original order
- **Usage in this module**:
  ```yaml
  - name: Set app-mode in /etc/company/app.conf
    company_app_conf:
      file: /etc/company/app.conf
      entry: app-mode
      value: cluster
      state: present

  - name: Set health-port in /etc/company/app.conf
    company_app_conf:
      file: /etc/company/app.conf
      entry: health-port
      value: "8080"
      state: present
  ```

### mySecretType1 + mySecretProvider1
- **Decision**: **NOT SAFELY CONVERTIBLE — flagged for developer review**
- **Reason**: The provider wraps a proprietary CLI tool `schedulerctl` (`/usr/local/bin/schedulerctl`) to register/query/unregister nodes in an undocumented Enterprise Scheduler platform. The semantics of `schedulerctl query`, `schedulerctl register`, and `schedulerctl unregister` — including output format, exit codes, error conditions, and side effects — are entirely opaque. A custom Ansible module wrapping `ansible.builtin.command` calls to `schedulerctl` could be written, but only once the full CLI contract is documented by the platform owner. The automation developer must obtain that documentation before proceeding.

### redis_role (custom fact)
- **Decision**: Existing Ansible modules — reproduce inline or as a persistent local fact
- **Inline approach**:
  ```yaml
  - name: Check replica.conf existence
    ansible.builtin.stat:
      path: /etc/redis/conf.d/replica.conf
    register: replica_conf_stat

  - name: Check for replicaof directive
    ansible.builtin.command: grep -q replicaof /etc/redis/conf.d/replica.conf
    register: replicaof_check
    failed_when: false
    changed_when: false
    when: replica_conf_stat.stat.exists

  - name: Set redis_role fact
    ansible.builtin.set_fact:
      redis_role: >-
        {{ 'replica' if (replica_conf_stat.stat.exists and replicaof_check.rc == 0) else 'primary' }}
  ```
- **Persistent approach**: deploy a script to `/etc/ansible/facts.d/redis_role.fact` and reference via `ansible_local.redis_role`

### myFunction1
- **Decision**: Existing Ansible modules — use `ansible.builtin.uri`
- **Mapping**:
  ```yaml
  - name: Fetch health check data
    ansible.builtin.uri:
      url: "http://localhost:8080/health"
      method: GET
      return_content: true
    register: health_check_result

  - name: Write health_check.json
    ansible.builtin.copy:
      content: "{{ health_check_result.json | to_json }}"
      dest: /var/lib/redis/health_check.json
      owner: redis
      group: redis
      mode: '0644'
  ```
  - If the endpoint returns non-JSON, use `health_check_result.content` instead of `.json`

### mySecretFunction1
- **Decision**: **NOT SAFELY CONVERTIBLE — flagged for developer review**
- **Reason**: The function delegates to `CompanyInternal::SecretStore.fetch`, a method from a proprietary Ruby library (`company_internal_lib`) that is not available in source. The underlying secret backend (HashiCorp Vault, CyberArk, an internal HSM, or other) is entirely unknown. The automation developer must identify the backend and select the appropriate Ansible lookup plugin (e.g. `community.hashi_vault.hashi_vault`, `delinea.pas.pas`, or a custom lookup) once the backend is documented. The secret name to look up is `redis_service_token`.

## Template Conversion Notes

No ERB templates are used in this module. All file content is either:
- Dynamically generated from a function return value (`/var/lib/redis/health_check.json` — content is the JSON-serialised result of `myFunction1`)
- Managed by the external `redis` community class (Redis configuration files)

## PuppetDB Dependencies

- **PuppetDB query in `manifests/init.pp`**:
  ```puppet
  $redis_nodes = puppetdb_query(
    "resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }"
  )
  ```
  - **Purpose**: discovers all certnames (hostnames) in the Puppet infrastructure that have this same profile applied — used for cluster peer discovery
  - **Ansible equivalent**: PuppetDB is not available in an Ansible environment. Replace with one of:
    - An Ansible dynamic inventory group (e.g. `[redis_cluster]`) — all hosts in the group are the peers
    - A static variable `redis_cluster_nodes: [list of hostnames]` in `group_vars/redis_cluster.yml`
    - A dynamic lookup via an inventory plugin (e.g. `community.general.consul_io`, `amazon.aws.aws_ec2`, or a custom inventory script) if nodes are registered in a CMDB or service discovery system
  - **⚠ Migration note**: The result `$redis_nodes` is assigned but its downstream usage is not visible in the execution tree beyond the assignment. The automation developer must trace all uses of `$redis_nodes` in the full codebase to determine what cluster configuration it drives.

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned `redis:redis`, mode `0644`, contains valid JSON from `http://localhost:8080/health`
- `/var/log/redis` — exists as directory, owned `redis:redis`, mode `0755`
- `/etc/company/app.conf` — contains line `!app-mode=cluster` and line `!health-port=8080`
- `/opt/myapp/version.txt` — contains `2.1.0`
- `/opt/myapp` — directory exists and contains extracted artifact

**Service endpoints to check**:
- Redis: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health endpoint: `curl -s http://localhost:8080/health` → should return JSON

**Templates rendered**: None (no ERB templates in this module)

## Pre-flight checks:
```bash
# Redis instance
redis-cli -p 6379 -a <password> ping
redis-cli -p 6379 -a <password> info replication

# myapp deployment
cat /opt/myapp/version.txt
ls /opt/myapp

# redis-backup cron
crontab -l | grep redis-backup

# CompanyApp settings
grep -E '^!(app-mode|health-port)=' /etc/company/app.conf

# Enterprise Scheduler registration
/usr/local/bin/schedulerctl query redis-node

# Health check JSON
cat /var/lib/redis/health_check.json
curl -s http://localhost:8080/health

# Log directory
ls -ld /var/log/redis

# Verify schedulerctl binary is present
test -x /usr/local/bin/schedulerctl && echo "schedulerctl present" || echo "schedulerctl MISSING"

# Verify redis-backup script is present
test -x /usr/local/bin/redis-backup.sh && echo "redis-backup.sh present" || echo "redis-backup.sh MISSING"
```