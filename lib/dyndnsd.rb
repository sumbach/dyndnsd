# frozen_string_literal: true

require 'etc'
require 'logger'
require 'ipaddr'
require 'json'
require 'yaml'
require 'rack'
require 'metriks'
require 'metriks/reporter/graphite'
require 'opentracing'
require 'rack/tracer'

require 'dyndnsd/generator/bind'
require 'dyndnsd/updater/command_with_bind_zone'
require 'dyndnsd/responder/dyndns_style'
require 'dyndnsd/responder/rest_style'
require 'dyndnsd/database'
require 'dyndnsd/helper'
require 'dyndnsd/textfile_reporter'
require 'dyndnsd/version'

module Dyndnsd
  # @return [Logger]
  def self.logger
    @logger
  end

  # @param logger [Logger]
  # @return [Logger]
  def self.logger=(logger)
    @logger = logger
  end

  class LogFormatter
    # @param lvl [Object]
    # @param _time [DateTime]
    # @param _progname [String]
    # @param msg [Object]
    # @return [String]
    def call(lvl, _time, _progname, msg)
      format("[%s] %-5s %s\n", Time.now.strftime('%Y-%m-%d %H:%M:%S'), lvl, msg.to_s)
    end
  end

  class Daemon
    # @param config [Hash{String => Object}]
    # @param db [Dyndnsd::Database]
    # @param updater [#update]
    def initialize(config, db, updater)
      @users = config['users']
      @domain = config['domain']
      @db = db
      @updater = updater

      @db.load
      @db['serial'] ||= 1
      @db['hosts'] ||= {}
      if @db.changed?
        @db.save
        @updater.update(@db)
      end
    end

    # @param username [String]
    # @param password [String]
    # @return [Boolean]
    def authorized?(username, password)
      Helper.span('check_authorized') do |span|
        span.set_tag('dyndnsd.user', username)

        allow = Helper.user_allowed?(username, password, @users)
        if !allow
          Dyndnsd.logger.warn "Login failed for #{username}"
          Metriks.meter('requests.auth_failed').mark
        end
        allow
      end
    end

    # @param env [Hash{String => String}]
    # @return [Array{Integer,Hash{String => String},Array{String}}]
    def call(env)
      return [422, {'X-DynDNS-Response' => 'method_forbidden'}, []] if env['REQUEST_METHOD'] != 'GET'
      return [422, {'X-DynDNS-Response' => 'not_found'}, []] if env['PATH_INFO'] != '/nic/update'

      handle_dyndns_request(env)
    end

    # @return [void]
    def self.run!
      if ARGV.length != 1
        puts 'Usage: dyndnsd config_file'
        exit 1
      end

      config_file = ARGV[0]

      if !File.file?(config_file)
        puts 'Config file not found!'
        exit 1
      end

      puts "DynDNSd version #{Dyndnsd::VERSION}"
      puts "Using config file #{config_file}"

      config = YAML.safe_load(File.open(config_file, 'r', &:read))

      setup_logger(config)

      Dyndnsd.logger.info 'Starting...'

      # drop priviliges as soon as possible
      # NOTE: first change group than user
      if config['group']
        group = Etc.getgrnam(config['group'])
        Process::Sys.setgid(group.gid) if group
      end
      if config['user']
        user = Etc.getpwnam(config['user'])
        Process::Sys.setuid(user.uid) if user
      end

      setup_traps

      setup_monitoring(config)

      setup_tracing(config)

      setup_rack(config)
    end

    private

    # @param params [Hash{String => String}]
    # @return [Array{String}]
    def extract_v4_and_v6_address(params)
      return [] if !(params['myip'])
      begin
        IPAddr.new(params['myip'], Socket::AF_INET)
        IPAddr.new(params['myip6'], Socket::AF_INET6)
        [params['myip'], params['myip6']]
      rescue ArgumentError
        []
      end
    end

    # @param env [Hash{String => String}]
    # @param params [Hash{String => String}]
    # @return [Array{String}]
    def extract_myips(env, params)
      # require presence of myip parameter as valid IPAddr (v4) and valid myip6
      return extract_v4_and_v6_address(params) if params.key?('myip6')

      # check whether myip parameter has valid IPAddr
      return [params['myip']] if params.key?('myip') && Helper.ip_valid?(params['myip'])

      # check whether X-Real-IP header has valid IPAddr
      return [env['HTTP_X_REAL_IP']] if env.key?('HTTP_X_REAL_IP') && Helper.ip_valid?(env['HTTP_X_REAL_IP'])

      # fallback value, always present
      [env['REMOTE_ADDR']]
    end

    # @param hostnames [String]
    # @param myips [Array{String}]
    # @return [Array{Symbol}]
    def process_changes(hostnames, myips)
      changes = []
      Helper.span('process_changes') do |span|
        span.set_tag('dyndnsd.hostnames', hostnames.join(','))

        hostnames.each do |hostname|
          # myips order is always deterministic
          if myips.empty? && @db['hosts'].include?(hostname)
            @db['hosts'].delete(hostname)
            changes << :good
            Metriks.meter('requests.good').mark
          elsif Helper.changed?(hostname, myips, @db['hosts'])
            @db['hosts'][hostname] = myips
            changes << :good
            Metriks.meter('requests.good').mark
          else
            changes << :nochg
            Metriks.meter('requests.nochg').mark
          end
        end
      end
      changes
    end

    # @return [void]
    def update_db
      @db['serial'] += 1
      Dyndnsd.logger.info "Committing update ##{@db['serial']}"
      @db.save
      @updater.update(@db)
      Metriks.meter('updates.committed').mark
    end

    # @param env [Hash{String => String}]
    # @return [Array{Integer,Hash{String => String},Array{String}}]
    def handle_dyndns_request(env)
      params = Rack::Utils.parse_query(env['QUERY_STRING'])

      # require hostname parameter
      return [422, {'X-DynDNS-Response' => 'hostname_missing'}, []] if !(params['hostname'])

      hostnames = params['hostname'].split(',')

      # check for invalid hostnames
      invalid_hostnames = hostnames.select { |h| !Helper.fqdn_valid?(h, @domain) }
      return [422, {'X-DynDNS-Response' => 'hostname_malformed'}, []] if invalid_hostnames.any?

      user = env['REMOTE_USER']

      # check for hostnames that the user does not own
      forbidden_hostnames = hostnames - @users[user]['hosts']
      return [422, {'X-DynDNS-Response' => 'host_forbidden'}, []] if forbidden_hostnames.any?

      if params['offline'] == 'YES'
        myips = []
      else
        myips = extract_myips(env, params)
        # require at least one IP to update
        return [422, {'X-DynDNS-Response' => 'host_forbidden'}, []] if myips.empty?
      end

      Metriks.meter('requests.valid').mark
      Dyndnsd.logger.info "Request to update #{hostnames} to #{myips} for user #{user}"

      changes = process_changes(hostnames, myips)

      update_db if @db.changed?

      [200, {'X-DynDNS-Response' => 'success'}, [changes, myips]]
    end

    # SETUP

    # @param config [Hash{String => Object}]
    # @return [void]
    private_class_method def self.setup_logger(config)
      if config['logfile']
        Dyndnsd.logger = Logger.new(config['logfile'])
      else
        Dyndnsd.logger = Logger.new(STDOUT)
      end

      Dyndnsd.logger.progname = 'dyndnsd'
      Dyndnsd.logger.formatter = LogFormatter.new
    end

    # @return [void]
    private_class_method def self.setup_traps
      Signal.trap('INT') do
        Dyndnsd.logger.info 'Quitting...'
        Rack::Handler::WEBrick.shutdown
      end
      Signal.trap('TERM') do
        Dyndnsd.logger.info 'Quitting...'
        Rack::Handler::WEBrick.shutdown
      end
    end

    # @param config [Hash{String => Object}]
    # @return [void]
    private_class_method def self.setup_monitoring(config)
      # configure metriks
      if config['graphite']
        host = config['graphite']['host'] || 'localhost'
        port = config['graphite']['port'] || 2003
        options = {}
        options[:prefix] = config['graphite']['prefix'] if config['graphite']['prefix']
        reporter = Metriks::Reporter::Graphite.new(host, port, options)
        reporter.start
      elsif config['textfile']
        file = config['textfile']['file'] || '/tmp/dyndnsd-metrics.prom'
        options = {}
        options[:prefix] = config['textfile']['prefix'] if config['textfile']['prefix']
        reporter = Dyndnsd::TextfileReporter.new(file, options)
        reporter.start
      else
        reporter = Metriks::Reporter::ProcTitle.new
        reporter.add 'good', 'sec' do
          Metriks.meter('requests.good').mean_rate
        end
        reporter.add 'nochg', 'sec' do
          Metriks.meter('requests.nochg').mean_rate
        end
        reporter.start
      end
    end

    # @param config [Hash{String => Object}]
    # @return [void]
    private_class_method def self.setup_tracing(config)
      # configure OpenTracing
      if config.dig('tracing', 'jaeger')
        require 'jaeger/client'

        host = config['tracing']['jaeger']['host'] || '127.0.0.1'
        port = config['tracing']['jaeger']['port'] || 6831
        service_name = config['tracing']['jaeger']['service_name'] || 'dyndnsd'
        OpenTracing.global_tracer = Jaeger::Client.build(
          host: host, port: port, service_name: service_name, flush_interval: 1
        )
      end
    end

    # @param config [Hash{String => Object}]
    # @return [void]
    private_class_method def self.setup_rack(config)
      # configure daemon
      db = Database.new(config['db'])
      updater = Updater::CommandWithBindZone.new(config['domain'], config.dig('updater', 'params')) if config.dig('updater', 'name') == 'command_with_bind_zone'
      daemon = Daemon.new(config, db, updater)

      # configure rack
      app = Rack::Auth::Basic.new(daemon, 'DynDNS', &daemon.method(:authorized?))

      if config['responder'] == 'RestStyle'
        app = Responder::RestStyle.new(app)
      else
        app = Responder::DynDNSStyle.new(app)
      end

      trust_incoming_span = config.dig('tracing', 'trust_incoming_span') || false
      app = Rack::Tracer.new(app, trust_incoming_span: trust_incoming_span)

      Rack::Handler::WEBrick.run app, Host: config['host'], Port: config['port']
    end
  end
end
