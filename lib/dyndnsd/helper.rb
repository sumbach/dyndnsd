# frozen_string_literal: true

require 'ipaddr'

module Dyndnsd
  class Helper
    # @param hostname [String]
    # @param domain [String]
    # @return [Boolean]
    def self.fqdn_valid?(hostname, domain)
      return false if hostname.length < domain.length + 2
      return false if !hostname.end_with?(domain)
      name = hostname.chomp(domain)
      return false if !name.match(/^[a-zA-Z0-9_-]+\.$/)
      true
    end

    # @param ip [String]
    # @return [Boolean]
    def self.ip_valid?(ip)
      IPAddr.new(ip)
      true
    rescue ArgumentError
      false
    end

    # @param username [String]
    # @param password [String]
    # @param users [Hash]
    # @return [Boolean]
    def self.user_allowed?(username, password, users)
      (users.key? username) && (users[username]['password'] == password)
    end

    # @param hostname [String]
    # @param myips [Array]
    # @param hosts [Hash]
    # @return [Boolean]
    def self.changed?(hostname, myips, hosts)
      # myips order is always deterministic
      ((!hosts.include? hostname) || (hosts[hostname] != myips)) && !myips.empty?
    end

    # @param operation [String]
    # @param block [Proc]
    # @return [void]
    def self.span(operation, &block)
      scope = OpenTracing.start_active_span(operation)
      span = scope.span
      span.set_tag('component', 'dyndnsd')
      span.set_tag('span.kind', 'server')
      begin
        block.call(span)
      rescue StandardError => e
        span.set_tag('error', true)
        span.log_kv(
          event: 'error',
          'error.kind': e.class.to_s,
          'error.object': e,
          message: e.message,
          stack: e.backtrace&.join("\n") || ''
        )
        raise
      ensure
        scope.close
      end
    end
  end
end
