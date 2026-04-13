require 'rsolr'
require_relative 'solr/solr_connector'

module Goo

  module Search

    def self.included(base)
      base.extend(ClassMethods)
    end

    def index(connection_name = nil, to_set = nil)
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      document = indexable_object(to_set)

      return if document.blank? || document[:id].blank?

      connection_name ||= self.class.search_collection_name
      unindex(connection_name)
      self.class.search_client(connection_name)&.index_document(document)
    end

    def index_update(attributes_to_update, connection_name = nil, to_set = nil)
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      raise ArgumentError, "Field names to be updated in index must be provided" if attributes_to_update.blank?

      old_doc = self.class.search("id:\"#{index_id}\"").dig("response", "docs")&.first

      raise ArgumentError, "ID must be set to be able to index" if old_doc.blank?

      doc = indexable_object(to_set)

      doc.each do |key, val|
        next unless attributes_to_update.any? { |attr| key.to_s.eql?(attr.to_s) || key.to_s.include?("#{attr}_") }
        old_doc[key] = val
      end

      connection_name ||= self.class.search_collection_name
      unindex(connection_name)

      old_doc.reject! { |k, v| k.to_s.end_with?('_sort') || k.to_s.end_with?('_sorts') }
      old_doc.delete("_version_")
      self.class.search_client(connection_name).index_document(old_doc)
    end

    def unindex(connection_name = nil)
      connection_name ||= self.class.search_collection_name
      self.class.search_client(connection_name)&.delete_by_id(index_id)
    end

    # default implementation, should be overridden by child class
    def index_id
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      @id.to_s
    end

    # default implementation, should be overridden by child class
    def index_doc(to_set = nil)
      raise NoMethodError, "You must define method index_doc in your class for it to be indexable"
    end

    def embedded_doc
      raise NoMethodError, "You must define method embedded_doc in your class for it to be indexable"
    end

    def indexable_object(to_set = nil)
      begin
        document = index_doc(to_set)
      rescue NoMethodError
        document = self.to_hash.reject { |k, _| !self.class.indexable?(k) }
        document.transform_values! do |v|
          is_array = v.is_a?(Array)
          v = Array(v).map do |x|
            if x.is_a?(Goo::Base::Resource)
              x.embedded_doc rescue x.id.to_s
            else
              if x.is_a?(RDF::URI)
                x.to_s
              else
                x.respond_to?(:object) ? x.object : x
              end
            end
          end
          is_array ? v : v.first
        end
      end

      # Merge sub-objects into a single document. For example, OntologySubmission.ontology
      # All Ontology object's properties are merged into a single document for OntologySubmission
      # Solr datatypes are also added, i.e:
      # {"name": "*_txt", "type": "text_general", stored: true, "multiValued": true}
      # {"name": "*_text", "type": "text_general", stored: true, "multiValued": false },
      document = document.reduce({}) do |h, (k, v)|
        if v.is_a?(Hash)
          v.each { |k2, v2| h["#{k}_#{k2}".to_sym] = v2 }
        else
          h[k] = v
        end
        h
      end

      model_name = self.class.model_name.to_s.downcase
      document.delete(:id)
      document.delete("id")

      document.transform_keys! do |k|
        self.class.index_document_attr(k)
      end

      document[:resource_id] = self.id.to_s
      document[:resource_model] = model_name
      document[:id] = index_id.to_s
      document
    end

    module ClassMethods

      def index_enabled?
        !@model_settings[:search_collection].nil?
      end

      def enable_indexing(collection_name, search_backend = :main, bootstrap_collection: nil, &block)
        @model_settings[:search_collection] = collection_name

        if block_given?
          Goo.add_search_connection(collection_name, search_backend, bootstrap_collection: bootstrap_collection, &block)
        else
          Goo.add_search_connection(collection_name, search_backend, bootstrap_collection: bootstrap_collection)
        end

        after_save :index
        after_destroy :unindex
      end

      def search_collection_name
        @model_settings[:search_collection]
      end

      def search_client(connection_name = search_collection_name)
        Goo.search_client(connection_name)
      end

      # Returns the SolrConnector for the reindex collection (if one has been created).
      def reindex_client
        Goo.reindex_client(search_collection_name)
      end

      def custom_schema?(connection_name = search_collection_name)
        search_client(connection_name)&.custom_schema?
      end

      def schema_generator
        Goo.search_client(search_collection_name).schema_generator
      end

      def index_document_attr(key)
        return key.to_s if custom_schema? || self.attribute_settings(key).nil?

        type = self.datatype(key)
        is_list = self.list?(key)
        fuzzy = self.fuzzy_searchable?(key)

        SOLR::SolrConnector.index_document_attr(key, type, is_list, fuzzy)
      end

      def search(q, params = {}, connection_name = search_collection_name)
        search_client(connection_name).search(q, params)
      end

      def submit_search_query(query, params = {}, connection_name = search_collection_name)
        search_client(connection_name).submit_search_query(query, params)
      end

      def indexBatch(collection, connection_name = search_collection_name)
        docs = collection.map(&:indexable_object)
        search_client(connection_name).index_document(docs)
      end

      def unindexBatch(collection, connection_name = search_collection_name)
        docs = collection.map(&:index_id)
        search_client(connection_name).delete_by_id(docs)
      end

      def unindexByQuery(query, connection_name = search_collection_name)
        search_client(connection_name)&.delete_by_query(query)
      end

      def indexCommit(attrs = nil, connection_name = search_collection_name)
        search_client(connection_name)&.index_commit(attrs)
      end

      def indexOptimize(attrs = nil, connection_name = search_collection_name)
        search_client(connection_name).index_optimize(attrs)
      end

      # WARNING: this deletes ALL data from the index
      def indexClear(connection_name = search_collection_name)
        search_client(connection_name).clear_all_data
      end
    end
  end
end
