---
source-path: .
---

# Migration Plan: profile_redis_cluster_case1

**TLDR**: This Puppet module deploys and configures a Redis instance as part of a cluster setup. It installs Redis via the `redis` community class with specific bind, port, password, memory, and persistence settings; creates a log directory; performs a PuppetDB query to discover all nodes in the cluster; runs a custom HTTP health-check function at catalog compile time; and enforces a runtime HTTP endpoint health check via a custom type/provider. A custom Facter fact (`redis_role`) determines whether the node is a primary or replica by inspecting `/etc/redis/conf.d/replica.conf`.

## Service Type and Instances

**Service Type**: In-memory Cache / Data Store (Redis Cluster Node)

**Configured Instances**:
- **redis** (single instance per node):
  - Bind Address: `0.0.0.0` (all interfaces)
  - Port: `6379`
  - Password: `CHANGEME` (plaintext default — must be replaced before production)
  - Max Memory: `2048mb`
  - Max Memory Policy: `allkeys-lru`
  - Persistence: AOF enabled (`appendonly: true`, `appendfsync: everysec`)
  - Log Directory: `/var/log/redis`

- **Health Check Endpoint**:
  - URL: `http://localhost:8080/health`
  - Checked at: catalog compile time (via `myFunction1`) AND enforced at runtime (via `myType1`)

## File Structure

```
manifests/
  init.pp                                  — entry class, PuppetDB query, health check function call, custom type resource, contains install
  install.pp                               — Redis class instantiation and log directory

lib/
  puppet/
    type/
      myType1.rb                           — custom type: HTTP endpoint ensurable resource
    provider/
      myType1/
        myProvider1.rb                     — provider: HTTP GET health check, fail-hard on non-2xx
    functions/
      myFunction1.rb                       — HTTP GET at compile time, returns parsed JSON or raw string body
  facter/
    redis_role.rb                          — determines redis_role fact (primary or replica) from /etc/redis/conf.d/replica.conf
```

## Module Explanation

The module performs operations in this order:

1. **profile_redis_cluster_case1** (`manifests/init.pp`):
   - Class parameters (with defaults):
     - `redis_port` = `6379` (Integer)
     - `redis_password` = `'CHANGEME'` (String — plaintext, no Sensitive[] wrapper, no eyaml encryption)
     - `maxmemory_mb` = `2048` (Integer)
     - `maxmemory_policy` = `'allkeys-lru'` (String)
   - **PuppetDB query** (compile-time): `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case1' }` — discovers all certnames that have this class applied; result stored in `$redis_nodes` as a list of Hashes with `certname` keys; used to build cluster peer awareness
   - **Custom function call** (compile-time): `myFunction1('http://localhost:8080/health')` — issues an HTTP GET to `http://localhost:8080/health`, returns parsed JSON or raw string body; raises `Puppet::Error` on non-2xx; result stored in `$health_check` (not used further in this manifest)
   - `myType1 'http://localhost:8080/health'` → `ensure: present` (default from `ensurable`): at runtime, provider `myProvider1` issues HTTP GET to `http://localhost:8080/health`; if response is non-2xx, `create` raises a hard error; `destroy` is a no-op
   - `contain profile_redis_cluster_case1::install` — fully contains the install class (ordering and notification boundary respected)

2. **profile_redis_cluster_case1::install** (`manifests/install.pp`):
   - `class { 'redis': }` (external/community class — assumed `puppet/redis` or `arioch/redis` from Puppet Forge; not analyzed):
     - `bind` → `'0.0.0.0'`
     - `port` → `6379` (resolved from `$profile_redis_cluster_case1::redis_port`)
     - `requirepass` → `'CHANGEME'` (resolved from `$profile_redis_cluster_case1::redis_password`)
     - `maxmemory` → `'2048mb'` (resolved from `"${profile_redis_cluster_case1::maxmemory_mb}mb"`)
     - `appendonly` → `true`
     - `appendfsync` → `'everysec'`
     - `manage_package` → `true` (the redis class installs the redis package)
   - `file { '/var/log/redis': }` → `ensure: directory`, `owner: redis`, `group: redis`, `mode: '0755'`

## Variables

**Variable Flow Summary**: 4 class parameters, no Hiera data files found. All values are hardcoded defaults in the manifest.

### Variable Definitions

