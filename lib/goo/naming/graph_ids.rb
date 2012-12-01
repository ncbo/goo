
module Goo
  module Naming 
    class PolicyNotSupported < StandardError
    end
    class InvalidGraphId < StandardError
    end
    
    def self.default_graph_id_generator
      :type_id_graph_policy
    end

    def self.get_graph_id(model_class)
      policy = model_class.goop_settings[:graph_policy] 
      #TODO: this can be improved to discover new policies based on the symbol.
      #      good enough for now
      if policy == :type_id_graph_policy
        graph_id = TypeIdGraphPolicy.get_graph_id(model_class)
        raise InvalidGraphId, "#{graph_id} does not parse as URI. Check the graph generator." \
          unless SparqlRd::Utils::Http.valid_uri? graph_id 
        return graph_id
      end
      #TODO implement other policies
      raise PolicyNotSupported, "Policy '#{policy}' not supported"
    end

    class TypeIdGraphPolicy
      def self.get_graph_id(model_class)
        vocabs = Goo::Naming.get_vocabularies 
        reg = vocabs.get_model_registry(model_class)
        prefix = vocabs.get_prefix reg[:prefix] 
        if reg[:prefix] == :default
          graph_id = prefix + model_class.to_s.camelize 
        else
          graph_id = prefix + reg[:type].to_s.camelize
        end
        return graph_id
      end
    end
  end
end
