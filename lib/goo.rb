require "pry"
require "rdf"
require "rdf/vocab"
require "rdf/ntriples"
require "rdf/rdfxml"
require "sparql/client"

require "set"
require "uri"
require "uuid"
require 'rsolr'
require 'rest_client'
require 'redis'
require 'uuid'

require_relative "goo/config/config"
require_relative "goo/sparql/sparql"
require_relative "goo/search/search"
require_relative "goo/base/base"
require_relative "goo/validators/enforce"
require_relative "goo/validators/validator"
project_root = File.dirname(File.absolute_path(__FILE__))
Dir.glob("#{project_root}/goo/validators/implementations/*", &method(:require))

require_relative "goo/utils/utils"
require_relative "goo/mixins/sparql_client"


module Goo


  @@resource_options = Set.new([:persistent]).freeze

  # Define the languages from which the properties values will be taken
  # It choose the first language that match otherwise return all the values
  @@main_languages = %w[en]
  @@requested_language = nil

  @@configure_flag = false
  @@sparql_backends = {}
  @@model_by_name = {}
  @@search_backends = {}
  @@search_connection = {}
  @@search_collections = {}
  @@default_namespace = nil
  @@id_prefix = nil
  @@redis_client = nil
  @@namespaces = {}
  @@pluralize_models = false
  @@uuid = UUID.new
  @@debug_enabled = false
  @@use_cache = false
  @@query_logging = false
  @@query_logging_file = './queries.log'
  @@slice_loading_size = 500



  def self.log_debug_file(str)
    debug_file = "./queries.txt"
    File.write(debug_file, str.to_s + "\n", mode: 'a')
  end



  def backend_4s?
    sparql_backend_name.downcase.eql?("4store")
  end

  def backend_ag?
    sparql_backend_name.downcase.eql?("allegrograph")
  end

  def backend_gb?
    sparql_backend_name.downcase.eql?("graphdb")
  end

  def backend_vo?
    sparql_backend_name.downcase.eql?("virtuoso")
  end


  def self.main_languages
    @@main_languages
  end
  def self.main_languages=(lang)
    @@main_languages = lang
  end

  def self.requested_language
    @@requested_language
  end

  def self.requested_language=(lang)
    @@requested_language = lang
  end

  def self.language_includes(lang)
    lang_str = lang.to_s
    main_languages.index { |l| lang_str.downcase.eql?(l) || lang_str.upcase.eql?(l)}
  end

  def self.add_namespace(shortcut, namespace,default=false)
    unless namespace.instance_of? RDF::Vocabulary
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
    @@sparql_backends[name][:query] = Goo::SPARQL::Client.new(opts[:query],
                                                              protocol: "1.1",
                                                              headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/sparql-results+json"},
                                                              read_timeout: 10000,
                                                              validate: false,
                                                              redis_cache: @@redis_client,
                                                              logger: query_logging? ? Logger.new(query_logging_file) : nil)
    @@sparql_backends[name][:update] = Goo::SPARQL::Client.new(opts[:update],
                                                               protocol: "1.1",
                                                               headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/sparql-results+json"},
                                                               read_timeout: 10000,
                                                               validate: false,
                                                               redis_cache: @@redis_client)
    @@sparql_backends[name][:data] = Goo::SPARQL::Client.new(opts[:data],
                                                             protocol: "1.1",
                                                             headers: { "Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/sparql-results+json"},
                                                             read_timeout: 10000,
                                                             validate: false,
                                                             redis_cache: @@redis_client)
    @@sparql_backends[name][:backend_name] = opts[:backend_name]
    @@sparql_backends.freeze
  end

  def self.main_lang
    @@main_lang
  end

  def self.main_lang=(value)
    @@main_lang = value
  end

  def self.use_cache=(value)
    @@use_cache = value
    set_sparql_cache
  end

  def self.use_cache?
    @@use_cache
  end

  def self.slice_loading_size=(value)
    @@slice_loading_size = value
  end

  def self.slice_loading_size
    return @@slice_loading_size
  end

  def self.queries_debug(flag)
    @@debug_enabled = flag
  end

  def self.queries_debug?
    return @@debug_enabled
  end

  def self.query_logging?
    @@query_logging
  end

  def self.query_logging_file
    @@query_logging_file
  end

  def self.query_logging=(value)
    @@query_logging = value
  end
  def self.query_logging_file=(value)
    @@query_logging_file = value
  end

  def self.logger
    return @@sparql_backends[:main][:query].logger
  end

  def self.add_search_backend(name, *opts)
    opts = opts[0]
    unless opts.include? :service
      raise ArgumentError, "Search backend configuration must contain a host list."
    end
    @@search_backends = @@search_backends.dup
    @@search_backends[name] = opts
    @@search_backends.freeze
  end

  def self.add_redis_backend(*opts)
    raise Exception, "add_redis_backend needs options" if opts.length == 0
    opts = opts.first
    host = opts.delete :host
    port = opts.delete(:port) || 6379
    @@redis_client = Redis.new host: host, port: port, timeout: 300
    set_sparql_cache
  end

  def self.add_query_logger(enabled: false, file: )
    @@query_logging = enabled
    @@query_logging_file = file
    set_query_logging
  end

  def self.set_sparql_cache
    if @@sparql_backends.length > 0 && @@use_cache
      @@sparql_backends.each do |k,epr|
        epr[:query].redis_cache= @@redis_client
        epr[:data].redis_cache= @@redis_client
        epr[:update].redis_cache= @@redis_client
      end
    elsif @@sparql_backends.length > 0
      @@sparql_backends.each do |k,epr|
        epr[:query].redis_cache= nil
        epr[:data].redis_cache= nil
        epr[:update].redis_cache= nil
      end
    end
  end


  def self.set_query_logging
    if @@sparql_backends.length > 0 && query_logging?
      @@sparql_backends.each do |k,epr|
        epr[:query].logger = Logger.new(query_logging_file)
      end
    elsif @@sparql_backends.length > 0
      @@sparql_backends.each do |k,epr|
        epr[:query].logger = nil
      end
    end
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
    configure_sanity_check

    
    init_search_connections

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

  def self.search_conf(name=:main)
    return @@search_backends[name][:service]
  end

  def self.search_connection(collection_name)
    return search_client(collection_name).solr
  end

  def self.search_client(collection_name)
    @@search_connection[collection_name]
  end

  def self.search_collection(collection_name)
    @@search_collections[collection_name]
  end

  def self.search_collection_target(collection_name)
    search_collection(collection_name)&.dig(:target_collection) || collection_name
  end

  def self.add_search_connection(collection_name, search_backend = :main, target_collection: nil, &block)
    @@search_collections[collection_name] = {
      search_backend: search_backend,
      target_collection: (target_collection || collection_name).to_sym,
      block: block_given? ? block : nil
    }
  end

  def self.set_search_collection_target(collection_name, target_collection)
    existing_config = search_collection(collection_name)
    raise ArgumentError, "Unknown search collection: #{collection_name}" if existing_config.nil?

    @@search_collections[collection_name] = existing_config.merge(target_collection: target_collection.to_sym)
  end

  def self.search_connections
    @@search_connection
  end

  def self.init_search_connection(collection_name, search_backend = :main,  block = nil, force: false, target_collection: nil)
    return @@search_connection[collection_name] if @@search_connection[collection_name] && !force

    target_collection ||= search_collection_target(collection_name)
    @@search_connection[collection_name] = SOLR::SolrConnector.new(search_conf(search_backend), target_collection)
    if block
      block.call(@@search_connection[collection_name].schema_generator)
      @@search_connection[collection_name].enable_custom_schema
    end
    @@search_connection[collection_name].init(force)
    @@search_connection[collection_name]
  end


  def self.init_search_connections(force=false)
    @@search_collections.each do |collection_name, backend|
      search_backend = backend[:search_backend]
      target_collection = backend[:target_collection]
      block =  backend[:block]
      init_search_connection(collection_name, search_backend, block, force: force, target_collection: target_collection)
    end
  end

  def self.sparql_query_client(name=:main)
    @@sparql_backends[name][:query]
  end

  def self.sparql_update_client(name=:main)
    return @@sparql_backends[name][:update]
  end

  def self.sparql_data_client(name=:main)
    return @@sparql_backends[name][:data]
  end

  def self.sparql_backend_name(name=:main)
    return @@sparql_backends[name][:backend_name]
  end

  def self.portal_language
    @@main_languages.first.downcase.to_sym
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

  #A debug middleware for rack applications
  class Debug
    def initialize(app = nil)
      @app = app
    end

    def call(env)
      Thread.current[:ncbo_debug] = {}
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
