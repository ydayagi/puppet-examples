---
source-path: .
---

# Migration Plan: profile_redis_cluster_case3

**TLDR**: This Puppet profile configures a Redis cluster node. It installs and configures Redis (via an external `redis` class) with authentication, memory limits, and append-only persistence. It also deploys a companion application (`myapp`), registers the node with a proprietary Enterprise Scheduler, writes entries to a proprietary CompanyApp settings file, schedules a Redis backup cron job, performs an HTTP health check whose result is written to a JSON file, and fetches a service token from a proprietary internal secret store. Several components rely on undocumented proprietary systems and require developer investigation before migration can be completed.

---

## Service Type and Instances

**Service Type**: In-memory data store / Cache (Redis cluster node)

**Configured Instances**:
- **Redis node** (primary service):
  - Port: `6379`
  - Bind: `0.0.0.0`
  - Auth password: `CHANGEME` (plaintext — must be replaced and encrypted before production use)
  - Max memory: `2048mb`, policy: `allkeys-lru`
  - Persistence: append-only (`appendonly=true`, `appendfsync=everysec`)
  - Log directory: `/var/log/redis`

- **myapp** (companion application deployment):
  - Version: `2.1.0`
  - Artifact URL: `http://artifacts.internal/myapp-2.1.0.tar.gz`
  - Install directory: `/opt/myapp`

- **redis-backup cron job**:
  - Command: `/usr/local/bin/redis-backup.sh`
  - Schedule: daily at `02:30`

- **CompanyApp settings** (`/etc/company/app.conf`):
  - Entry `app-mode` = `cluster`
  - Entry `health-port` = `8080`

- **Health check JSON** (`/var/lib/redis/health_check.json`):
  - Written from HTTP GET to `http://localhost:8080/health`

- **Enterprise Scheduler registration** (`redis-node`, schedule: `daily`):
  - Managed via proprietary `schedulerctl` CLI — NOT SAFELY CONVERTIBLE

- **Service token** (`redis_service_token`):
  - Fetched from proprietary `CompanyInternal::SecretStore` — NOT SAFELY CONVERTIBLE

---

## File Structure

```
manifests/
  init.pp                                          — entry class, all top-level resources
  install.pp                                       — Redis installation and log directory

lib/
  puppet/
    type/
      myDeploy1.rb
      mySecretType1.rb
      myFormatType1.rb
      myCronType1.rb
    provider/
      myDeploy1/
        myDeployProvider.rb
      mySecretType1/
        mySecretProvider1.rb
      myFormatType1/
        myFormatProvider1.rb
      myCronType1/
        myCronProvider1.rb
    functions/
      myFunction1.rb
      mySecretFunction1.rb
  facter/
    redis_role.rb
```

---

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case3** (`manifests/init.pp`):
   - Sets class parameters with defaults (all resolved from manifest defaults — no Hiera overrides exist):
     - `redis_port` = `6379`
     - `redis_password` = `'CHANGEME'`
     - `maxmemory_mb` = `2048`
     - `maxmemory_policy` = `'allkeys-lru'`
   - **PuppetDB query**: `$redis_nodes = puppetdb_query("resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }")` — collects all certnames in the cluster running this profile
   - **Custom function call**: `$health_check = myFunction1('http://localhost:8080/health')` — performs HTTP GET to `http://localhost:8080/health`, returns parsed JSON body (or raw string on parse failure)
   - `file '/var/lib/redis/health_check.json'` → ensure: `file`, owner: `redis`, group: `redis`, mode: `0644`, content: JSON-serialized result of `$health_check`
   - **Custom type** `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`, ensure: `present`
   - **Custom function call**: `$service_token = mySecretFunction1('redis_service_token')` — fetches secret named `redis_service_token` from proprietary `CompanyInternal::SecretStore`
   - **Custom type** `mySecretType1 'redis-node'` → schedule: `daily`, ensure: `present` — registers this node with the Enterprise Scheduler platform via `schedulerctl`
   - **Custom type** `myFormatType1 'app-mode'` → file: `/etc/company/app.conf`, value: `cluster`, ensure: `present` — writes `!app-mode=cluster` to the CompanyApp settings file
   - **Custom type** `myFormatType1 'health-port'` → file: `/etc/company/app.conf`, value: `8080`, ensure: `present` — writes `!health-port=8080` to the CompanyApp settings file
   - **Custom type** `myCronType1 'redis-backup'` → command: `/usr/local/bin/redis-backup.sh`, hour: `2`, minute: `30`, ensure: `present` — adds root crontab entry
   - `contain profile_redis_cluster_case3::install` — contained subclass (ordering enforced)

