---
source-path: .
---

# Migration Plan: role::app_server / profile_app_stack

**TLDR**: This Puppet role deploys a full Python web application stack on a single server. It installs a Python runtime and virtualenv, optionally provisions a local PostgreSQL database (with APT repo, packages, user/DB creation, and a suite of custom-type resources for deployment tracking, secret registration, and config-file management), clones the application from Git, installs pip dependencies, writes a `.env` file, creates a systemd unit, and sets up monitoring (Prometheus exporters realized only in production via spaceship collectors) plus logrotate and cron-based health checks. The role also includes a base profile (NTP via chrony, syslog via rsyslog) and references an unanalyzed HAProxy and Redis profile. Two custom types (`myFormatType1`, `mySecretType1`) and one custom function (`mySecretFunction1`) are **not safely convertible** without proprietary documentation.

---

## Service Type and Instances

**Service Type**: Python Web Application Server (gunicorn/uvicorn) with optional local PostgreSQL database

**Configured Instances**:

- **myapp-api** (module default; overridden to `test-app` in env common.yaml):
  - Location/Path: `/opt/myapp-api` (module default; env override: `/opt/test-app`)
  - Port/Socket: `8000` (TCP, all interfaces)
  - Key Config: gunicorn, 2 workers (staging: 1, production: 8), worker class `uvicorn.workers.UvicornWorker` (env override: `sync`), max_requests 1000 (staging: 100, production: 5000), graceful_timeout 30s
  - Systemd unit: `/etc/systemd/system/myapp-api.service`
  - Environment file: `/opt/myapp-api/.env`
  - Log directory: `/var/log/myapp-api` (env override: `/var/log/test-app`)

- **PostgreSQL** (local, when `db_host == 'localhost'`):
  - Version: `15` (env-level override of module default `16`)
  - Packages: `postgresql-15`, `postgresql-contrib-15`, `libpq-dev`
  - Service: `postgresql`
  - APT repo: `https://apt.postgresql.org/pub/repos/apt` (pgdg)
  - Database: `myapp_db` (env override: `testdb`), owner: `myapp_app` (env override: `testuser`)

---

## File Structure

```
../../site-modules/role/manifests/app_server.pp
../../site-modules/profile/manifests/app/stack.pp
../../site-modules/profile/manifests/base/base.pp
../../site-modules/profile_app_stack/manifests/init.pp
../../site-modules/profile_app_stack/manifests/python.pp
../../site-modules/profile_app_stack/manifests/database.pp
../../site-modules/profile_app_stack/manifests/app.pp
../../site-modules/profile_app_stack/manifests/service.pp
../../site-modules/profile_app_stack/manifests/monitoring.pp
../../site-modules/profile_postgresql/manifests/init.pp
../../site-modules/profile_postgresql/manifests/repo.pp
../../site-modules/profile_postgresql/manifests/install.pp
../../site-modules/profile_postgresql/manifests/service.pp

../../site-modules/profile_app_stack/templates/logrotate.conf.erb
../../site-modules/profile_app_stack/templates/app.env.erb
../../site-modules/profile_app_stack/templates/app.service.epp

../../site-modules/profile_app_stack/data/common.yaml
../../site-modules/profile_app_stack/data/environment/production.yaml
../../site-modules/profile_app_stack/data/environment/staging.yaml
../../site-modules/profile_postgresql/data/common.yaml
../../site-modules/profile_postgresql/data/os/Debian.yaml
../../data/common.yaml
../../data/environment/production.yaml
../../data/environment/staging.yaml

lib/puppet/type/myCronType1.rb
lib/puppet/type/myDeploy1.rb
lib/puppet/type/myFormatType1.rb
lib/puppet/type/mySecretType1.rb
lib/puppet/provider/myCronType1/myCronProvider1.rb
lib/puppet/provider/myDeploy1/myDeployProvider.rb
lib/puppet/provider/myFormatType1/myFormatProvider1.rb
lib/puppet/provider/mySecretType1/mySecretProvider1.rb
lib/facter/postgres_role.rb
lib/puppet/functions/myFunction1.rb
lib/puppet/functions/mySecretFunction1.rb
```

---

## Module Explanation

The module performs operations in this order:

### 1. **role::app_server** (`../../site-modules/role/manifests/app_server.pp`)
- `include profile::base::base`
- `include profile::loadbalancer::haproxy` *(class not analyzed — not in scope)*
- `include profile::app::stack`
- `include profile::cache::redis` *(class not analyzed — not in scope)*

