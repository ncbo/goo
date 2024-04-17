module Goo
  module SPARQL
    module Triples

      def self.model_delete_triples(model)
        subject = model.id
        graph_delete = nil
        graph_delete = RDF::Graph.new
        graph_delete << [subject, RDF.type, model.class.uri_type(model.collection)]
        bnode_delete = {}
        model.class.attributes.each do |attr|
          next if model.class.collection?(attr)
          predicate = model.class.attribute_uri(attr,model.collection)
          begin
            value = model.send("#{attr}")
          rescue Goo::Base::AttributeNotLoaded => e
            next
          end
          values = value.kind_of?(Array) ? value : [value]
          values.each do |v|
            if v.is_a?(Struct) #bnode
              next if bnode_delete.include?(attr)
              delete_query = ["WITH #{model.graph.to_ntriples}"]
              delete_query_where = ["WHERE {"]
              delete_query << "DELETE {"
              delete_query << "#{model.id.to_ntriples} #{predicate.to_ntriples} ?x ."
              delete_query_where << delete_query.last
              var_i = 0
              v.to_h.each do |k,kk|
                delete_query << "?x #{Goo.vocabulary(nil)[k].to_ntriples} ?o#{var_i} ."
                delete_query_where << delete_query.last
                var_i += 1
              end
              delete_query << "}"
              delete_query_where << "}"
              delete_query.concat(delete_query_where)
              bnode_delete[attr] = delete_query.join "\n"
              next
            end
            object = v.class.respond_to?(:shape_attribute) ? v.id : v
            object = v.respond_to?(:klass) ? v[:id] : object
            next if object.nil?
            graph_delete << [subject, predicate, object]
          end
        end
        return [graph_delete,bnode_delete]
      end

      def self.model_update_triples(model)
        subject = model.id

        graph_delete = nil
        if model.previous_values
          graph_delete = RDF::Graph.new
          model.previous_values.each do |attr,value|
            predicate = model.class.attribute_uri(attr,model.collection)
            values = value.kind_of?(Array) ? value : [value]
            values.each do |v|
              object = v.class.respond_to?(:shape_attribute) ? v.id : v
              next if object.nil?
              graph_delete << [subject, predicate, object]
            end
          end
        end
          
        graph_insert = RDF::Graph.new
        unless model.persistent?
          graph_insert << [subject, RDF.type, model.class.uri_type(model.collection)]
        end

        model.modified_attributes.each do |attr|
          next if model.class.collection?(attr)
          predicate = model.class.attribute_uri(attr,model.collection)
          value = model.send("#{attr}")
          next if value.nil?
          values = value.kind_of?(Array) ? value : [value]
          object = nil
          values.each do |v|
            if v.is_a?(Struct) && !v.respond_to?(:klass)
              hh = v.to_h
              bnode = RDF::Node.new
              hh.each do |k,bvalue|
                bnode_pred = Goo.vocabulary(nil)[k]
                graph_insert << [bnode, bnode_pred, bvalue]
              end
              object = bnode
            else
              object = v.class.respond_to?(:shape_attribute) ? v.id : v
            end
            object = v.respond_to?(:klass) ? v[:id] : object
            graph_insert << [subject, predicate, object]
          end
        end
        return [graph_insert, graph_delete]

      end #model_update_triples

    end
  end
end

