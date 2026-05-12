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

    def init(force: false, bootstrap_collection: nil)
      bootstrap_name = (bootstrap_collection || @alias_name).to_s

      if uses_alias?(bootstrap_name)
        init_with_alias(force: force, bootstrap_name: bootstrap_name)
      else
        init_without_alias(force: force)
      end
    end

    # Returns true if this connector uses an alias (i.e. supports re-indexing).
    def aliased?
      @aliased
    end

    # Creates a new collection for re-indexing with the same schema as the current one.
    # Does NOT swap the alias — call swap_alias_and_delete_old after indexing is complete.
    def create_reindex_collection(new_collection_name)
      raise "Re-indexing requires an aliased connector" unless aliased?
      raise ArgumentError, "new_collection_name is required" unless new_collection_name && !new_collection_name.to_s.empty?

      new_name = new_collection_name.to_s
      raise ArgumentError, "Collection '#{new_name}' already exists" if collection_exists?(new_name)

      create_collection(new_name)

      # Apply the same schema to the new collection by temporarily
      # pointing schema operations at it, then restoring
      original_collection = @collection_name
      @collection_name = new_name
      begin
        init_schema
      ensure
        @collection_name = original_collection
      end

      new_name
    end

    # Atomically swaps the alias to point to a new collection.
    # Returns the old collection name. Updates @collection_name to reflect the new target.
    def promote_alias(new_collection_name)
      raise "Alias promotion requires an aliased connector" unless aliased?

      new_name = new_collection_name.to_s
      raise ArgumentError, "Collection '#{new_name}' does not exist" unless collection_exists?(new_name)

      old_collection = resolve_alias(@alias_name.to_s)
      create_alias(@alias_name.to_s, new_name)
      @collection_name = new_name

      old_collection
    end

    # Atomically swaps the alias to point to a new collection and deletes the old one.
    # Updates @collection_name to reflect the new target.
    def swap_alias_and_delete_old(new_collection_name)
      old_collection = promote_alias(new_collection_name)
      delete_collection(old_collection) if old_collection && old_collection != @collection_name
    end

    private

    # An alias is used when the bootstrap collection name differs from the alias name.
    def uses_alias?(bootstrap_name)
      bootstrap_name.to_s != @alias_name.to_s
    end

    # Init for connectors that use an alias (re-index capable).
    def init_with_alias(force: false, bootstrap_name:)
      @aliased = true

      if alias_exists?(@alias_name)
        @collection_name = resolve_alias(@alias_name)
        init_schema if force
      else
        create_collection(bootstrap_name)
        @collection_name = bootstrap_name
        init_schema
        create_alias(@alias_name.to_s, bootstrap_name)
      end
    end

    # Init for connectors without an alias (simple collection, no re-index support).
    def init_without_alias(force: false)
      @aliased = false

      return if collection_exists?(@collection_name) && !force

      create_collection
      init_schema
    end

  end
end

