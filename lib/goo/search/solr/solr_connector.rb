require 'rsolr'
require_relative 'solr_schema_generator'
require_relative 'solr_schema'
require_relative 'solr_admin'
require_relative 'solr_query'

module SOLR

  class SolrConnector
    include Schema, Administration, Query
    attr_reader :solr, :collection_name, :num_shards, :replication_factor

    def initialize(solr_url, collection_name, num_shards: 1, replication_factor: 1)
      @solr_url = solr_url
      @collection_name = collection_name
      @num_shards = num_shards
      @replication_factor = replication_factor
      @solr = RSolr.connect(url: collection_url)

      # Perform a status test and wait up to 30 seconds before raising an error
      wait_time = 0
      max_wait_time = 30
      until solr_alive? || wait_time >= max_wait_time
        sleep 1
        wait_time += 1
      end
      raise "Solr instance not reachable within #{max_wait_time} seconds" unless solr_alive?


      @custom_schema = false
    end

    alias physical_collection_name collection_name

    def init(force = false)
      return if collection_exists?(@collection_name) && !force

      create_collection(@collection_name, @num_shards, @replication_factor)

      init_schema
    end

  end
end