**Class parameter defaults (`manifests/init.pp`)** → Migration note: All values are hardcoded manifest defaults; no Hiera hierarchy exists for this module. All must be explicitly defined in Ansible vars/defaults or Vault.
- `profile_redis_cluster_case1::redis_port`: `6379` (type: Integer)
- `profile_redis_cluster_case1::redis_password`: `'CHANGEME'` (type: String — **insecure plaintext default; must be migrated to Ansible Vault or external secrets manager**)
- `profile_redis_cluster_case1::maxmemory_mb`: `2048` (type: Integer)
- `profile_redis_cluster_case1::maxmemory_policy`: `'allkeys-lru'` (type: String)

**Runtime-derived variables** → Migration note: These are computed at Puppet catalog compile time and have no direct Hiera equivalent; Ansible equivalents require task-level computation.
- `$redis_nodes`: result of PuppetDB query — list of Hashes `[{ certname: '...' }]` for all nodes with this class applied
- `$health_check`: result of `myFunction1('http://localhost:8080/health')` — parsed JSON Hash/Array or raw String from health endpoint

### Variable Migration Summary

- **Common defaults**: 4 variables (all hardcoded in manifest, no Hiera)
- **OS-specific variables**: 0 variables
- **Environment-specific variables**: 0 variables
- **Host-specific variables**: 0 variables
- **Encrypted variables**: 0 variables (password is plaintext — **must be rotated and stored in Ansible Vault or an external secrets manager before migration**)

### Cross-Level Overrides

No cross-level overrides detected. No Hiera data files exist for this module.

### Merge Strategy Notes

No Hiera merge strategies apply. All variables are single-level manifest defaults with no layered overrides.

## Custom Types and Providers

### myType1 (`lib/puppet/type/myType1.rb`)
- **Purpose**: Ensurable HTTP endpoint resource. Namevar is `url` (must match `/\Ahttps?:///`).
- **Parameters**:
  - `url` (namevar, String): target URL, validated against regex `\Ahttps?:///`
  - `ensure` (Enum[present, absent]): standard ensurable lifecycle
- **Ansible equivalent**: `ansible.builtin.uri` module with `method: GET` and `status_code` assertion. No custom module needed.

### myProvider1 (`lib/puppet/provider/myType1/myProvider1.rb`)
- **Purpose**: Implements `myType1` lifecycle via HTTP GET using Ruby `Net::HTTP`.
  - `exists?` → returns `true` if HTTP response is 2xx, `false` on failure or exception
  - `create` → raises hard error if `exists?` is false (URL unreachable)
  - `destroy` → no-op (resource represents a connectivity check, not a managed artifact)
- **Ansible equivalent**:
  ```yaml
  - name: Check URL reachability
    ansible.builtin.uri:
      url: "http://localhost:8080/health"
      method: GET
      status_code: [200, 201, 202, 204]
  ```
  The default `failed_when` behavior (non-2xx = failure) replicates the `create` raise exactly.

### redis_role fact (`lib/facter/redis_role.rb`)
- **Purpose**: Sets `redis_role` to `'replica'` if `/etc/redis/conf.d/replica.conf` exists AND contains the string `'replicaof'`; otherwise sets it to `'primary'`. Confined to Linux only (via `kernel` fact).
- **Used in**: Not directly referenced in the analyzed manifests, but available to any class or template that needs to branch on node role.
- **Ansible equivalent**:
  ```yaml
  - name: Check replica config existence
    ansible.builtin.stat:
      path: /etc/redis/conf.d/replica.conf
    register: replica_conf_stat

  - name: Read replica config contents
    ansible.builtin.slurp:
      src: /etc/redis/conf.d/replica.conf
    register: replica_conf_content
    when: replica_conf_stat.stat.exists

  - name: Set redis_role fact
    ansible.builtin.set_fact:
      redis_role: >-
        {{ 'replica'
           if (replica_conf_stat.stat.exists and
               'replicaof' in (replica_conf_content.content | b64decode))
           else 'primary' }}
  ```