---

### 2. **profile::base::base** (`../../site-modules/profile/manifests/base/base.pp`)
- **Conditional** `if $manage_utils` → `include base_utils` *(class not analyzed)*
- **Conditional** `if $manage_ntp and $facts['kernel'] == 'Linux'`:
  - `package 'chrony'` → ensure: `installed`
  - `service 'chronyd'` → ensure: `running`, enable: `true`
- **Conditional** `if $manage_syslog and $facts['kernel'] == 'Linux'`:
  - `package 'rsyslog'` → ensure: `installed`
  - `service 'rsyslog'` → ensure: `running`, enable: `true`
- **Fact used**: `$facts['kernel']` — must equal `'Linux'` for NTP/syslog resources to apply

---

### 3. **profile::app::stack** (`../../site-modules/profile/manifests/app/stack.pp`)
- Sets `$environment_name` via `fact('environment')` — stdlib built-in function call (see Custom Functions Used)
- `include profile_app_stack`

---

### 4. **profile_app_stack** (`../../site-modules/profile_app_stack/manifests/init.pp`)
- Resolves all class parameters from Hiera (see Variables section for effective values per environment)
- Calls custom function `profile_app_stack::app_db_url($db_user, $db_password, $db_host, $db_port, $db_name)` → builds `$db_url` string (e.g., `postgresql://myapp_app:<password>@localhost:5432/myapp_db`)
- `contain profile_app_stack::python`
- `contain profile_app_stack::database`
- `contain profile_app_stack::app`
- `contain profile_app_stack::service`
- `contain profile_app_stack::monitoring`
- Ordering chain:
  - `profile_app_stack::python` → `profile_app_stack::database` → `profile_app_stack::app` ~> `profile_app_stack::service` → `profile_app_stack::monitoring`
  - (`~>` means app changes notify/restart service)

---

### 5. **profile_app_stack::python** (`../../site-modules/profile_app_stack/manifests/python.pp`)

Resolves local variables:
- `$python_version` = `python3` (from Hiera `profile_app_stack::python_version`)
- `$pip_packages` = `['uvicorn', 'gunicorn', 'psycopg2-binary']` (from Hiera `profile_app_stack::pip_packages`)
- `$log_max_size` = `100M` (Hiera default)
- `$log_rotate_count` = `7` (Hiera default)
- `$log_dir` = `/var/log/myapp-api` (module default; env override: `/var/log/test-app`)
- `$app_name` = `myapp-api` (module default; env override: `test-app`)

**Package installation** — `$python_packages` array expands to 6 items:
- `package 'python3'` → ensure: `installed`
- `package 'python3-pip'` → ensure: `installed`
- `package 'python3-venv'` → ensure: `installed`
- `package 'python3-dev'` → ensure: `installed`
- `package 'git'` → ensure: `installed`
- `package 'build-essential'` → ensure: `installed`

**User/group setup**:
- `group 'myapp'` (env override: `appuser`) → ensure: `present`, system: `true`
- `user 'myapp'` (env override: `appuser`) → ensure: `present`, gid: `myapp`/`appuser`, home: `/opt/myapp-api`/`/opt/test-app`, shell: `/bin/bash`, system: `true`, managehome: `false`, require: `Group[myapp/appuser]`

**Log directory**:
- `file '/var/log/myapp-api'` (env override: `/var/log/test-app`) → ensure: `directory`, owner: `myapp`/`appuser`, group: `myapp`/`appuser`, mode: `0755`

**Logrotate config** (template rendered once):
- `file '/etc/logrotate.d/myapp-api'` (env override: `/etc/logrotate.d/test-app`) → ensure: `file`, owner: `root`, group: `root`, mode: `0644`
  - Template: `profile_app_stack/logrotate.conf.erb`
  - Variables passed (resolved from scope):
    - `@log_dir` = `/var/log/myapp-api` (env: `/var/log/test-app`)
    - `@log_rotate_count` = `7`
    - `@log_max_size` = `100M`
    - `@app_name` = `myapp-api` (env: `test-app`)
  - Rendered output: rotates `*.log` daily, keeps 7 copies, compress+delaycompress, maxsize 100M, postrotate: `systemctl reload myapp-api 2>/dev/null || true`

---

### 6. **profile_app_stack::database** (`../../site-modules/profile_app_stack/manifests/database.pp`)

**Conditional**: `if $profile_app_stack::db_host == 'localhost'`

