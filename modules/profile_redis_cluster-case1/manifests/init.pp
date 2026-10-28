class profile_redis_cluster_case1 (
  Integer $redis_port       = 6379,
  String  $redis_password   = 'CHANGEME',
  Integer $maxmemory_mb     = 2048,
  String  $maxmemory_policy = 'allkeys-lru',
) {

  $redis_nodes = puppetdb_query(
    "resources[certname] {
      type = 'Class' and
      title = 'Profile_redis_cluster_case1'
    }"
  )

  $health_check = myFunction1('http://localhost:8080/health')

  myType1 { 'http://localhost:8080/health': }

  contain profile_redis_cluster_case1::install
}
