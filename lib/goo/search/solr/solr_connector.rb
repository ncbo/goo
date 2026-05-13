require 'rsolr'
require_relative 'solr_schema_generator'
require_relative 'solr_schema'
require_relative 'solr_admin'
require_relative 'solr_query'

module SOLR

  class SolrConnector
    include Schema, Administration, Query
    attr_reader :solr, :collection_name, :num_shards, :replication_factor, :alias_name

    def initialize(solr_url, collection_name, num_shards: 1, replication_factor: 1)
      @solr_url = solr_url
      @collection_name = collection_name
      @alias_name = collection_name
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

    def init(force = false, bootstrap_collection: nil)
      bootstrap_collection ||= @collection_name
      return init_with_alias(bootstrap_collection, force: force) if uses_alias?(bootstrap_collection)

      init_without_alias(force)
    end

    def init_without_alias(force = false)
      @aliased = false
      return if collection_exists?(@collection_name) && !force

      create_collection(@collection_name, @num_shards, @replication_factor)

      init_schema
    end

    def init_with_alias(bootstrap_collection, force: false)
      @aliased = true

      if alias_exists?(@alias_name)
        with_collection(resolve_alias(@alias_name).first) do
          init_schema if force
        end
      else
        with_collection(bootstrap_collection) do
          init_without_alias(force)
          create_or_update_alias(@alias_name, bootstrap_collection)
        end
      end

      @collection_name = @alias_name
      self
    end

    def aliased?
      !!@aliased || alias_exists?(@alias_name)
    end

    def create_reindex_collection(new_collection_name)
      new_name = new_collection_name.to_s
      raise ArgumentError, 'new_collection_name is required' if new_name.empty?
      raise ArgumentError, "Collection '#{new_name}' already exists" if collection_exists?(new_name)

      with_collection(new_name) do
        init_without_alias(true)
      end

      new_name
    end

    def promote_alias(new_collection_name, alias_name: @alias_name)
      new_name = new_collection_name.to_s
      alias_name = alias_name.to_s
      raise ArgumentError, 'new_collection_name is required' if new_name.empty?
      raise ArgumentError, "Collection '#{new_name}' does not exist" unless collection_exists?(new_name)

      old_collections = resolve_alias(alias_name)
      create_or_update_alias(alias_name, new_name)
      old_collections.first
    end

    def swap_alias_and_delete_old(new_collection_name, alias_name: @alias_name)
      old_collection = promote_alias(new_collection_name, alias_name: alias_name)
      delete_collection(old_collection) if old_collection && old_collection != new_collection_name.to_s
      old_collection
    end

    private

    def uses_alias?(bootstrap_collection)
      bootstrap_collection.to_s != @alias_name.to_s
    end

    def with_collection(collection_name)
      original_collection = @collection_name
      original_schema = @schema
      original_aliased = @aliased
      @collection_name = collection_name
      @schema = nil
      yield
    ensure
      @collection_name = original_collection
      @schema = original_schema
      @aliased = original_aliased
    end

  end
end
