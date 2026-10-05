require "sinatra/base"
require "redis"
require "connection_pool"

require_relative "otel" unless ENV["ENABLE_OTEL"].to_s.empty?

module RedisPool
  def self.pool
    @pool ||= ConnectionPool.new(size: 8, timeout: 5) do
      Redis.new(host: ENV.fetch("VALKEY_HOST", "valkey"), port: 6379)
    end
  end
end

class App < Sinatra::Base
  # Sinatra's default Rack::Protection::HostAuthorization only allows
  # localhost-ish Host headers; the load generator hits this container by
  # its compose DNS name, which would otherwise get a blanket 403.
  set :host_authorization, permitted_hosts: []

  get "/" do
    content_type "text/plain"
    RedisPool.pool.with { |redis| redis.call("INCR", "counter") }.to_s
  end
end