- **In staging** (`db_host = 'localhost'`): condition is TRUE → PostgreSQL is installed locally
- **In production** (`db_host = 'db-primary.prod.internal'`): condition is FALSE → PostgreSQL block is skipped entirely; only the backup script and cron are created

**When condition is TRUE** (staging / default):

#### 6a. **profile_postgresql** (`../../site-modules/profile_postgresql/manifests/init.pp`)

Resolves class parameters:
- `$version` = `15` (env-level common.yaml overrides module default `16`)
- `$package_names` = `['postgresql-15', 'postgresql-contrib-15']` (Debian.yaml with `%{lookup('profile_postgresql::version')}` interpolated to `15`)
- `$service_name` = `postgresql`

**Custom function call**:
- `$health_check = myFunction1('http://localhost:8080/health')` → performs HTTP GET, returns parsed JSON body

**File**:
- `file '/var/lib/pgsql/health_check.json'` → ensure: `file`, owner: `postgres`, group: `postgres`, mode: `0644`, content: JSON-serialized result of `myFunction1('http://localhost:8080/health')`

**Custom type** `myDeploy1`:
- `myDeploy1 'myapp'` → version: `2.1.0`, url: `http://artifacts.internal/myapp-2.1.0.tar.gz`, install_dir: `/opt/myapp`
  - Downloads artifact, extracts to `/opt/myapp`, writes `/opt/myapp/version.txt` = `2.1.0`; idempotent via version.txt comparison

**Custom function call**:
- `$service_token = mySecretFunction1('postgres_service_token')` → fetches secret from proprietary `CompanyInternal::SecretStore` — **⚠ NOT SAFELY CONVERTIBLE**

**Custom type** `mySecretType1`:
- `mySecretType1 'postgres-node'` → schedule: `daily`
  - Registers this node in Enterprise Scheduler platform via `schedulerctl register postgres-node --schedule daily` — **⚠ NOT SAFELY CONVERTIBLE**

**Custom type** `myFormatType1` (×2):
- `myFormatType1 'app-mode'` → file: `/etc/company/app.conf`, value: `cluster`
  - Writes `!app-mode=cluster` into `/etc/company/app.conf` — **⚠ NOT SAFELY CONVERTIBLE** (proprietary format)
- `myFormatType1 'health-port'` → file: `/etc/company/app.conf`, value: `8080`
  - Writes `!health-port=8080` into `/etc/company/app.conf` — **⚠ NOT SAFELY CONVERTIBLE** (proprietary format)

**Custom type** `myCronType1`:
- `myCronType1 'postgres-backup'` → command: `/usr/local/bin/postgres-backup.sh`, hour: `2`, minute: `30`
  - Adds root crontab entry: `30 2 * * * /usr/local/bin/postgres-backup.sh`

**Ordering**: `profile_postgresql::repo` → `profile_postgresql::install` → `profile_postgresql::service`

##### 6a-i. **profile_postgresql::repo** (`../../site-modules/profile_postgresql/manifests/repo.pp`)
- `include apt` *(class not analyzed)*
- `apt::source 'pgdg'`:
  - location: `https://apt.postgresql.org/pub/repos/apt` (from `profile_postgresql::repo_location`)
  - release: `<distro_codename>-pgdg` (from `profile_postgresql::repo_release`, uses `%{facts.os.distro.codename}` interpolation — e.g., `jammy-pgdg` on Ubuntu 22.04)
  - repos: `main`
  - key id: value from `profile_postgresql::repo_key_id` (Debian.yaml)
  - key source: value from `profile_postgresql::repo_key_source` (Debian.yaml)

##### 6a-ii. **profile_postgresql::install** (`../../site-modules/profile_postgresql/manifests/install.pp`)
- `package 'postgresql-15'` → ensure: `installed`
- `package 'postgresql-contrib-15'` → ensure: `installed`
- `package 'libpq-dev'` → ensure: `installed`

##### 6a-iii. **profile_postgresql::service** (`../../site-modules/profile_postgresql/manifests/service.pp`)
- `service 'postgresql'` → ensure: `running`, enable: `true`

**Back in profile_app_stack::database** (after profile_postgresql, still inside `db_host == 'localhost'` block):

- `exec 'create_db_user'`:
  - command: `sudo -u postgres psql -c "CREATE USER myapp_app WITH PASSWORD 'test-db-password';"` (env values; production: `myapp_app` / encrypted password)
  - unless: `sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='myapp_app'" | grep -q 1`
  - path: `/usr/bin:/bin`
  - require: `Class['profile_postgresql::service']`

