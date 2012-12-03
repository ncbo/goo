
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
        return model_class.type_uri
      end
    end
  end
end