### myFunction1 (`lib/puppet/functions/myFunction1.rb`)
- **Purpose**: Compile-time HTTP GET to a URL; returns parsed JSON (Hash/Array) or raw String body; raises `Puppet::Error` on non-2xx.
- **Called with**: `'http://localhost:8080/health'`
- **Ansible equivalent**:
  ```yaml
  - name: Fetch health check endpoint
    ansible.builtin.uri:
      url: "http://localhost:8080/health"
      method: GET
      return_content: true
    register: health_check
  ```
  The `uri` module auto-parses JSON into `health_check.json`; raw body is in `health_check.content`. Non-2xx raises a task failure by default.

## Dependencies

**External module dependencies**:
- `redis` class (referenced in `manifests/install.pp`) — no Puppetfile found; assumed to be a Puppet Forge module (e.g., `puppet/redis` or `arioch/redis`). Must be identified and its Ansible equivalent located (e.g., a community Redis role from Ansible Galaxy).

**System package dependencies**:
- Redis server package — managed by the `redis` class (`manage_package: true`); exact package name depends on the `redis` module implementation (typically `redis` or `redis-server` depending on OS).

**Service dependencies**:
- The `redis` class (not analyzed) is expected to manage the `redis` service (start/enable).
- `file['/var/log/redis']` has no explicit ordering relationship with `class['redis']` in the manifest — ordering is implicit via catalog compilation.

## Puppet Facts Used

- `kernel` — used by `redis_role` fact confinement; ensures the fact only runs on Linux nodes
- `redis_role` — custom fact; value is `'primary'` or `'replica'`; derived from presence and content of `/etc/redis/conf.d/replica.conf`; available for use in manifests/templates but not directly referenced in the analyzed execution tree

## Template Conversion Notes

No ERB or EPP templates are used directly in this module's manifests. Template rendering is delegated entirely to the external `redis` class.

## PuppetDB Dependencies

**PuppetDB query in `manifests/init.pp`**:
- **Query**: `resources[certname] { type = 'Class' and title = 'Profile_redis_cluster_case1' }`
- **Purpose**: Discovers all cluster peer nodes that have this profile applied; result stored in `$redis_nodes`
- **Migration note**: This is a significant dependency. Ansible has no native equivalent to PuppetDB's exported resource/query mechanism. The query performs cross-node discovery at catalog compile time; in Ansible this must be replaced with inventory group membership or runtime `hostvars` introspection.
- **Ansible equivalent strategies**:
  - Use Ansible's dynamic inventory with group membership — nodes in the same inventory group replace the PuppetDB certname list
  - Use `ansible.builtin.set_fact` with `hostvars` and `groups['redis_cluster']` to build a peer list at playbook runtime:
    ```yaml
    - name: Build redis cluster peer list
      ansible.builtin.set_fact:
        redis_nodes: "{{ groups['redis_cluster'] | map('extract', hostvars, 'inventory_hostname') | list }}"
    ```
  - If cross-node discovery is needed dynamically, use `ansible.builtin.add_host` or a custom inventory plugin

## Checks for the Migration

**Files to verify**:
- `/var/log/redis` — directory, owner: `redis`, group: `redis`, mode: `0755`
- `/etc/redis/conf.d/replica.conf` — presence and content determine `redis_role` fact value
- Redis configuration file (path determined by the `redis` class, typically `/etc/redis/redis.conf` or `/etc/redis.conf`)

**Service endpoints to check**:
- Redis: `localhost:6379` — authenticate with password `CHANGEME` (replace before production)
- Health check: `http://localhost:8080/health` — must return HTTP 2xx

**Templates rendered**: None directly in this module.

## Pre-flight checks:
```bash
# Redis service status
systemctl status redis

# Redis instance connectivity (replace CHANGEME with actual password before production)
redis-cli -p 6379 -a CHANGEME ping
# Expected output: PONG

# Health check endpoint
curl -f http://localhost:8080/health
# Expected: HTTP 2xx response

# Log directory ownership and permissions
ls -la /var/log/redis
# Expected: drwxr-xr-x redis redis /var/log/redis

# Node role determination
cat /etc/redis/conf.d/replica.conf | grep replicaof
# If output contains 'replicaof': node is replica
# If file absent or no match: node is primary

# Redis configuration validation
redis-cli -p 6379 -a CHANGEME CONFIG GET maxmemory
# Expected: 2147483648 (2048mb in bytes)

redis-cli -p 6379 -a CHANGEME CONFIG GET appendonly
# Expected: yes

redis-cli -p 6379 -a CHANGEME CONFIG GET appendfsync
# Expected: everysec
```