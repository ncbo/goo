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
require 'request_store'

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

  DEFAULT_SOLR_NUM_SHARDS = 1
  DEFAULT_SOLR_REPLICATION_FACTOR = 1

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
  @@log_redis_client = nil # query-log Redis (D6a); nil => fall back to @@redis_client
  @@namespaces = {}
  @@pluralize_models = false
  @@uuid = UUID.new
  @@debug_enabled = false
  @@use_cache = false
  @@query_logging = false
  @@query_logging_file = nil
  @@query_count_total = nil # process-wide store-bound query tally; nil = disabled (test reporting)
  @@cache_hit_total = nil   # process-wide cache-hit tally; nil = disabled (test reporting)
  @@slice_loading_size = 500
  @@force_rebuild_search_schema = false



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
                                                              redis_cache: @@redis_client)
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
    # Keep @@use_cache authoritative regardless of add_redis_backend/add_sparql_backend call
    # order (de-fork review D5): construction injects @@redis_client above, so without this a
    # host that configures redis FIRST would get caching silently ON while use_cache says off.
    set_sparql_cache
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

  # When enabled, the first initialization of each search collection in this
  # process rebuilds its schema (init force) instead of trusting whatever an
  # existing collection contains. FOR TEST/DEV ENVIRONMENTS ONLY: goo's test
  # harness enables it so runs never depend on state left in Solr by previous
  # (possibly interrupted) runs. Do NOT enable in production — a forced
  # rebuild drops every schema field the generator does not declare (e.g.
  # fields added over time by Solr's data-driven mode), breaking search on
  # them until a full reindex. Indexed documents themselves are preserved.
  # Production collections are repaired additively instead (see
  # SOLR::Schema#repair_schema_additively).
  def self.force_rebuild_search_schema=(value)
    @@force_rebuild_search_schema = value
  end

  def self.force_rebuild_search_schema?
    @@force_rebuild_search_schema
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
    set_query_logging # the log handle may be defaulting to this client
  end

  # Redis instance for the SPARQL query log, kept separate from the cache (de-fork review D6a).
  # maxmemory / allkeys-lru is per-INSTANCE and ignores key prefixes and db numbers, so disjoint
  # goo:qlog:* vs sparql:* keys prevent collisions but NOT cross-eviction: on a shared instance,
  # log volume evicts cache entries and vice versa. Optional -- unset means the log falls back to
  # the cache Redis, which is fine while logging is off (the default) but should be provisioned
  # before enabling logging in an environment where the cache is load-bearing.
  def self.add_log_redis_backend(*opts)
    raise Exception, "add_log_redis_backend needs options" if opts.length == 0
    opts = opts.first
    host = opts.delete :host
    port = opts.delete(:port) || 6379
    @@log_redis_client = Redis.new host: host, port: port, timeout: 300
    set_query_logging
  end

  # The Redis the query log writes to: its own instance when configured, else the cache's.
  def self.log_redis_client
    @@log_redis_client || @@redis_client
  end

  # The query logger attached to the :main query client (records SPARQL text, timing, result
  # size, cache hits). Inert unless query logging was enabled.
  def self.query_logger
    @@sparql_backends[:main][:query].query_logger
  end

  # Backward-compatible alias for the fork-era name. AgroPortal's ontologies_api
  # Admin::LoggingController calls Goo.logger.{get_logs,queries_last_n_seconds,users_query_count}.
  def self.logger
    query_logger
  end

  # --- SPARQL query counting -------------------------------------------------------------
  # Counts store-bound SPARQL round-trips (cache hits don't count). Unlike wall time, the count
  # is deterministic for a given code path + data, so it's the right signal for catching N+1 /
  # query-fan-out regressions in goo/OLD across machines (laptop vs CI).
  #
  # Three independent tallies, all fed by tick_query_count:
  #   - a thread-local block counter, armed only inside Goo.count_sparql_queries (tests);
  #   - a per-request counter in RequestStore, armed for the duration of an HTTP request;
  #   - a process-wide total, armed only by enable_query_count_total (test-run reporting).
  # Each is a nil-check when unarmed, so there is no overhead in normal operation.

  # Increment whichever counters are active. Called at the client seam per store round-trip.
  def self.tick_query_count
    count = Thread.current[:goo_query_count]
    Thread.current[:goo_query_count] = count + 1 unless count.nil?
    if RequestStore.active?
      RequestStore.store[:goo_query_count] = RequestStore.store.fetch(:goo_query_count, 0) + 1
    end
    @@query_count_total += 1 unless @@query_count_total.nil?
  end

  # Store-bound SPARQL queries issued so far in the current HTTP request, or nil outside one.
  #
  # Deliberately keyed off RequestStore rather than the Goo::Debug middleware: Debug is mounted
  # only when Goo.queries_debug? is set, which no environment config sets, so anything armed
  # there is dead in a default production deploy. RequestStore::Middleware is mounted
  # unconditionally by the API and clears the store per request. Same reasoning as the
  # equivalent-predicates cache in Goo::Base::Where#retrieve_equivalent_predicates. Outside a
  # request (cron, scripts) RequestStore is inactive and this returns nil.
  def self.request_query_count
    return nil unless RequestStore.active?

    RequestStore.store.fetch(:goo_query_count, 0)
  end

  # Counted at the cache-hit branch of Client#query (a hit means caching is on and served the
  # query without a store round-trip). Complements tick_query_count: store-bound + hits = total
  # logical reads, and hits/(hits+store-bound-reads) is the cache effectiveness during the run.
  def self.tick_cache_hit
    @@cache_hit_total += 1 unless @@cache_hit_total.nil?
  end

  # Process-wide tallies for test-run reporting. Off in production (each tick is a single
  # nil-check); a test harness opts in, then prints the totals at the end of the run. Not exact
  # under concurrent threads, but test suites run queries serially.
  def self.enable_query_count_total
    @@query_count_total = 0
    @@cache_hit_total = 0
  end

  def self.query_count_total
    @@query_count_total
  end

  def self.cache_hit_total
    @@cache_hit_total
  end

  # Count the store-bound SPARQL queries issued by the block. Nesting-safe: an inner count also
  # rolls up into the enclosing counter. Returns the count for the block.
  def self.count_sparql_queries
    outer = Thread.current[:goo_query_count]
    Thread.current[:goo_query_count] = 0
    yield
    Thread.current[:goo_query_count]
  ensure
    inner = Thread.current[:goo_query_count] || 0
    Thread.current[:goo_query_count] = outer.nil? ? nil : outer + inner
  end

  def self.query_logging?
    @@query_logging
  end

  # Turn SPARQL query logging on/off and (re)attach loggers to the registered backends.
  # Default off; opt in via this call or the OP_QUERIES_LOGGING env var (see config.rb).
  def self.enable_query_logging(enabled: false, file: nil)
    @@query_logging = enabled
    @@query_logging_file = file
    set_query_logging
  end

  def self.set_query_logging
    return unless @@sparql_backends.length > 0

    @@sparql_backends.each_value do |epr|
      logger = if @@query_logging
                 Goo::SPARQL::QueryLogger.new(redis: log_redis_client, file: @@query_logging_file)
               else
                 Goo::SPARQL::QueryLogger.new # inert
               end
      epr[:query].query_logger = logger
      epr[:update].query_logger = logger
      epr[:data].query_logger = logger
    end
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

  def self.search_collection_bootstrap_target(collection_name)
    search_collection(collection_name)&.dig(:bootstrap_collection) || search_collection_target(collection_name)
  end

  def self.add_search_connection(collection_name, search_backend = :main, target_collection: nil, bootstrap_collection: nil, num_shards: 1, replication_factor: 1, &block)
    target_collection ||= collection_name
    @@search_collections[collection_name] = {
      search_backend: search_backend,
      target_collection: target_collection.to_sym,
      bootstrap_collection: (bootstrap_collection || target_collection).to_sym,
      num_shards: normalize_solr_topology_value(num_shards, DEFAULT_SOLR_NUM_SHARDS, 'num_shards'),
      replication_factor: normalize_solr_topology_value(replication_factor, DEFAULT_SOLR_REPLICATION_FACTOR, 'replication_factor'),
      block: block_given? ? block : nil
    }
  end

  def self.set_search_collection_target(collection_name, target_collection)
    existing_config = search_collection(collection_name)
    raise ArgumentError, "Unknown search collection: #{collection_name}" if existing_config.nil?

    @@search_collections[collection_name] = existing_config.merge(target_collection: target_collection.to_sym)
  end

  def self.set_search_collection_bootstrap(collection_name, bootstrap_collection)
    existing_config = search_collection(collection_name)
    raise ArgumentError, "Unknown search collection: #{collection_name}" if existing_config.nil?

    @@search_collections[collection_name] = existing_config.merge(bootstrap_collection: bootstrap_collection.to_sym)
  end

  def self.set_search_collection_topology(collection_name, num_shards: nil, replication_factor: nil)
    existing_config = search_collection(collection_name)
    raise ArgumentError, "Unknown search collection: #{collection_name}" if existing_config.nil?

    @@search_collections[collection_name] = existing_config.merge(
      num_shards: normalize_solr_topology_value(num_shards, DEFAULT_SOLR_NUM_SHARDS, 'num_shards'),
      replication_factor: normalize_solr_topology_value(replication_factor, DEFAULT_SOLR_REPLICATION_FACTOR, 'replication_factor')
    )
  end

  def self.reset_search_connection(collection_name)
    @@search_connection.delete(collection_name)
  end

  # Atomically repoints a logical Goo search connection to a rebuilt Solr collection
  # by updating a Solr alias and optionally reinitializing the cached connector
  # against that alias. This is the promotion step used after indexing into a
  # versioned collection, so callers can switch the live logical target without
  # changing model-level search bindings.
  def self.promote_search_alias(collection_name, promoted_collection, alias_name: nil, reinitialize: true)
    existing_config = search_collection(collection_name)
    raise ArgumentError, "Unknown search collection: #{collection_name}" if existing_config.nil?

    alias_name ||= search_collection_target(collection_name)
    alias_name = alias_name.to_sym
    promoted_collection = promoted_collection.to_sym

    connector = search_client(collection_name) ||
                SOLR::SolrConnector.new(search_conf(existing_config[:search_backend]), alias_name)

    connector.promote_alias(promoted_collection, alias_name: alias_name)
    set_search_collection_target(collection_name, alias_name)

    return init_search_connection(collection_name,
                                  existing_config[:search_backend],
                                  existing_config[:block],
                                  force: true,
                                  target_collection: alias_name,
                                  initialize_collection: false) if reinitialize

    reset_search_connection(collection_name)
    connector
  end

  def self.promote_alias(collection_name, promoted_collection, alias_name: nil, reinitialize: true)
    promote_search_alias(collection_name, promoted_collection, alias_name: alias_name, reinitialize: reinitialize)
  end

  def self.search_connections
    @@search_connection
  end

  def self.init_search_connection(collection_name, search_backend = :main,  block = nil, force: false, target_collection: nil, initialize_collection: true, bootstrap_collection: nil, num_shards: 1, replication_factor: 1)
    return @@search_connection[collection_name] if @@search_connection[collection_name] && !force

    target_collection ||= search_collection_target(collection_name)
    bootstrap_collection ||= search_collection_bootstrap_target(collection_name)
    num_shards = normalize_solr_topology_value(num_shards, DEFAULT_SOLR_NUM_SHARDS, 'num_shards')
    replication_factor = normalize_solr_topology_value(replication_factor, DEFAULT_SOLR_REPLICATION_FACTOR, 'replication_factor')
    @@search_connection[collection_name] = build_search_connection(search_backend,
                                                                   target_collection,
                                                                   block,
                                                                   num_shards: num_shards,
                                                                   replication_factor: replication_factor)
    # force_rebuild_search_schema? makes the one-time init of this collection
    # rebuild the schema (see the accessor's comment); afterwards the memoized
    # connection short-circuits above, so the rebuild happens once per process.
    @@search_connection[collection_name].init(force || Goo.force_rebuild_search_schema?, bootstrap_collection: bootstrap_collection) if initialize_collection

    @@search_connection[collection_name]
  end


  def self.init_search_connections(force=false)
    @@search_collections.each do |collection_name, backend|
      search_backend = backend[:search_backend]
      target_collection = backend[:target_collection]
      bootstrap_collection = backend[:bootstrap_collection]
      num_shards = backend[:num_shards]
      replication_factor = backend[:replication_factor]
      block =  backend[:block]
      init_search_connection(collection_name,
                             search_backend,
                             block,
                             force: force,
                             target_collection: target_collection,
                             bootstrap_collection: bootstrap_collection,
                             num_shards: num_shards,
                             replication_factor: replication_factor)
    end
  end

  private

  def self.build_search_connection(search_backend, target_collection, block = nil, num_shards: 1, replication_factor: 1)
    num_shards = normalize_solr_topology_value(num_shards, DEFAULT_SOLR_NUM_SHARDS, 'num_shards')
    replication_factor = normalize_solr_topology_value(replication_factor, DEFAULT_SOLR_REPLICATION_FACTOR, 'replication_factor')
    connector = SOLR::SolrConnector.new(search_conf(search_backend),
                                        target_collection,
                                        num_shards: num_shards,
                                        replication_factor: replication_factor)
    if block
      block.call(connector.schema_generator)
      connector.enable_custom_schema
    end
    connector
  end

  def self.normalize_solr_topology_value(value, default, name)
    value = default if value.nil? || (value.respond_to?(:empty?) && value.empty?)
    integer_value = Integer(value)
    raise ArgumentError, "#{name} must be greater than zero" unless integer_value.positive?

    integer_value
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a positive integer"
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
      if Thread.current[:ncbo_debug] && Thread.current[:ncbo_debug][:goo_process_query]
        goo_totals = Thread.current[:ncbo_debug][:goo_process_query]
          .inject { |sum,x| sum + x }
        headers["ncbo-time-goo-process-query"] = "%.3f"%goo_totals
      end
      # Count of store-bound SPARQL queries this request issued -- deterministic, unlike timing.
      # Only the *exposure* is gated on QUERIES_DEBUG (this middleware): the count itself is
      # collected unconditionally in Goo.tick_query_count, so it is available to logs and metrics
      # in a normal deploy without publishing per-request fan-out to every API caller.
      count = Goo.request_query_count
      headers["ncbo-sparql-query-count"] = count.to_s unless count.nil?
      [status, headers, response]
    end
  end

end

Goo::Filter = Goo::Base::Filter
Goo::Pattern = Goo::Base::Pattern
Goo::Collection = Goo::Base::Collection