2. **profile_redis_cluster_case3::install** (`manifests/install.pp`):
   - `class 'redis'` (external, not analyzed) → configured with:
     - `bind`: `0.0.0.0`
     - `port`: `6379`
     - `requirepass`: `CHANGEME`
     - `maxmemory`: `2048mb`
     - `appendonly`: `true`
     - `appendfsync`: `everysec`
     - `manage_package`: `true`
   - `file '/var/log/redis'` → ensure: `directory`, owner: `redis`, group: `redis`, mode: `0755`

---

## Variables

**Variable Flow Summary**: 4 variables, all resolved from manifest parameter defaults. No Hiera data files define any `profile_redis_cluster_case3::*` keys. No environment-level overrides exist.

### Variable Definitions

**Manifest parameter defaults** (`manifests/init.pp`) → Migration note: All defaults live in the manifest; migrate to `defaults/main.yml` in Ansible:
- `profile_redis_cluster_case3::redis_port`: `6379` (type: integer)
- `profile_redis_cluster_case3::redis_password`: `'CHANGEME'` (type: string — **plaintext credential, must be replaced and encrypted with ansible-vault**)
- `profile_redis_cluster_case3::maxmemory_mb`: `2048` (type: integer — used as `2048mb` in Redis config)
- `profile_redis_cluster_case3::maxmemory_policy`: `'allkeys-lru'` (type: string)

### Variable Migration Summary

- **Common defaults**: 4 variables (all from manifest defaults)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables (no `profile_redis_cluster_case3::*` keys found in any environment-level Hiera data)
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 1 variable requiring secure storage (`redis_password` — currently plaintext `CHANGEME`, must be vaulted before production use)

### Cross-Level Overrides

No cross-level overrides. All four variables are defined only at the manifest default level.

### Merge Strategy Notes

- No Hiera merge strategies apply — all variables are single-level manifest defaults with no hash or array merging.

---

## Custom Types and Providers

### myCronType1 / myCronProvider1

- **Type file**: `lib/puppet/type/myCronType1.rb`
- **Provider file**: `lib/puppet/provider/myCronType1/myCronProvider1.rb`
- **Parameters**: `name` (namevar), `command` (non-empty string), `hour` (default: `'2'`), `minute` (default: `'30'`), `ensure`
- **Provider behavior**: shells out to `crontab -l` (read) and `crontab -` (write) for the root user; `exists?` checks if command is already scheduled; `create` appends entry; `destroy` removes matching lines

### myDeploy1 / myDeployProvider

- **Type file**: `lib/puppet/type/myDeploy1.rb`
- **Provider file**: `lib/puppet/provider/myDeploy1/myDeployProvider.rb`
- **Parameters**: `name` (namevar), `version` (non-empty, validated), `url` (must match `^https?://`), `install_dir`, `ensure` (default: `present`)
- **Provider behavior**: `exists?` checks `install_dir/version.txt` for matching version; `create` creates directory, downloads `.tar.gz` from `url`, extracts with `tar -xzf`, writes `version.txt`; `destroy` removes `install_dir` recursively

### myFormatType1 / myFormatProvider1

- **Type file**: `lib/puppet/type/myFormatType1.rb`
- **Provider file**: `lib/puppet/provider/myFormatType1/myFormatProvider1.rb`
- **Parameters**: `entry` (namevar, non-empty), `file` (default: `/etc/company/app.conf`), `value` (property — actively enforced), `ensure`
- **Provider behavior**: manages `!key=value` lines in a proprietary CompanyApp settings file; parses lines starting with `!`, splits on first `=`, strips whitespace; preserves comment lines (`#`) and invalid `!` lines (no `=`) untouched; `create`/`update` appends `!{entry}={value}`; `destroy` removes matching key lines

### mySecretType1 / mySecretProvider1

- **Type file**: `lib/puppet/type/mySecretType1.rb`
- **Provider file**: `lib/puppet/provider/mySecretType1/mySecretProvider1.rb`
- **Parameters**: `name` (namevar), `schedule` (string), `ensure`
- **Provider behavior**: uses proprietary CLI `/usr/local/bin/schedulerctl` with `query`, `register`, and `unregister` subcommands; semantics, exit codes, and output format are entirely opaque

