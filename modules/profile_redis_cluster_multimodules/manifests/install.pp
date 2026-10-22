class profile_redis_cluster::install {

  class { 'redis':
    bind           => '0.0.0.0',
    port           => $profile_redis_cluster::redis_port,
    requirepass    => $profile_redis_cluster::redis_password,
    maxmemory      => "${profile_redis_cluster::maxmemory_mb}mb",
    appendonly     => true,
    appendfsync    => 'everysec',
    manage_package => true,
  }

  file { '/var/log/redis':
    ensure => directory,
    owner  => 'redis',
    group  => 'redis',
    mode   => '0755',
  }
}
