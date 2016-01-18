# -*- mode: ruby -*-
# vi: set ft=ruby :
class wordpress::config {
  # General configuration

  Exec { path => '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' }

}

class wordpress {
  #include timezone
  #include keys
  #include user
  #include mysql
  #include php_install
  #include software
  
  # PHP
  include php
  include php::apt
  include php::params
  include php::pear
  
  class timezone inherits wordpress::config {
  
    package { "language-pack-pt":
      ensure => latest,
    } 
  
    class { 'locales':
      default_locale  => $default_locale,
      locales         => Array[$locales],
      require         => Package['language-pack-pt']
    }
  
  }

  class keys inherits wordpress::config {
    # Add here your login keys
  }
  
  class user inherits wordpress::config {

    exec { 'add user':
      command => "sudo useradd -m -G sudo -s /bin/bash ${user}",
      unless => "id -u ${user}"
    }
  
    exec { 'set password':
      command => "echo \"${user}:${password}\" | sudo chpasswd",
      require => Exec['add user']
    }
  
    # Prepare user's project directories
    file { "storage":
      path => "/storage",
      ensure => directory,
      require => Exec['add user']
    }

    file { ["/home/${user}",
            "/storage/${user}",
            "/storage/${user}/projects",
            "/storage/${user}/public_html",
            "/storage/${user}/arquivos",
            ]:
      ensure => directory,
      owner => "${user}",
      group => "${user}",
      require => File['storage']
    }
  
    # Variavel de ambiente do composer
    file { "user-profile":
      path => "/home/${user}/.profile",
      owner => $user,
      group => $user,
      content => inline_template("COMPOSER_HOME=/home/${user}/.composer"),
      require => Exec['add user']
    }
  
    exec {'load profile':
      command => "bash -c 'source /home/${user}/.profile'",
      require => File['user-profile']
    }

  }
  
  class nginx  inherits wordpress::config {
    package { 'nginx':
      ensure => latest,
    }
  
    service { 'nginx':
      ensure => running,
      enable => true,
      require => Package['nginx']
    }
  
    file { '/etc/nginx/sites-enabled/default':
      ensure => absent,
      require => Package['nginx']
    }

    # Arquivos de configuração de cache do WP
    file { "/etc/nginx/global":
      ensure => directory,
      require => Package['nginx']
    }
  
  }

  class mysql inherits wordpress::config  {

    # Repositório oficial do MySQL
    exec { "mysql-key":
      command => "bash -c 'export DEBIAN_FRONTEND=\"noninteractive\" && cd /tmp/ && wget http://dev.mysql.com/get/mysql-apt-config_0.5.3-1_all.deb && dpkg -i mysql-apt-config_0.5.3-1_all.deb'",
    }

    apt::source { 'mysql_repo':
      location => 'http://repo.mysql.com/apt/ubuntu',
      release  => 'trusty',
      repos    => 'mysql-5.6',
      pin      => '900',
      include_src => false,  # Puppet Apt 1.2.0
      #include  => {
      #  'deb' => true,
      #},
      require => Exec["mysql-key"],
    }

    package { 'libmysqlclient-dev':
      ensure => latest,
      install_options => [ "--force-yes" ],
    }

    package { "mysql-server":
      ensure => latest
    }

  }
  
  class php_install($version = 'latest') inherits wordpress::config  {
    # MySQL must be installed first
    require mysql
  
    # Extensions must be installed before they are configured
    Php::Extension <| |> -> Php::Config <| |>
  
    # Ensure base packages is installed in the correct order
    # and before any php extensions
    Package['php5-common']
    -> Package['php5-dev']
    -> Package['php5-cli']
    -> Php::Extension <| |>
  
    class {
      # Base packages
      [ 'php::dev', 'php::cli' ]:
        ensure => $version;
  
      # PHP extensions
      [
        'php::extension::curl', 'php::extension::gd', 'php::extension::memcache',
        'php::extension::mcrypt', 'php::extension::mysql', 'php::extension::ldap',
        'php::extension::memcached'
      ]:
        ensure => $version;
  
