require 'sparql/client'
require 'sparql/client/query'

module Goo
  module SPARQL
    module Queries

      def self.duplicate_attribute_value?(model,attr,store=:main)
        value = model.instance_variable_get("@#{attr}")
        if !value.instance_of? Array
          so = Goo.sparql_query_client(store).ask.from(model.graph).
            whether([:id, model.class.attribute_uri(attr), value]).
            filter("?id != #{model.id.to_ntriples}")
          return so.true?
        else
          #not yet support for unique arrays
        end
      end

      def self.sub_property_predicates(*graphs)
        graphs = graphs.flatten!
        client = Goo.sparql_query_client(:main)
        select = client.select(:subP, :superP).distinct()
        select.where([:subP, Goo.vocabulary(:rdfs)[:subPropertyOf], :superP])
        select.from(graphs)
        tuples = []
        select.each_solution do |sol|
          tuples << [sol[:subP],sol[:superP]]
        end
        return tuples
      end

      def self.graph_predicates(*graphs)
        graphs = graphs.flatten
        client = Goo.sparql_query_client(:main)
        select = client.select(:predicate).distinct()
        select.where([:subject, :predicate, :object])
        select.from(graphs)
        predicates = []
        select.each_solution do |sol|
          predicates << sol[:predicate]
        end
        return predicates
      end

      def self.model_exist(model,id=nil,store=:main)
        id = id || model.id
        so = Goo.sparql_query_client(store).ask.from(model.graph).
          whether([id, RDF.type, model.class.uri_type(model.collection)])
        return so.true?
      end


      def self.model_load(*options)
        Goo::SPARQL::Loader.model_load(*options)
      end


      end #Queries
    end #SPARQL
end #Goo
