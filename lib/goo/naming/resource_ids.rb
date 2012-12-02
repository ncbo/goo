
module Goo
  module Naming
    class InvalidResourceId < StandardError
    end

    def self.getResourceId(model)
      policy = model.class.goop_settings[:unique][:generator]
      #TODO: this can be improved to discover new policies based on the symbol.
      #      good enough for now
      if policy == :concat_and_encode
        resource_id = UniqueFieldsConcatPolicy.getResourceId(model)
        raise InvalidResourceId, 
            "#{resource_id} does not parse as URI. Check the resource_id generator." \
          unless SparqlRd::Utils::Http.valid_uri? resource_id.value
        return resource_id
      end
      if policy == :anonymous
        resource_id = AnonymousPolicy.getResourceId(model)
        return resource_id
      end
      #TODO implement other policies
      raise PolicyNotSupported, "Policy '#{policy}' not supported"
    end

    class UniqueFieldsConcatPolicy
      def self.getResourceId(model)
        fields = model.class.goop_settings[:unique][:fields]
        name = []
        fields.each do |field|
          field_value = model.send("#{field}")
          raise ArgumentError, "Field #{field} has no value. Value is needed to generate resource id" \
            if field_value == nil or (field_value.kind_of? Array and field_value.length == 0)
          raise ArgumentError, "Field #{field} holds multiple values. " << \
                               "Unique Resource policy cannot be constructed from N-ary relations" \
                               if field_value.kind_of? Array and field_value.length > 1
          name << field_value
        end
        uri_last_fragment = URI.encode(name.join "+")
        binding.pry 
        vocabs = Goo::Naming.get_vocabularies 
        reg = vocabs.get_model_registry(model.class)
        prefix = vocabs.get_prefix reg[:prefix] 
        type = reg[:type].to_s.camelize.downcase
        return RDF::IRI.new(prefix + type + "/" + uri_last_fragment)
      end
    end

    class AnonymousPolicy
      def self.getResourceId(model)
        if false and Goo.is_skolem_supported?
          return RDF::BNode.new(model.hash)
        end
        uri = model.class.prefix + ".well-known/genid/" + model.uuid
        return RDF::BNode.new(uri)
      end
    end

  end
end
