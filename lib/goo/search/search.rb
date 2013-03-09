require 'rsolr'

module Goo


  module Search

    def self.included(base)
        base.extend(ClassMethods)
      end

      def index






        doc = get_indexable_object


        #document = JSON.dump copy_to_index

        Goo.search_connection.add doc

        self.class.commit
        #Goo.search_connection.commit :commit_attributes => {}

        #puts copy_to_index

   #     self.class.solr.add copy_to_index

      end

      def unindex

        id = get_index_id

        puts id

        Goo.search_connection.delete_by_id get_index_id




        self.class.commit


      end


      def get_index_id
        return self.class.goop_settings[:search_options][:index_id].call(self)
      end


      def get_indexable_object

        doc = self.class.goop_settings[:search_options][:document].call(self)
        doc[:id] = get_index_id
        return doc
      end



      module ClassMethods


        def search(q)
          response = Goo.search_connection.get 'select', :params => {:q => q}



          response["response"]["docs"].each{|doc| puts doc }



          #binding.pry
        end

        def indexBatch(collection)
          docs = Array.new
          collection.each do |c|
             docs << c.get_indexable_object


            #binding.pry



          end




          Goo.search_connection.add docs

          commit
        end


        def unindexBatch(collection)
          docs = Array.new
          collection.each do |c|
            docs << c.get_index_id
          end

          Goo.search_connection.delete_by_id docs


          commit

        end


        def unindexByQuery(query)
          Goo.search_connection.delete_by_query query


          commit

        end


        def commit(attrs=nil)
          Goo.search_connection.commit :commit_attributes => attrs || {}
        end

        def optimize(attrs=nil)
          Goo.search_connection.optimize :optimize_attributes => attrs || {}
        end
      end
  end
end