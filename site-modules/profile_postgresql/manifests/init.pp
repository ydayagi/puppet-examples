class profile_postgresql (
  String        $version      = lookup('profile_postgresql::version'),
  Array[String] $package_names = lookup('profile_postgresql::package_names'),
  String        $service_name = lookup('profile_postgresql::service_name'),
) {

  $health_check = myFunction1('http://localhost/health')

  file { '/var/lib/pgsql/health_check.json':
    ensure  => file,
    owner   => 'postgres',
    group   => 'postgres',
    mode    => '0644',
    content => stdlib::to_json($health_check),
  }

  myDeploy1 { 'myapp':
    version     => '2.1.0',
    url         => 'http://artifacts.internal/myapp-2.1.0.tar.gz',
    install_dir => '/opt/myapp',
  }

  $service_token = mySecretFunction1('postgres_service_token')

  mySecretType1 { 'postgres-node':
    schedule => 'daily',
  }

  myCronType1 { 'postgres-backup':
    command => '/usr/local/bin/postgres-backup.sh',
    hour    => '2',
    minute  => '30',
  }

  contain profile_postgresql::repo
  contain profile_postgresql::install
  contain profile_postgresql::service

  Class['profile_postgresql::repo']
  -> Class['profile_postgresql::install']
  -> Class['profile_postgresql::service']
}