- `exec 'create_database'`:
  - command: `sudo -u postgres psql -c "CREATE DATABASE testdb OWNER myapp_app;"` (env: `testdb`; module default: `myapp_db`)
  - unless: `sudo -u postgres psql -tAc "SELECT 1 FROM pg_catalog.pg_database WHERE datname='testdb'" | grep -q 1`
  - path: `/usr/bin:/bin`
  - require: `Exec['create_db_user']`

- `exec 'grant_db_privileges'`:
  - command: `sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE testdb TO myapp_app;"`
  - unless: `sudo -u postgres psql -tAc "SELECT has_database_privilege('myapp_app', 'testdb', 'CREATE')" | grep -q t`
  - path: `/usr/bin:/bin`
  - require: `Exec['create_database']`

**Always applied** (outside the localhost conditional):

- `file '/usr/local/bin/db-backup.sh'` → ensure: `file`, source: `puppet:///modules/profile_app_stack/backup.sh`, owner: `root`, group: `myapp`/`appuser`, mode: `0750`

- `cron 'database_backup'`:
  - command: `/usr/local/bin/db-backup.sh testdb localhost` (env values; production: `myapp_db db-primary.prod.internal`)
  - user: `root`, hour: `2`, minute: `30`

---

### 7. **profile_app_stack::app** (`../../site-modules/profile_app_stack/manifests/app.pp`)

Resolves local variables:
- `$python_version` = `python3`
- `$pip_packages` = `['uvicorn', 'gunicorn', 'psycopg2-binary']` (from Hiera)
- `$db_url` = `postgresql://myapp_app:test-db-password@localhost:5432/testdb` (env; production: `postgresql://myapp_app:<secret>@db-primary.prod.internal:5432/myapp_db`)

**App directory**:
- `file '/opt/myapp-api'` (env: `/opt/test-app`) → ensure: `directory`, owner: `myapp`/`appuser`, group: `myapp`/`appuser`, mode: `0755`

**Git clone**:
- `vcsrepo '/opt/myapp-api'` (env: `/opt/test-app`) → ensure: `latest`, provider: `git`, source: `https://github.com/example-org/myapp-api.git` (env: `file:///tmp/test-app-repo`), revision: `main` (staging: `main`, production: `v2.4.1`), user: `myapp`/`appuser`, require: `[User[myapp/appuser], File[/opt/myapp-api]]`

**Virtualenv creation**:
- `exec 'create_app_venv'`:
  - command: `python3 -m venv /opt/myapp-api/venv` (env: `/opt/test-app/venv`)
  - creates: `/opt/myapp-api/venv/bin/activate`
  - user: `myapp`/`appuser`
  - path: `/usr/bin:/usr/local/bin:/bin`
  - require: `Vcsrepo[/opt/myapp-api]`

**Requirements install**:
- `exec 'install_requirements'`:
  - command: `/opt/myapp-api/venv/bin/pip install -r /opt/myapp-api/requirements.txt`
  - cwd: `/opt/myapp-api`
  - user: `myapp`/`appuser`
  - unless: `/opt/myapp-api/venv/bin/pip freeze | diff - /opt/myapp-api/requirements.txt > /dev/null 2>&1`
  - require: `[Vcsrepo[/opt/myapp-api], Exec['create_app_venv']]`
  - **notifies**: `Class['profile_app_stack::service']`

**Extra pip packages** — `$pip_packages` = `['uvicorn', 'gunicorn', 'psycopg2-binary']` — loop runs **3 times**:

- **uvicorn**:
  - `exec 'install_pip_uvicorn'` → command: `/opt/myapp-api/venv/bin/pip install uvicorn`, unless: `/opt/myapp-api/venv/bin/pip show uvicorn`, user: `myapp`/`appuser`, require: `Exec['create_app_venv']`

- **gunicorn**:
  - `exec 'install_pip_gunicorn'` → command: `/opt/myapp-api/venv/bin/pip install gunicorn`, unless: `/opt/myapp-api/venv/bin/pip show gunicorn`, user: `myapp`/`appuser`, require: `Exec['create_app_venv']`

- **psycopg2-binary**:
  - `exec 'install_pip_psycopg2-binary'` → command: `/opt/myapp-api/venv/bin/pip install psycopg2-binary`, unless: `/opt/myapp-api/venv/bin/pip show psycopg2-binary`, user: `myapp`/`appuser`, require: `Exec['create_app_venv']`

