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
      @num_shards = normalize_topology_value(num_shards, 'num_shards')
      @replication_factor = normalize_topology_value(replication_factor, 'replication_factor')
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

    def init(force = false, bootstrap_collection: nil, clear_data: false)
      bootstrap_collection ||= @collection_name

      # SAFETY: SolrCloud aliases share a namespace with collections. If
      # @alias_name already names a real collection (not an alias), creating
      # an alias with that name silently shadows the collection — queries
      # route to the alias target and writes go to a different physical
      # core. This guards against init() with force=false destroying data.
      if collection_exists?(@alias_name) && !alias_exists?(@alias_name)
        @aliased = false
        # A live collection may carry data-driven fields the generator does
        # not declare; only ADD what is missing (e.g. a dynamicField dropped
        # by an interrupted schema update) — never rebuild, which would drop
        # those fields from the schema and break search on them until a full
        # reindex. The full rebuild requires explicit force (previously this
        # early return made force a silent no-op here).
        force ? init_schema(clear_data: clear_data) : repair_schema_additively
        return self
      end

      return init_with_alias(bootstrap_collection, force: force, clear_data: clear_data) if uses_alias?(bootstrap_collection)

      init_without_alias(force, clear_data: clear_data)
    end

    def init_without_alias(force = false, clear_data: false)
      @aliased = false
      if collection_exists?(@collection_name)
        # See init(): additive repair only, unless explicitly forced.
        force ? init_schema(clear_data: clear_data) : repair_schema_additively
        return
      end

      create_collection(@collection_name, @num_shards, @replication_factor)

      init_schema(clear_data: clear_data)
    end

    def init_with_alias(bootstrap_collection, force: false, clear_data: false)
      @aliased = true

      if alias_exists?(@alias_name)
        with_collection(resolve_alias(@alias_name).first) do
          # See init(): additive repair only on the live resolved collection,
          # unless explicitly forced.
          force ? init_schema(clear_data: clear_data) : repair_schema_additively
        end
      else
        # Defense-in-depth: the guard in init() should catch this earlier,
        # but if anything constructs a connector and calls init_with_alias
        # directly, refuse to overwrite an existing collection.
        if collection_exists?(@alias_name)
          raise "Refusing to create alias '#{@alias_name}': name conflicts with an existing Solr collection. Aliases and collections share a namespace; creating this alias would shadow the collection."
        end

        with_collection(bootstrap_collection) do
          bootstrap_exists = collection_exists?(@collection_name)
          create_collection(@collection_name, @num_shards, @replication_factor)
          init_schema(clear_data: clear_data) if force || !bootstrap_exists
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

    def reset_schema!
      init_schema(clear_data: true)
    end

    private

    def normalize_topology_value(value, name)
      value = 1 if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      integer_value = Integer(value)
      raise ArgumentError, "#{name} must be greater than zero" unless integer_value.positive?

      integer_value
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def uses_alias?(bootstrap_collection)
      bootstrap_collection.to_s != @alias_name.to_s
    end

    def with_collection(collection_name)
      original_collection = @collection_name
      original_schema = @schema
      original_aliased = @aliased
      original_solr = @solr
      @collection_name = collection_name
      @solr = RSolr.connect(url: collection_url)
      @schema = nil
      yield
    ensure
      @collection_name = original_collection
      @schema = original_schema
      @aliased = original_aliased
      @solr = original_solr
    end

  end
end