      [ 'php::extension::igbinary' ]:
        ensure => installed;
  
      ['php::extension::apcu']: 
        ensure    => installed,
        package   => 'php5-apcu',
        provider  => 'apt',
        inifile   => "/etc/php5/mods-available/apcu.ini";
    }
  
    # ICU package is mandatory
    package { 'libicu-dev':
      ensure  => installed
    }
  
    # Install the INTL extension
    php::extension { 'php5-intl':
      ensure    => present,
      package   => 'intl',
      provider  => 'pecl',
      require  => Package['libicu-dev']
    }
  
    # Install the CGI extension
    php::extension { 'php5-cgi':
      ensure    => $version,
      package   => 'php5-cgi',
      provider  => 'apt'
    }
  
    # Install the SQLite extension (for tests)
    php::extension { 'php5-sqlite':
      ensure    => $version,
      package   => 'php5-sqlite',
      provider  => 'apt'
    }
  
    # Cconfigurações do PHP
    create_resources('php::config', hiera_hash('php_config', {}))
    create_resources('php::cli::config', hiera_hash('php_cli_config', {}))

    php::cli::config { "memory_limit2":
      setting => 'memory_limit',
      value => '96M',
      section => 'PHP',
    }
  
    php::cli::config { "date.timezone2":
      setting => 'date.timezone',
      value => "${tz}",
      section => 'Date',
    }

    # Configurações do php::fpm
    class { 'php::fpm':
      ensure => $version,
      #emergency_restart_threshold  => 5,
      #emergency_restart_interval   => '1m',
      #rlimit_files                 => 32768,
      #events_mechanism             => 'epoll'
    }

    create_resources('php::fpm::pool',  hiera_hash('php_fpm_pool', {}))
    create_resources('php::fpm::config',  hiera_hash('php_fpm_config', {}))

    Php::Extension <| |> ~> Service['php5-fpm']

    exec { "restart-php5-fpm":
      command  => "service php5-fpm restart",
      schedule => hourly,
      require => Class['php::fpm']
    }
  
    php::fpm::config { "memory_limit":
      setting => 'memory_limit',
      value => '96M',
      section => 'PHP',
    }
  
    php::fpm::config { "date.timezone":
      setting => 'date.timezone',
      value => "${tz}",
      section => 'Date',
    }
  
  
    # Habilita manualmente. É o único jeito
    package { 'libpcre++-dev':
      ensure  => installed
    }
  
    file { 'apcu_config':
      ensure  => "present",
      path    => "/etc/php5/mods-available/apcu.ini",
      content => inline_template("extension=apcu.so"),
      require => Class["php::extension::apcu"]
    }
  
    file { ["/etc/php5/fpm/conf.d/20-apcu.ini",
            "/etc/php5/cli/conf.d/20-apcu.ini"
          ]:
      ensure  => "link",
      target  => "/etc/php5/mods-available/apcu.ini",
      replace => yes,
      force   => true,
      require => [Class["php::extension::apcu"], Class["php::fpm"], Class["php::cli"], File['apcu_config']]
    }
  }
  
  class software  inherits wordpress::config {
  
    package { 'git':
      ensure => latest
    }
  
    package { 'vim':
      ensure => latest
    }
  
    package { 'libffi-dev':
      ensure => latest
    }
  
    package {'openjdk-7-jre':
      ensure => latest
    }

    package { 'sshfs':
      ensure => installed,
    }
  
  }
}