### redis_role (custom fact)

- **Fact file**: `lib/facter/redis_role.rb`
- **Behavior**: confined to Linux; checks existence of `/etc/redis/conf.d/replica.conf` and whether it contains the string `replicaof`; returns `'primary'` or `'replica'`

### myFunction1 (custom function)

- **Function file**: `lib/puppet/functions/myFunction1.rb`
- **Behavior**: HTTP GET to a given URL; returns parsed JSON body (Hash/Array) or raw string; raises on non-2xx response

### mySecretFunction1 (custom function)

- **Function file**: `lib/puppet/functions/mySecretFunction1.rb`
- **Behavior**: delegates to `CompanyInternal::SecretStore.fetch(credential_name)` from proprietary `company_internal_lib` Ruby library; backend, auth mechanism, and return format are unknown

---

## Dependencies

**External module dependencies**:
- `redis` class (no Puppetfile found; assumed to be a community Redis module such as `puppet-redis` from Puppet Forge — must be identified and replaced with an equivalent Ansible role, e.g., `geerlingguy.redis`)

**System package dependencies**:
- Redis server package (managed by the `redis` class with `manage_package: true`)
- `/usr/local/bin/redis-backup.sh` — must exist on the target host (not managed by this module)
- `/usr/local/bin/schedulerctl` — proprietary CLI required by `mySecretType1`/`mySecretProvider1`

**Service dependencies**:
- `profile_redis_cluster_case3::install` is `contain`-ed inside `profile_redis_cluster_case3`, meaning all resources in `install.pp` are ordered relative to the parent class within the catalog

---

## Puppet Facts Used

- `$facts['kernel']` — used in `lib/facter/redis_role.rb` confinement; ensures the fact only runs on Linux kernels
- `$redis_nodes` — result of PuppetDB query `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }` — returns list of certnames running this profile; used for cluster membership awareness in `manifests/init.pp`

---

## Custom Types Used

- `myDeploy1 'myapp'` — declared in `manifests/init.pp`; parameters: `version=2.1.0`, `url=http://artifacts.internal/myapp-2.1.0.tar.gz`, `install_dir=/opt/myapp`
- `mySecretType1 'redis-node'` — declared in `manifests/init.pp`; parameters: `schedule=daily`
- `myFormatType1 'app-mode'` — declared in `manifests/init.pp`; parameters: `file=/etc/company/app.conf`, `value=cluster`
- `myFormatType1 'health-port'` — declared in `manifests/init.pp`; parameters: `file=/etc/company/app.conf`, `value=8080`
- `myCronType1 'redis-backup'` — declared in `manifests/init.pp`; parameters: `command=/usr/local/bin/redis-backup.sh`, `hour=2`, `minute=30`

---

## Custom Providers Used

- `myCronProvider1` — implements `myCronType1`; used for the `redis-backup` cron entry; shells out to `crontab -l`/`crontab -`
- `myDeployProvider` — implements `myDeploy1`; used for `myapp` deployment; uses `mkdir`, `wget`/`curl`, `tar -xzf`, file I/O
- `myFormatProvider1` — implements `myFormatType1`; used for `app-mode` and `health-port` entries in `/etc/company/app.conf`; proprietary `!key=value` format
- `mySecretProvider1` — implements `mySecretType1`; used for `redis-node` scheduler registration; uses proprietary `/usr/local/bin/schedulerctl`

---

## Custom Functions Used

- `myFunction1('http://localhost:8080/health')` — called in `manifests/init.pp`; returns parsed JSON or raw string from HTTP GET; result stored in `$health_check` and written to `/var/lib/redis/health_check.json`
- `mySecretFunction1('redis_service_token')` — called in `manifests/init.pp`; returns secret value from proprietary `CompanyInternal::SecretStore`; result stored in `$service_token` (downstream consumer of `$service_token` is not visible in the execution tree — its usage after assignment is unknown)

---

## Custom Component Conversion Decisions

### myCronType1 + myCronProvider1
- **Decision**: Existing Ansible modules
- **Mapping**: Use `ansible.builtin.cron` with `name: redis-backup`, `job: /usr/local/bin/redis-backup.sh`, `hour: "2"`, `minute: "30"`, `user: root`, `state: present`. The provider's `crontab -l`/`crontab -` shell-out is fully replaced by the module's idempotent crontab management.

