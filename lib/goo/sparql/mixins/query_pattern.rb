module Goo
  module SPARQL
    module QueryPatterns



      def query_pattern(klass,attr,**opts)
        value = opts[:value] || nil
        subject = opts[:subject] || :id
        collection = opts[:collection] || nil
        value = value.id if value.class.respond_to?(:model_settings)
        if klass.attributes(:all).include?(attr) && klass.inverse?(attr)
          inverse_opts = klass.inverse_opts(attr)
          on_klass = inverse_opts[:on]
          inverse_klass = on_klass.respond_to?(:model_name) ? on_klass: Goo.models[on_klass]
          if inverse_klass.collection?(inverse_opts[:attribute])
            #inverse on collection - need to retrieve graph
            #graph_items_collection = attr
            #inverse_klass_collection = inverse_klass
            #return [nil, nil]
          end
          predicate = inverse_klass.attribute_uri(inverse_opts[:attribute],collection)
          return [ inverse_klass.uri_type(collection) ,
                   [ value.nil? ? attr : value, predicate, subject ]]
        else
          predicate = nil
          if attr.is_a?(Symbol)
            predicate = klass.attribute_uri(attr,collection)
          elsif attr.is_a?(RDF::URI)
            predicate = attr
          else
            raise ArgumentError, "Unknown attribute param for query `#{attr}`"
          end
          #unknown predicate
          return [klass.uri_type(collection),
                  [ subject , predicate , value.nil? ? attr : value]]
        end

      end


    end
  end
end

