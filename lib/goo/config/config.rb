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
    @settings.goo_redis_host      ||= ENV['REDIS_HOST'] || 'localhost'
    @settings.goo_redis_port      ||= ENV['REDIS_PORT'] || 6379
    @settings.bioportal_namespace ||= ENV['BIOPORTAL_NAMESPACE'] || 'http://data.bioontology.org/'
    @settings.query_logging       ||= ENV['QUERIES_LOGGING'] || false
    @settings.query_logging_file  ||= ENV['QUERIES_LOGGING_FILE'] || './sparql.log'
    @settings.queries_debug       ||= ENV['QUERIES_DEBUG'] || false
    @settings.slice_loading_size  ||= ENV['GOO_SLICES']&.to_i || 500
    puts "(GOO) >> Using RDF store (#{@settings.goo_backend_name}) #{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_query}"
    puts "(GOO) >> Using term search server at #{@settings.search_server_url}"
    puts "(GOO) >> Using Redis instance at #{@settings.goo_redis_host}:#{@settings.goo_redis_port}"
    puts "(GOO) >> Using Query logging: #{@settings.query_logging_file}" if @settings.query_logging

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
        conf.add_query_logger(enabled: @settings.query_logging, file: @settings.query_logging_file)

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
        conf.use_cache = false
        conf.slice_loading_size = @settings.slice_loading_size
      end
    rescue StandardError => e
      abort("EXITING: Goo cannot connect to triplestore and/or search server:\n  #{e}\n#{e.backtrace.join("\n")}")
    end
  end

  def self.test_reset
    if @@sparql_backends[:main][:query].url.to_s["localhost"].nil?
      raise Exception, "only for testing"
    end
    @@sparql_backends = {}
    Goo.add_sparql_backend(:main,
                            backend_name: @settings.goo_backend_name,
                            query: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_query}",
                            data: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_data}",
                            update: "http://#{@settings.goo_host}:#{@settings.goo_port}#{@settings.goo_path_update}",
                            options: { rules: :NONE })
  end

end
