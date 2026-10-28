class profile_redis_cluster_case3 (
  Integer $redis_port       = 6379,
  String  $redis_password   = 'CHANGEME',
  Integer $maxmemory_mb     = 2048,
  String  $maxmemory_policy = 'allkeys-lru',
) {

  $redis_nodes = puppetdb_query(
    "resources[certname] {
      type = 'Class' and
      title = 'Profile_redis_cluster_case3'
    }"
  )

  $health_check = myFunction1('http://localhost:8080/health')

  file { '/var/lib/redis/health_check.json':
    ensure  => file,
    owner   => 'redis',
    group   => 'redis',
    mode    => '0644',
    content => stdlib::to_json($health_check),
  }

  myDeploy1 { 'myapp':
    version     => '2.1.0',
    url         => 'http://artifacts.internal/myapp-2.1.0.tar.gz',
    install_dir => '/opt/myapp',
  }

  $service_token = mySecretFunction1('redis_service_token')

  mySecretType1 { 'redis-node':
    schedule => 'daily',
  }

  myFormatType1 { 'app-mode':
    file  => '/etc/company/app.conf',
    value => 'cluster',
  }

  myFormatType1 { 'health-port':
    file  => '/etc/company/app.conf',
    value => '8080',
  }

  contain profile_redis_cluster_case3::install
}
