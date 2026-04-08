require 'rsolr'
require_relative 'solr_schema_generator'
require_relative 'solr_schema'
require_relative 'solr_admin'
require_relative 'solr_query'

module SOLR

  class SolrConnector
    include Schema, Administration, Query
    attr_reader :solr, :collection_name, :alias_name

    def initialize(solr_url, collection_name)
      @solr_url = solr_url
      @collection_name = collection_name
      @alias_name = collection_name
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

    def init(force = false)
      if alias_exists?(@alias_name)
        return unless force

        # Alias exists — reinitialize schema on the underlying collection
        @collection_name = resolve_alias(@alias_name)
        init_schema
      else
        # First boot — create versioned collection + alias
        versioned_name = "#{@alias_name}_v1"
        create_collection(versioned_name)
        @collection_name = versioned_name
        init_schema
        create_alias(@alias_name.to_s, versioned_name)
      end
    end

  end
end