### myDeploy1 + myDeployProvider
- **Decision**: Existing Ansible modules
- **Mapping**: Implement as a task block:
  1. `ansible.builtin.stat` on `/opt/myapp/version.txt` — register result for idempotency check
  2. `ansible.builtin.slurp` on `/opt/myapp/version.txt` — read current version when file exists
  3. `ansible.builtin.file` → `state: directory`, `path: /opt/myapp` — create install directory
  4. `ansible.builtin.get_url` → `url: http://artifacts.internal/myapp-2.1.0.tar.gz`, `dest: /tmp/myapp-2.1.0.tar.gz` — download artifact (skip when version already matches)
  5. `ansible.builtin.unarchive` → `src: /tmp/myapp-2.1.0.tar.gz`, `dest: /opt/myapp`, `remote_src: yes` — extract artifact
  6. `ansible.builtin.copy` → `content: "2.1.0\n"`, `dest: /opt/myapp/version.txt` — write version tracker
  - Wrap steps 3–6 in a `when` condition: `current_version != '2.1.0'`
  - Destroy path: `ansible.builtin.file` → `state: absent`, `path: /opt/myapp`

### myFormatType1 + myFormatProvider1
- **Decision**: Custom Ansible module required
- **Module name**: `company_app_conf`
- **Parameters**:
  - `file` (string, required) — path to the CompanyApp settings file (e.g., `/etc/company/app.conf`)
  - `entry` (string, required) — the key name (e.g., `app-mode`)
  - `value` (string, required when `state=present`) — the desired value (e.g., `cluster`)
  - `state` (enum `present`/`absent`, default: `present`)
- **Read**: Read all lines from `file` if it exists. Lines starting with `#` are comments — leave untouched. Lines starting with `!` followed by `key=value` are managed entries. All other lines are left untouched.
- **Parsing**: For each `!`-prefixed line, split on the first `=`. Strip whitespace from key and value. Lines starting with `!` that contain no `=` are invalid — leave untouched.
- **state=present**: If `!{entry}={value}` already exists exactly, do nothing (`changed=false`). Otherwise, remove any existing line whose key matches `entry` and append `!{entry}={value}` at end of file (`changed=true`).
- **state=absent**: Remove any line whose parsed key matches `entry` (`changed=true` if removed, `changed=false` if not found).
- **File handling**: If file does not exist and `state=present`, create it with the single entry line. If file does not exist and `state=absent`, do nothing.
- **Error handling**: Raise error if file path is not writable or required parameters are missing.
- **Idempotency**: No changes and `changed=false` when desired state already matches actual state.
- **Usage in this module**:
  - `company_app_conf` → `file: /etc/company/app.conf`, `entry: app-mode`, `value: cluster`, `state: present`
  - `company_app_conf` → `file: /etc/company/app.conf`, `entry: health-port`, `value: 8080`, `state: present`

### mySecretType1 + mySecretProvider1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The provider relies exclusively on the proprietary CLI `/usr/local/bin/schedulerctl` with `query`, `register`, and `unregister` subcommands. The semantics, output format, exit codes, and side effects of these subcommands are entirely undocumented and opaque. No existing Ansible module or combination of modules can reproduce this behavior. The automation developer must:
  1. Obtain documentation or source code for `schedulerctl`
  2. Determine the exact CLI contract (exit codes, output format, idempotency guarantees)
  3. Either wrap it in `ansible.builtin.command` tasks (if exit codes are reliable) or write a custom Ansible module

### redis_role (custom fact)
- **Decision**: Existing Ansible modules
- **Mapping**: Reproduce inline in the playbook:
  1. `ansible.builtin.stat` → `path: /etc/redis/conf.d/replica.conf` — register `replica_conf_stat`
  2. `ansible.builtin.command` → `grep -q replicaof /etc/redis/conf.d/replica.conf` — register `grep_result`, `failed_when: false`
  3. Set `redis_role` as a host variable: `"replica"` when `replica_conf_stat.stat.exists and grep_result.rc == 0`, else `"primary"`
  - Alternatively, deploy a static fact script to `/etc/ansible/facts.d/redis_role.fact` and gather via `ansible.builtin.setup`

