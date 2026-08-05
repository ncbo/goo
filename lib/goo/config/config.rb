require 'ostruct'

module Goo
  extend self
  attr_reader :settings

  @settings = OpenStruct.new
  @settings_run = false

  def config(&block)
    return if @settings_run
    @settings_run = true

    yield @settings if block_given?

    # Set defaults
    @settings.goo_backend_name    ||= ENV['GOO_BACKEND_NAME'] || '4store'
    @settings.goo_port            ||= ENV['GOO_PORT'] || 9000
    @settings.goo_host            ||= ENV['GOO_HOST'] || 'localhost'
    @settings.goo_path_query      ||= ENV['GOO_PATH_QUERY'] || '/sparql/'
    @settings.goo_path_data       ||= ENV['GOO_PATH_DATA'] || '/data/'
    @settings.goo_path_update     ||= ENV['GOO_PATH_UPDATE'] || '/update/'
    @settings.search_server_url   ||= ENV['SEARCH_SERVER_URL'] || 'http://localhost:8983/solr'
    @settings.solr_num_shards     ||= ENV['SOLR_NUM_SHARDS'] || 1
    @settings.solr_replication_factor ||= ENV['SOLR_REPLICATION_FACTOR'] || 1
    @settings.goo_redis_host      ||= ENV['REDIS_HOST'] || 'localhost'
    @settings.goo_redis_port      ||= ENV['REDIS_PORT'] || 6379
    @settings.bioportal_namespace ||= ENV['BIOPORTAL_NAMESPACE'] || 'http://data.bioontology.org/'
    # SPARQL query logging: goo default OFF, process-wide env opt-in. Parse truthiness rather
    # than taking the raw string -- OP_QUERIES_LOGGING=false is a non-empty String and would
    # otherwise turn logging ON (same treatment as use_cache below).
    @settings.query_logging       ||= %w[1 true yes on].include?(ENV['OP_QUERIES_LOGGING'].to_s.strip.downcase)
    @settings.query_logging_file  ||= ENV['OP_QUERIES_LOGGING_FILE'] || nil
    # Query logs go on their own Redis instance by default (de-fork review D6a): maxmemory /
    # allkeys-lru is per-INSTANCE and ignores key prefixes and db numbers, so sharing one
    # instance lets log volume evict cache entries. Falls back to the cache Redis when unset.
    @settings.query_logging_redis_host ||= ENV['OP_QUERIES_LOGGING_REDIS_HOST'] || nil
    @settings.query_logging_redis_port ||= ENV['OP_QUERIES_LOGGING_REDIS_PORT'] || nil
    # Ring-buffer depth / entry TTL. Raise max_logs above the query count of the request under
    # investigation: one class-tree request is ~2000 reads, so too small a buffer means the
    # request trims away the evidence you enabled logging to collect.
    @settings.query_logging_max_logs ||= (ENV['OP_QUERIES_LOGGING_MAX_LOGS'] || 10_000).to_i
    @settings.query_logging_ttl        ||= (ENV['OP_QUERIES_LOGGING_TTL'] || 86_400).to_i
    @settings.queries_debug       ||= ENV['QUERIES_DEBUG'] || false
    # SPARQL query caching: goo default OFF; env-driven opt-in so production can flip caching
    # without a code change (de-fork review D5).
    @settings.use_cache           ||= %w[1 true yes on].include?(ENV['OP_USE_CACHE'].to_s.strip.downcase)
    @settings.slice_loading_size  ||= ENV['GOO_SLICES']&.to_i || 500
    puts "(GOO) >> Using RDF store (#{@settings.goo_backend_name}) #{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_query}"
    puts "(GOO) >> Using term search server at #{@settings.search_server_url}"
    puts "(GOO) >> Using Redis instance at #{@settings.goo_redis_host}:#{@settings.goo_redis_port}"
    puts "(GOO) >> SPARQL query caching enabled (OP_USE_CACHE)" if @settings.use_cache
    if @settings.query_logging
      log_redis = @settings.query_logging_redis_host ?
        "#{@settings.query_logging_redis_host}:#{@settings.query_logging_redis_port || 6379}" :
        "#{@settings.goo_redis_host}:#{@settings.goo_redis_port} (SHARED with cache -- see D6a)"
      puts "(GOO) >> Using SPARQL query logging -> redis #{log_redis}" \
           "#{@settings.query_logging_file ? " + file #{@settings.query_logging_file}" : ''}"
    end

    connect_goo
  end

  def connect_goo
    begin
      Goo.configure do |conf|
        conf.queries_debug(@settings.queries_debug)
        conf.add_sparql_backend(:main,
                                backend_name: @settings.goo_backend_name,
                                query: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_query}",
                                data: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_data}",
                                update: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_update}",
                                options: { rules: :NONE})
        conf.add_search_backend(:main, service: @settings.search_server_url)
        conf.add_redis_backend(host: @settings.goo_redis_host, port: @settings.goo_redis_port)
        if @settings.query_logging_redis_host
          conf.add_log_redis_backend(host: @settings.query_logging_redis_host,
                                     port: @settings.query_logging_redis_port || 6379)
        end
        conf.enable_query_logging(enabled: @settings.query_logging,
                                  file: @settings.query_logging_file,
                                  max_logs: @settings.query_logging_max_logs,
                                  ttl: @settings.query_logging_ttl)

        conf.add_namespace(:omv, RDF::Vocabulary.new("http://omv.org/ontology/"))
        conf.add_namespace(:skos, RDF::Vocabulary.new("http://www.w3.org/2004/02/skos/core#"))
        conf.add_namespace(:owl, RDF::Vocabulary.new("http://www.w3.org/2002/07/owl#"))
        conf.add_namespace(:rdfs, RDF::Vocabulary.new("http://www.w3.org/2000/01/rdf-schema#"))
        conf.add_namespace(:goo, RDF::Vocabulary.new("http://goo.org/default/"), default = true)
        conf.add_namespace(:metadata, RDF::Vocabulary.new("http://goo.org/metadata/"))
        conf.add_namespace(:foaf, RDF::Vocabulary.new("http://xmlns.com/foaf/0.1/"))
        conf.add_namespace(:rdf, RDF::Vocabulary.new("http://www.w3.org/1999/02/22-rdf-syntax-ns#"))
        conf.add_namespace(:tiger, RDF::Vocabulary.new("http://www.census.gov/tiger/2002/vocab#"))
        conf.add_namespace(:nemo, RDF::Vocabulary.new("http://purl.bioontology.org/NEMO/ontology/NEMO_annotation_properties.owl#"))
        conf.add_namespace(:bioportal, RDF::Vocabulary.new(@settings.bioportal_namespace))
        conf.use_cache = @settings.use_cache
        conf.slice_loading_size = @settings.slice_loading_size
      end
    rescue StandardError => e
      abort("EXITING: Goo cannot connect to triplestore and/or search server:\n  #{e}\n#{e.backtrace.join("\n")}")
    end
  end

end
