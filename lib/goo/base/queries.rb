
module Goo
  module Queries

    class XsdTypeNotFoundForValue < StandardError
    end

    def self.value_to_rdf_object(value)
      raise StandardError, "hash not yet supported here" if value.kind_of? Hash

      xsd_type = SparqlRd::Utils::Xsd.xsd_type_from_value(value)
      raise XsdTypeNotFoundForValue, "XSD Type not found for value `#{value}` `#{value.class}`" \
        if xsd_type == nil
      SparqlRd::Utils::Xsd.xsd_string_from_value(value,xsd_type)
      xsd_type_string = SparqlRd::Utils::Xsd.types[xsd_type]
      return "\"\"\"#{value}\"\"\"^^<#{xsd_type_string}>"

    end
    
    def self.get_resource_class(id, store_name)
      resource_id = if id.kind_of? String then id else id.value end
      epr = Goo.store(store_name)
      q = <<eos
SELECT ?class WHERE { <#{resource_id}> a ?class }
LIMIT 1
eos
      rs = epr.query(q)
      model_class_uri = nil
      rs.each_solution do |sol|
        model_class_uri = sol.get(:class)
      end
      return nil if model_class_uri.nil?
      model = Goo.find_model_by_uri(model_class_uri.value)
      return model
    end

    def self.get_resource_attributes(resource_id, model_class, store_name)
      epr = Goo.store(store_name)
      q = <<eos
SELECT DISTINCT * WHERE { #{resource_id.to_turtle} ?predicate ?object }
eos
      rs = epr.query(q)
      attributes = Hash.new()
      rs.each_solution do |sol|
        pvalue = sol.get(:predicate).value
        attr_name = model_class.attr_for_predicate_uri(pvalue) 
        if attr_name == :rdf_type
          next
        end
        if attr_name.nil?
          #TODO some means of proper warning here
          #puts "attr_name not found for #{pvalue}"
        else
          attributes[attr_name] = [] if attributes[attr_name].nil?
          object = sol.get(:object)
          if object.iri? or object.bnode?
            object_class = self.get_resource_class(object.value, store_name)
            if not object.nil? and not object_class.nil?
              object_instance = object_class.new
              object_instance.lazy_loaded
              object_instance.resource_id= object
              attributes[attr_name] << object_instance
            else
              attributes[attr_name] << RDF::IRI.new(object.value)
            end
          else
            attributes[attr_name] << object.parsed_value
          end
        end
      end
      return attributes
    end

    def self.model_to_triples(model,resource_id, expand_bnodes = false)
      expand_bnodes = (expand_bnodes and (model.loaded? or not model.persistent?))
      model_uri = model.class.type_uri
      if resource_id.iri? or (not expand_bnodes) or (not model.uuid.nil?)
        triples = [ "#{resource_id.to_turtle} <#{RDF.TYPE_IRI}> <#{model_uri}>" ]
      else
        triples = [ " <#{RDF.TYPE_IRI}> <#{model_uri}>" ]
      end

      model.attributes.each_pair do |name,value|
        if model.class.inverse_attr? name
          next
        end
        next if name == :internals
        subject = resource_id
        predicate = model.class.uri_for_predicate(name)
        values = (value.kind_of? Array and value or [value])
        values.each do |single_value|
          next if single_value.nil?
          if single_value.kind_of? Goo::Base::Resource
            object_iri = single_value.resource_id
            if object_iri.bnode? and expand_bnodes and
              (single_value.loaded? or not single_value.persistent?)
              bnode_tuples = model_to_triples(
                                single_value, object_iri, expand_bnodes)
              object = "[\n\t\t" << (bnode_tuples.join ";\n\t\t") << " ]"
            else
              object = object_iri.to_turtle
            end
          elsif single_value.kind_of? SparqlRd::Resultset::Node 
            object = single_value.to_turtle
          else
            object = value_to_rdf_object(single_value) 
          end
          if resource_id.iri? or (not expand_bnodes) or (not model.uuid.nil?)
            triples << "#{subject.to_turtle} <#{predicate}> #{object}" 
          else
            triples << " <#{predicate}> #{object}" 
          end
        end
      end
      return triples
    end

    def self.value_as_array(value)
        model_values = nil
        if value.kind_of? Array
          model_values = value
        else
          model_values = [value]
        end
        model_values
    end
    
    def self.recursively_collect_modified_models(model, models)
      model.attributes.each_pair do |name,value|
        (value_as_array value).each do |single_value|
          if single_value.kind_of? Goo::Base::Resource
            if single_value.modified?
              if not single_value.resource_id.bnode?
                models << single_value
              end
              recursively_collect_modified_models(single_value, models)
            end
          end
        end
      end
    end

    #TODO: delete only includes connected bnodes for the moment
    def self.build_sparql_delete_query(models)
        queries = []
        #TODO: dangerous. Model [0] is the master, the others are bnodes.
        graph_id_master = Goo::Naming.get_graph_id(models[0].class)
        models.each do |model|
          triples = model_to_triples(model,model.resource_id, expand_bnodes = false)
          if model.resource_id.bnode?
            graph_id = graph_id_master
          else
            graph_id = Goo::Naming.get_graph_id(model.class)
          end 
          query = ["DELETE DATA { GRAPH <#{graph_id}> {"]
          triples.map! { |t| t + ' .' }
          query << triples
          query << "} }"
          queries << (query.join "\n")
        end
        return queries
    end

    def self.build_sparql_update_query(modified_models)
      queries = []
      modified_models.each do |mmodel|
        triples = model_to_triples(mmodel,mmodel.resource_id)
        mmodel.each_linked_base do |attr_name, umodel|
          if umodel.resource_id.bnode? and umodel.modified?
            triples.concat(model_to_triples(umodel, umodel.resource_id))
          end
        end
        triples.map! { |t| t + ' .' }
        graph_id = Goo::Naming.get_graph_id(mmodel.class)
        query = ["INSERT DATA { GRAPH <#{graph_id}> {"]
        query << triples
        query << "} }"
        queries << (query.join "\n")
      end
      return queries
    end
    
    def self.count_backlinks(resource_id, store_name)
      epr = Goo.store(store_name)
      q = <<eos
SELECT (COUNT(?s) as ?c) WHERE {
  ?s ?p #{resource_id.to_turtle} .
}
eos
      rs = epr.query(q)
      rs.each_solution do |sol|
        return sol.get(:c).parsed_value
      end
      nil
    end
    def self.reachable_objects_from_recursive(resource_id, objects, store_name)
      epr = Goo.store(store_name)
      models = Goo.models
      q = <<eos
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT DISTINCT ?o WHERE { 
  #{resource_id.to_turtle} ?p ?o .
  FILTER (!isLiteral(?o) && ?p != rdf:type) }
eos
      rs = epr.query(q)
      rs.each_solution do |sol|
        object = sol.get(:o)
        if not objects.include? object
          objects << object
        end
      end
    end

    def self.reachable_objects_from(resource_id, store_name, 
                                    count_backlinks=false)
      reached_objects = Set.new 
      reachable_objects_from_recursive(resource_id, reached_objects, store_name)
      filled_reached_objects = []
      reached_objects.each do |object| 
        model_class = get_resource_class(object,store_name)
        if not model_class.nil? 
          reached = { :id => object, 
                      :model_class => model_class}
          if count_backlinks
            reached[:backlink_count] = self.count_backlinks(object,store_name)
          end
          filled_reached_objects << reached
        end
      end
      return filled_reached_objects
    end
  
    def self.get_resource_id_by_uuid(uuid, model_class, store_name)
      uuid_predicate = model_class.uri_for_predicate(:uuid)
      q = <<eos
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
SELECT ?res WHERE {
  ?res <#{uuid_predicate}> "#{uuid}"^^xsd:string
}
eos
      epr = Goo.store(store_name)
      res = epr.query(q)
      res.each_solution do |sol|
        return sol.get(:res)
      end
      return nil  
    end
  
    def self.hash_to_triples_for_query(hash,model_class)
      patterns = []
      hash.each do |attr,v|
        predicate = model_class.uri_for_predicate(attr)
        [v].flatten.each do |value|
          if value.kind_of? Goo::Base::Resource
            rdf_object_string = value.resource_id.to_turtle 
          elsif value.kind_of? Hash
            if model_class.attributes[attr][:validators].include? :instance_of
              model_symbol = model_class.attributes[attr][:validators][:instance_of][:with]
              model_att = Goo.find_model_by_name(model_symbol)
              if model_att.nil?
                raise ArgumentError, "Wrong configuration in instance_of makes nested search fail." +
                                     "`#{model_symbol}` has no associated model"
              end
              rdf_object_string =  hash_to_triples_for_query(value,model_att)
            else
              raise ArgumentError, "Nested search cannot be performed due to missing instance_of"
            end
          else
            rdf_object_string = value_to_rdf_object(value)
          end
          patterns << " <#{predicate}> #{rdf_object_string};"
        end
      end
      return "[\n\t" + (patterns.join "\n") + " \n]" 
    end

    def self.search_by_attributes(attributes, model_class, store_name, ignore_inverse)
      patterns = []
      graph_id = Goo::Naming.get_graph_id(model_class)
      patterns << " ?subject a <#{ model_class.type_uri}> ."
      attributes.each do |attribute, value|
        next if value.nil?
        predicate = nil
        inverse = false
        if not ignore_inverse and model_class.inverse_attr? attribute
          inv_cls, inv_attr = model_class.inverse_attr_options(attribute)
          predicate = inv_cls.uri_for_predicate(inv_attr)
          inverse = true
        else
          predicate = model_class.uri_for_predicate(attribute)
        end
        if value.kind_of? Goo::Base::Resource
          rdf_object_string = value.resource_id.to_turtle 
        elsif value.kind_of? Hash
          if model_class.attributes[attribute][:validators].include? :instance_of
            model_symbol = model_class.attributes[attribute][:validators][:instance_of][:with]
            model_att = Goo.find_model_by_name(model_symbol)
            if model_att.nil?
              raise ArgumentError, "Wrong configuration in instance_of makes nested search fail." +
                                   "`#{model_symbol}` has no associated model"
            end
            rdf_object_string =  hash_to_triples_for_query(value,model_att)
          else
            raise ArgumentError, "Nested search cannot be performed due to missing instance_of"
          end
        else
          rdf_object_string = value_to_rdf_object(value)
        end
        if not inverse
          patterns << " ?subject <#{predicate}> #{rdf_object_string} ."
        else
          patterns << " #{rdf_object_string} <#{predicate}> ?subject ."
        end
      end
      patterns = patterns.join "\n"
      query = <<eos
SELECT DISTINCT ?subject WHERE {
    #{patterns}
}
eos
      return query
    end

  end
end
