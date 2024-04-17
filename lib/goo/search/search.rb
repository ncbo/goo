require 'rsolr'

module Goo

  module Search

    def self.included(base)
      base.extend(ClassMethods)
    end

    def index(connection_name=:main)
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      doc = indexable_object
      Goo.search_connection(connection_name).add(doc)
    end

    def index_update(to_set, connection_name=:main)
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      raise ArgumentError, "Field names to be updated in index must be provided" if to_set.nil?
      doc = indexable_object(to_set)

      doc.each { |key, val|
        next if key === :id
        doc[key] = {set: val}
      }

      Goo.search_connection(connection_name).update(
          data: "[#{doc.to_json}]",
          headers: { 'Content-Type' => 'application/json' }
      )
    end

    def unindex(connection_name=:main)
      id = index_id
      Goo.search_connection(connection_name).delete_by_id(id)
    end

    # default implementation, should be overridden by child class
    def index_id()
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      @id.to_s
    end

    # default implementation, should be overridden by child class
    def index_doc(to_set=nil)
      raise NoMethodError, "You must define method index_doc in your class for it to be indexable"
    end

    def indexable_object(to_set=nil)
      doc = index_doc(to_set)
      # use resource_id for the actual term id because :id is a Solr reserved field
      doc[:resource_id] = doc[:id].to_s
      doc[:id] = index_id.to_s
      doc
    end


    module ClassMethods

      def search(q, params={}, connection_name=:main)
        params["q"] = q
        Goo.search_connection(connection_name).post('select', :data => params)
      end

      def indexBatch(collection, connection_name=:main)
        docs = Array.new
        collection.each do |c|



          # c.bring(:prefLabel)
          # binding.pry if c.prefLabel == "biodiversity"



          docs << c.indexable_object
        end
        Goo.search_connection(connection_name).add(docs)
      end

      def unindexBatch(collection, connection_name=:main)
        docs = Array.new
        collection.each do |c|
          docs << c.index_id
        end
        Goo.search_connection(connection_name).delete_by_id(docs)
      end

      def unindexByQuery(query, connection_name=:main)
        Goo.search_connection(connection_name).delete_by_query(query)
      end

      # Get the doc that will be indexed in solr
      def get_indexable_object()
        # To make the code less readable the guys that wrote it managed to hide the real function called by this line
        # It is "get_index_doc" in ontologies_linked_data Class.rb
        doc = self.class.model_settings[:search_options][:document].call(self)
        doc[:resource_id] = doc[:id].to_s
        doc[:id] = get_index_id.to_s
        # id: clsUri_ONTO-ACRO_submissionNumber. i.e.: http://lod.nal.usda.gov/nalt/5260_NALT_4
        doc
      end

      def indexCommit(attrs=nil, connection_name=:main)
        Goo.search_connection(connection_name).commit(:commit_attributes => attrs || {})
      end

      def indexOptimize(attrs=nil, connection_name=:main)
        Goo.search_connection(connection_name).optimize(:optimize_attributes => attrs || {})
      end

      def indexClear(connection_name=:main)
        # WARNING: this deletes ALL data from the index
        unindexByQuery("*:*", connection_name)
      end
    end
  end
end
