require "pry"
require "rdf"
require "rdf/ntriples"
require "sparql/client"

require "set"
require "uri"
require "uuid"
require 'rsolr'
require 'rest_client'
require 'redis'
require 'uuid'

require_relative "goo/sparql/sparql"
require_relative "goo/search/search"
require_relative "goo/base/base"
require_relative "goo/validators/enforce"
require_relative "goo/utils/utils"
require_relative "goo/mixins/sparql_client"

module Goo

  @@resource_options = Set.new([:persistent]).freeze

  @@configure_flag = false
  @@sparql_backends = {}
  @@search_backends = {}
  @@model_by_name = {}
  @@search_connection = nil

  @@default_namespace = nil
  @@id_prefix = nil
  @@redis_client = nil
  @@namespaces = {}
  @@pluralize_models = false
  @@uuid = UUID.new
  @@debug_enabled = false

  def self.add_namespace(shortcut, namespace,default=false)
    if !(namespace.instance_of? RDF::Vocabulary)
      raise ArgumentError, "Namespace must be a RDF::Vocabulary object"
    end
    @@namespaces[shortcut.to_sym] = namespace
    @@default_namespace = shortcut if default
  end

  def self.pluralize_models(setting_value)
    @@pluralize_models = setting_value
  end

  def self.add_sparql_backend(name, *opts)
    opts = opts[0]
    @@sparql_backends = @@sparql_backends.dup
    @@sparql_backends[name] = opts
    @@sparql_backends[name][:query]=Goo::SPARQL::Client.new(opts[:query],
                 {protocol: "1.1", "Content-Type" => "application/x-www-form-urlencoded", read_timeout: 10000 })
    @@sparql_backends[name][:update]=Goo::SPARQL::Client.new(opts[:update],
                 {protocol: "1.1", "Content-Type" => "application/x-www-form-urlencoded", read_timeout: 10000 })
    @@sparql_backends[name][:data]=Goo::SPARQL::Client.new(opts[:data],
                 {protocol: "1.1", "Content-Type" => "application/x-www-form-urlencoded", read_timeout: 10000 })
    @@sparql_backends.freeze
  end

  def self.queries_debug(flag)
    @@debug_enabled = flag
  end

  def self.queries_debug?
    return @@debug_enabled
  end

  def self.add_search_backend(name, *opts)
    opts = opts[0]
    unless opts.include? :service
      raise ArgumentError, "Search backend configuration must contains a host list."
    end
    @@search_backends = @@search_backends.dup
    @@search_backends[name] = opts
    @@search_backends.freeze
  end

  def self.add_redis_backend(*opts)
    host = opts.delete :host
    port = opts.delete(:port) || 6379
    @@redis_client = Redis.new host: host, port: port
  end

  def self.configure_sanity_check()
    unless @@namespaces.length > 0
      raise ArgumentError, "Namespaces needs to be provided."
    end
    unless @@default_namespace
      raise ArgumentError, "Default namespaces needs to be provided."
    end
  end

  def self.configure
    if not block_given?
      raise ArgumentError, "Configuration needs to receive a code block"
    end
    yield self
    configure_sanity_check()
    if @@search_backends.length > 0
      @@search_connection = RSolr.connect :url => search_conf()
    end
    @@namespaces.freeze
    @@sparql_backends.freeze
    @@search_backends.freeze
    @@configure_flag = true
  end

  def self.configure?
    return @@configure_flag
  end

  def self.redis_client
    return @@redis_client
  end

  def self.namespaces
    return @@namespaces
  end

  def self.search_conf
    return @@search_backends[:main][:service]
  end

  def self.search_connection
    return @@search_connection
  end

  def self.sparql_query_client(name=:main)
    return @@sparql_backends[name][:query]
  end

  def self.sparql_update_client(name=:main)
    return @@sparql_backends[name][:update]
  end

  def self.sparql_data_client(name=:main)
    return @@sparql_backends[name][:data]
  end

  def self.id_prefix
    return @@id_prefix
  end

  def self.id_prefix=(prefix)
    @@id_prefix = prefix
  end

  def self.add_model(name, model)
    @@model_by_name[name] = model
  end

  def self.model_by_name(name)
    return @@model_by_name[name]
  end

  def self.models
    return @@model_by_name
  end

  def self.resource_options
    return @@resource_options
  end

  def self.vocabulary(namespace=nil)
    return @@namespaces[@@default_namespace] if namespace.nil?
    return @@namespaces[namespace]
  end

  def self.pluralize_models?
    return @@pluralize_models
  end

  def self.uuid
    @@uuid.generate
  end

  def self.write_in_chunks?
    true
  end

  #A debug middleware for rack applications
  class Debug
    def initialize(app = nil)
      @app = app
    end

    def call(env)
      Thread.current[:ncbo_debug] = nil
      status, headers, response = @app.call(env)
      if Thread.current[:ncbo_debug]
        if Thread.current[:ncbo_debug][:sparql_queries]
          queries = Thread.current[:ncbo_debug][:sparql_queries]
          processing = queries.map { |x| x[0] }.inject { |sum,x| sum + x }
          parsing = queries.map { |x| x[1] }.inject { |sum,x| sum + x }
          headers["ncbo-time-goo-sparql-queries"] = "%.3f"%processing
          headers["ncbo-time-goo-response-parsing"] = "%.3f"%parsing
        end
        if Thread.current[:ncbo_debug][:goo_process_query]
          goo_totals = Thread.current[:ncbo_debug][:goo_process_query]
            .inject { |sum,x| sum + x }
          headers["ncbo-time-goo-process-query"] = "%.3f"%goo_totals
        end
      end
      return [status, headers, response]
    end
  end

end

Goo::Filter = Goo::Base::Filter
Goo::Pattern = Goo::Base::Pattern
Goo::Collection = Goo::Base::Collection