class wordpress::dev (
  $domain_name,
  $db_name = 'wordpress',
  $db_host = 'localhost',
  $db_user = 'wordpress'
) inherits wordpress::config  {
  include wordpress

  # Carrega somente após todas as outras classes
  require software
  require timezone
  require php_install
  require user
  require mysql
  require nginx

  # Cria banco de dados local
  class { '::mysql::server':
    require => Package['mysql-server'],
    package_manage => false,
    override_options => {
      'mysqld' => {
        innodb_buffer_pool_size => '32M',
      },
    },
  }

  mysql::db { "${db_name}":
      ensure   => 'present',
      user     => $db_user,
      password => $db_password,
      host     => $db_host,
      grant    => ['all'],
      require  => Class['::mysql::server'],
  }

  # cria um pool FPM
  create_resources('php::fpm::pool',  hiera_hash('php_fpm_pool', {}))

  php::fpm::pool { "${domain_name}":
    ensure => 'present',
    user => "${user}",
    group => "${group}",
    notify => Service['php5-fpm']
  }

  # Cria o host no Nginx
  file { 'sites-available config':
    path => "/etc/nginx/sites-available/${domain_name}",
    ensure => file,
    content => template("${inc_file_path}/wordpress/nginx/nginx.conf.erb"),
  }

  file { "/etc/nginx/sites-enabled/${domain_name}":
    ensure => link,
    target => "/etc/nginx/sites-available/${domain_name}",
    require => File['sites-available config'],
  }

  exec { "restart-nginx":
    command => "service nginx restart",
    path => "/usr/bin/",
    require => File["/etc/nginx/sites-enabled/${domain_name}"]
  }

  file {"/storage/${user}/public_html/${domain_name}":
    ensure => "link",
    target => "/storage/${user}/projects/${domain_name}",
    replace => yes,
    force => true,
  }

  file { 'wp-config':
    path => "/storage/${user}/projects/${domain_name}/wp-config.php",
    ensure => file,
    notify => Service["php5-fpm"],
    content => template("${inc_file_path}/wordpress/wordpress/wp-config.php.erb"),
  }

}

# MySQL Server config
# Source: http://nerdier.co.uk/2013/12/07/mysql-replication-with-puppet/
class wordpress::mysql_master inherits wordpress::config {
  include wordpress

  require timezone
  require keys
  require mysql

  class { '::mysql::server':
    #root_password => "${mysql_root_pw}",
    require => Package['mysql-server'],
    package_manage => false,
    override_options => {
      'mysqld' => {
        server-id                      => '1',
        binlog-format                  => 'mixed',
        bind-address                   => '0.0.0.0',
        log-bin                        => 'mysql-bin',
        datadir                        => '/var/lib/mysql',
        innodb_flush_log_at_trx_commit => '1',
        sync_binlog                    => '1',
        binlog-do-db                   => [ 'wordpress',
                                          ],
      },
    },
    users => {
      "${replication_db_user}@${db_host}" => {
        password_hash => mysql_password("${replication_db_password}")
      },
    },
    grants => {
      "${replication_db_user}@${db_host}/*.*" => {
        privileges => ['REPLICATION SLAVE'] ,
        table => '*.*',
        user => "${replication_db_user}@${db_host}"
      },
    }
  }
  
  mysql::db { 'wordpress':
      ensure   => 'present',
      user     => $db_user,
      password => $db_password,
      host     => '%',
      grant    => ['all'],
      require  => Class['::mysql::server'],
  }
  
}

class wordpress::mysql_slave inherits wordpress::config {
  include wordpress

  require timezone
  require keys
  require mysql

  class { '::mysql::server':
    #root_password => "${mysql_root_pw}",
    require => Package['mysql-server'],
    package_manage => false,
    override_options => {
      'mysqld' => {
        server-id                      => '2',
        binlog-format                  => 'mixed',
        bind-address                   => '0.0.0.0',
        log-bin                        => 'mysql-bin',
        relay-log                      => 'mysql-relay-bin',
        log-slave-updates              => '1',
        read-only                      => '1',
        binlog-do-db                   => [ 'wordpress',
                                          ],
      },
    },
  }
  
  mysql::db { 'wordpress':
      ensure   => 'present',
      user     => $db_user,
      password => $db_password,
      host     => "%",
      grant    => ['all'],
      require  => Class['::mysql::server'],
  }
  
}