### myFunction1
- **Decision**: Existing Ansible modules
- **Mapping**: Use `ansible.builtin.uri` → `url: http://localhost:8080/health`, `method: GET`, `return_content: yes`, `status_code: [200, 201, 202, 203, 204]`. The parsed JSON response is available via `result.json`; raw body via `result.content`. Register result and pass to subsequent tasks (e.g., write to `/var/lib/redis/health_check.json` using `ansible.builtin.copy` with `content: "{{ health_check_result.json | to_json }}"`)

### mySecretFunction1
- **Decision**: NOT SAFELY CONVERTIBLE — flagged for developer review
- **Reason**: The function delegates entirely to `CompanyInternal::SecretStore.fetch` from the proprietary `company_internal_lib` Ruby library. The backend (Vault, HSM, database, etc.), authentication mechanism, and return value format are completely unknown. Additionally, the downstream consumer of `$service_token` is not visible in the execution tree — it is unclear where or how the token is used after being fetched. The automation developer must:
  1. Identify what secret backend `company_internal_lib` wraps (e.g., HashiCorp Vault, AWS Secrets Manager, CyberArk)
  2. Determine the return value format and how `$service_token` is consumed
  3. Map to the appropriate Ansible lookup plugin (e.g., `community.hashi_vault.hashi_vault`, `amazon.aws.aws_secret`, `azure.azcollection.azure_keyvault_secret`) or implement a custom vars plugin

---

## Template Conversion Notes

No ERB templates are used in this module. The only dynamic file content is:
- `/var/lib/redis/health_check.json` — content is the JSON-serialized result of `myFunction1('http://localhost:8080/health')`. In Ansible, use `ansible.builtin.uri` to fetch the health check response, then `ansible.builtin.copy` with `content: "{{ health_check_result.json | to_json }}\n"` to write the file.

---

## PuppetDB Dependencies

- **PuppetDB query** in `manifests/init.pp`:
  - Query: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case3' }`
  - Returned data: list of all certnames (hostnames) in the Puppet catalog that have this profile applied; stored in `$redis_nodes` for cluster membership awareness
  - Migration notes: This cross-node inventory query has no direct built-in Ansible equivalent. Options:
    1. Use Ansible's dynamic inventory — group all Redis cluster nodes under a group (e.g., `redis_cluster_case3`) and reference `groups['redis_cluster_case3']` in playbooks
    2. Use `ansible.builtin.add_host` or a static `inventory/hosts` file to enumerate cluster members
    3. If using AWX/Tower, use smart inventories or inventory plugins to replicate the dynamic membership query

---

## Checks for the Migration

**Files to verify**:
- `/var/lib/redis/health_check.json` — exists, owned by `redis:redis`, mode `0644`, contains valid JSON
- `/opt/myapp/version.txt` — exists, contains `2.1.0`
- `/opt/myapp/` — directory exists with extracted application files
- `/var/log/redis` — directory exists, owned by `redis:redis`, mode `0755`
- `/etc/company/app.conf` — contains line `!app-mode=cluster` and line `!health-port=8080`

**Service endpoints to check**:
- Redis on port `6379`: `redis-cli -p 6379 -a CHANGEME ping` → should return `PONG`
- Health check endpoint: `curl -s http://localhost:8080/health` → should return valid JSON

**Templates rendered**: None (no ERB templates in this module)

## Pre-flight checks:
```bash
# Redis service status
systemctl status redis
redis-server --version

# Redis connectivity (replace CHANGEME with actual password)
redis-cli -p 6379 -a CHANGEME ping

# myapp deployment verification
stat /opt/myapp/version.txt
cat /opt/myapp/version.txt

# redis-backup cron entry
crontab -l -u root | grep redis-backup.sh

# CompanyApp settings entries
cat /etc/company/app.conf
grep -E '!app-mode=cluster' /etc/company/app.conf
grep -E '!health-port=8080' /etc/company/app.conf

# Redis log directory
stat /var/log/redis
ls -ld /var/log/redis

# Health check endpoint and JSON output
curl -s http://localhost:8080/health
cat /var/lib/redis/health_check.json

# Enterprise Scheduler registration (requires schedulerctl documentation — NOT SAFELY CONVERTIBLE)
/usr/local/bin/schedulerctl query redis-node

# Verify redis-backup script exists on host (not managed by this module)
stat /usr/local/bin/redis-backup.sh

# Verify schedulerctl binary exists on host
stat /usr/local/bin/schedulerctl
```