**Environment file** (template rendered once):
- `file '/opt/myapp-api/.env'` (env: `/opt/test-app/.env`) → ensure: `file`, owner: `myapp`/`appuser`, group: `myapp`/`appuser`, mode: `0600`
  - Template: `profile_app_stack/app.env.erb`
  - Variables (resolved):
    - `@db_url` = `postgresql://myapp_app:test-db-password@localhost:5432/testdb` (env; production uses encrypted password and remote host)
    - `@app_name` = `myapp-api` (env: `test-app`)
    - `@app_port` = `8000`
    - `@secret_key` = `changeme` (default fallback; staging: `staging-not-secret-at-all`; production: ENC[PKCS7,...ProdSecret])
    - `@log_level` = `info` (staging: `debug`; production: `warning`)
    - `@log_dir` = `/var/log/myapp-api` (env: `/var/log/test-app`)
    - `@worker_count` = `2` (staging: `1`; production: `8`)
    - `@facts['environment']` — conditional: production renders `DEBUG=false`, `CORS_ORIGINS=https://app.example.com,https://admin.example.com`; all other environments render `DEBUG=true`, `CORS_ORIGINS=*`
  - **notifies**: `Class['profile_app_stack::service']`

**Health check script**:
- `file '/usr/local/bin/app-healthcheck.sh'` → ensure: `file`, source: `puppet:///modules/profile_app_stack/healthcheck.sh`, owner: `root`, group: `root`, mode: `0755`

**DB migrations**:
- `exec 'run_db_migrations'`:
  - command: `/opt/myapp-api/venv/bin/python -m alembic upgrade head`
  - cwd: `/opt/myapp-api`
  - user: `myapp`/`appuser`
  - environment: `DATABASE_URL=postgresql://myapp_app:test-db-password@localhost:5432/testdb`
  - onlyif: `test -f /opt/myapp-api/migrations/env.py`
  - refreshonly: `true` (only runs when `Vcsrepo[/opt/myapp-api]` changes)
  - subscribe: `Vcsrepo[/opt/myapp-api]`

---

### 8. **profile_app_stack::service** (`../../site-modules/profile_app_stack/manifests/service.pp`)

**Systemd unit file** (EPP template rendered once):
- `file '/etc/systemd/system/myapp-api.service'` (env: `/etc/systemd/system/test-app.service`) → ensure: `file`, owner: `root`, group: `root`, mode: `0644`
  - Template: `profile_app_stack/app.service.epp`
  - Variables passed (resolved):
    - `$app_name` = `myapp-api` (env: `test-app`)
    - `$app_dir` = `/opt/myapp-api` (env: `/opt/test-app`)
    - `$app_user` = `myapp` (env: `appuser`)
    - `$app_group` = `myapp` (env: `appuser`)
    - `$app_port` = `8000`
    - `$worker_count` = `2` (staging: `1`; production: `8`)
    - `$worker_class` = `uvicorn.workers.UvicornWorker` (env override: `sync`)
    - `$max_requests` = `1000` (staging: `100`; production: `5000`)
    - `$graceful_timeout` = `30`
    - `$log_dir` = `/var/log/myapp-api` (env: `/var/log/test-app`)
    - `$log_level` = `info` (staging: `debug`; production: `warning`)
  - Rendered: systemd `[Service]` with `ExecStart=/opt/myapp-api/venv/bin/gunicorn --bind 0.0.0.0:8000 --workers 2 --worker-class uvicorn.workers.UvicornWorker --max-requests 1000 --max-requests-jitter 50 --graceful-timeout 30 ... app.main:app`
  - `TimeoutStopSec` = `35` (graceful_timeout + 5)
  - Security: `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `ReadWritePaths=/opt/myapp-api /var/log/myapp-api`, `PrivateTmp=true`
  - **notifies**: `Exec['systemd_daemon_reload']`

- `exec 'systemd_daemon_reload'`:
  - command: `systemctl daemon-reload`
  - path: `/usr/bin:/bin`
  - refreshonly: `true` (only runs when notified by file above)

- `service 'myapp-api'` (env: `test-app`) → ensure: `running`, enable: `true`
  - require: `[File[/etc/systemd/system/myapp-api.service], Exec['systemd_daemon_reload']]`
  - subscribe: `File[/opt/myapp-api/.env]` (restarts when `.env` changes)

---

### 9. **profile_app_stack::monitoring** (`../../site-modules/profile_app_stack/manifests/monitoring.pp`)

**Virtual/exported resources** (declared but not applied unless collected):
- `@package 'prometheus-node-exporter'` → ensure: `installed`
- `@service 'prometheus-node-exporter'` → ensure: `running`, enable: `true`, require: `Package['prometheus-node-exporter']`
- `@package 'prometheus-pushgateway'` → ensure: `installed`
- `@cron 'push_app_metrics'` → command: `/usr/local/bin/app-healthcheck.sh --push-metrics`, user: `myapp`/`appuser`, minute: `*/5`, require: `[Package['prometheus-pushgateway'], File['/usr/local/bin/app-healthcheck.sh']]`

**Conditional** `if $facts['environment'] == 'production'` → resources are **collected via spaceship collectors** (`<<| |>>`):
- `<<| |>>` on `Package` (prometheus-node-exporter)
- `<<| |>>` on `Service` (prometheus-node-exporter)
- `<<| |>>` on `Package` (prometheus-pushgateway)
- `<<| |>>` on `Cron` (push_app_metrics)

**⚠ Migration note**: Spaceship collectors (`<<| |>>`) realize exported resources from PuppetDB. In non-production environments, all four resources are declared but never collected — they have no effect. See PuppetDB Dependencies section for migration implications.

**Always applied** (regardless of environment):
- `cron 'app_health_check'`:
  - command: `/usr/local/bin/app-healthcheck.sh http://localhost:8000/health`
  - user: `root`
  - minute: `*/2`

