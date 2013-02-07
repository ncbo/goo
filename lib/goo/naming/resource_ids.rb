require 'cgi'

module Goo
  module Naming
    class InvalidResourceId < StandardError
    end

    def self.getResourceId(model)
      if model.class.goop_settings[:name_with]
        return model.class.goop_settings[:name_with].call(model)
      end
      policy = model.class.goop_settings[:unique][:generator]
      #TODO: this can be improved to discover new policies based on the symbol.
      #      good enough for now
      if policy == :concat_and_encode
        resource_id = UniqueFieldPolicy.getResourceId(model)
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

    class UniqueFieldPolicy
      def self.getResourceId(model)
        fields = model.class.goop_settings[:unique][:fields]
        if fields.length != 1
          raise InvalidResourceId, "Model '#{model.class.name}' has '#{fields.length}' :unique attributes. Only 1 is allowed."
        end
        #this policy only allows for one unique attribute
        field = fields[0]
        field_value = model.send("#{field}")
        raise ArgumentError, "Field #{field} has no value. Value is needed to generate resource id" \
          if field_value == nil or (field_value.kind_of? Array and field_value.length == 0)
        raise ArgumentError, "Field #{field} holds multiple values. " << \
                             "Unique Resource policy cannot be constructed from multiple value attributes" \
                             if field_value.kind_of? Array and field_value.length > 1
        if field_value.kind_of? Array
          field_value = field_value[0]
        end
        uri_last_fragment = CGI.escape(field_value)
        return RDF::IRI.new(model.class.prefix + model.class.goo_name.to_s + '/' + uri_last_fragment)
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