---

## Variables

**Variable Flow Summary**: 28 variables across 7 Hiera levels (2 module-level, 2 module environment-scoped, 1 env/control-repo common, 2 env/control-repo environment-scoped)

### Variable Definitions

**`../../site-modules/profile_app_stack/data/common.yaml`** → Migration note: Module-level base defaults for all nodes; lowest priority, mostly masked at runtime by environment-level overrides
- `profile_app_stack::app_name`: `myapp-api` (type: string)
- `profile_app_stack::app_repo`: `https://github.com/example-org/myapp-api.git` (type: string)
- `profile_app_stack::app_revision`: `main` (type: string)
- `profile_app_stack::app_port`: `8000` (type: integer)
- `profile_app_stack::app_dir`: `/opt/myapp-api` (type: string)
- `profile_app_stack::app_user`: `myapp` (type: string)
- `profile_app_stack::app_group`: `myapp` (type: string)
- `profile_app_stack::python_version`: `python3` (type: string)
- `profile_app_stack::pip_packages`: `['uvicorn', 'gunicorn', 'psycopg2-binary']` (type: array of string)
- `profile_app_stack::db_host`: `localhost` (type: string)
- `profile_app_stack::db_port`: `5432` (type: integer)
- `profile_app_stack::db_name`: `myapp_db` (type: string)
- `profile_app_stack::db_user`: `myapp_app` (type: string)
- `profile_app_stack::db_password`: `ENC[PKCS7,...]` (type: string, eyaml-encrypted — **never effective at runtime in this repo; overridden at all environment levels**)
- `profile_app_stack::worker_count`: `2` (type: integer)
- `profile_app_stack::worker_class`: `uvicorn.workers.UvicornWorker` (type: string)
- `profile_app_stack::max_requests`: `1000` (type: integer)
- `profile_app_stack::graceful_timeout`: `30` (type: integer)
- `profile_app_stack::log_dir`: `/var/log/myapp-api` (type: string)
- `profile_app_stack::log_level`: `info` (type: string)
- `profile_app_stack::log_max_size`: `100M` (type: string)
- `profile_app_stack::log_rotate_count`: `7` (type: integer)

**`../../site-modules/profile_app_stack/data/environment/production.yaml`** → Migration note: Module-level production overrides; applied when environment == production
- `profile_app_stack::app_revision`: `v2.4.1` (type: string)
- `profile_app_stack::db_host`: `db-primary.prod.internal` (type: string)
- `profile_app_stack::db_port`: `5432` (type: integer)
- `profile_app_stack::worker_count`: `8` (type: integer)
- `profile_app_stack::max_requests`: `5000` (type: integer)
- `profile_app_stack::log_level`: `warning` (type: string)
- `profile_app_stack::db_password`: `ENC[PKCS7,...ProdSecret]` (type: string, eyaml-encrypted)
- `profile_app_stack::secret_key`: `ENC[PKCS