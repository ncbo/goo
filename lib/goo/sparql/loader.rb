module Goo
  module SPARQL
    class Loader
      extend Goo::SPARQL::QueryPatterns



      def self.model_load(*options)
        options = options.last
        if options[:models] && options[:models].is_a?(Array) && \
                             (options[:models].length > Goo.slice_loading_size)
          options = options.dup
          models = options[:models]
          include_options = options[:include]
          models_by_id = Hash.new
          models.each_slice(Goo.slice_loading_size) do |model_slice|
            options[:models] = model_slice
            unless include_options.nil?
              options[:include] = include_options.dup
            end
            model_load_sliced(options)
            model_slice.each do |m|
              models_by_id[m.id] = m
            end
          end
          return models_by_id
        else
          return self.model_load_sliced(options)
        end
      end

      ##
      # always a list of attributes with subject == id
      ##
      def self.model_load_sliced(*options)
        options = options.last
        ids = options[:ids]
        klass = options[:klass]
        incl = options[:include]
        models = options[:models]
        aggregate = options[:aggregate]
        read_only = options[:read_only]
        order_by = options[:order_by]
        collection = options[:collection]
        count = options[:count]
        include_pagination = options[:include_pagination]
        equivalent_predicates = options[:equivalent_predicates]
        predicates = options[:predicates]
        predicates_map = get_predicate_map predicates
        binding_as = nil

        embed_struct, klass_struct = get_structures(aggregate, count, incl, include_pagination, klass, read_only)

        raise_resource_must_persistent_error(models) if models

        graphs = get_graphs(collection, klass)
        ids, models_by_id = get_models_by_id_hash(ids, klass, klass_struct, models)

        variables = [:id]

        query_options = {}
        #TODO: breaks the reasoner
        patterns = [[:id, RDF.type, klass.uri_type(collection)]]
        optional_patterns = []

        incl_embed = nil
        unmapped = nil
        bnode_extraction = nil

        if incl
          if incl.first && incl.first.is_a?(Hash) && incl.first.include?(:bnode)
            #limitation only one level BNODE
            bnode_extraction, patterns, variables = bnode_extraction(collection, incl, klass, patterns, variables)
          elsif incl.first == :unmapped
            #a filter with for ?predicate will be included
            binding_as, unmapped, variables = get_binding_as(patterns, predicates_map)
          else
            #make it deterministic
            incl, incl_embed, variables, graphs, optional_patterns = get_includes(collection, graphs, incl, klass, optional_patterns, query_options, variables)
          end
        end





        query_builder = Goo::SPARQL::QueryBuilder.new options
        select, aggregate_projections =
          query_builder.build_select_query(ids, binding_as,
                                           klass, graphs, optional_patterns,
                                           order_by, patterns, query_options, variables)

        expand_equivalent_predicates(select, equivalent_predicates)
        solution_mapper = Goo::SPARQL::SolutionMapper.new aggregate_projections, bnode_extraction,
                                                          embed_struct, incl_embed, klass_struct, models_by_id,
                                                          predicates_map, unmapped, variables, incl, options

        solution_mapper.map_each_solutions(select)
      end

      def self.expand_equivalent_predicates(query, eq_p)
        attribute_mappings = {}
        if eq_p && eq_p.length.positive?
          count_rewrites = 0
          if query.options[:optionals]
            query.options[:optionals].each do |opt|
              opt.each do |pattern|
                if pattern.predicate && pattern.predicate.is_a?(RDF::URI)
                  if eq_p.include?(pattern.predicate.to_s)
                    if attribute_mappings.include?(pattern.predicate.to_s)
                      #reuse filter
                      pattern.predicate =
                        RDF::Query::Variable.new(attribute_mappings[pattern.predicate.to_s])
                    else
                      query_predicate = pattern.predicate
                      var_name = "rewrite#{count_rewrites}"
                      pattern.predicate = RDF::Query::Variable.new(var_name)
                      expansion = eq_p[query_predicate.to_s]
                      expansion = expansion.map { |x| "?#{var_name} = <#{x}>" }
                      expansion = expansion.join " || "
                      # Instead of appending the filters to the end of the query, as in query.filter(expansion),
                      # we store them in the options[:filter] attribute. They will be included in the OPTIONAL
                      # sections when the query is constructed. According to AG, this is the CORRECT way of
                      # constructing the query.
                      # Because the FILTERs are _outside_ the OPTIONALs, they are applied to _every_
                      # row returned. i.e., only rows where ?rewrite0 is in its list _and_ ?rewrite1
                      # is in its list will be returned. I.e., the query will return NO results where
                      # ?rewrite0 or ?rewrite1 is NULL.
                      #
                      # All you need to do is to make sure that the FILTERS are applied only _inside_
                      # each OPTIONAL.
                      pattern.options[:filter] = expansion
                      # query.filter(expansion)
                      count_rewrites += 1
                      attribute_mappings[query_predicate.to_s] = var_name
                    end
                  end
                end
              end
            end
          end
        end
      end

      def self.get_predicate_map(predicates)
        predicates_map = nil
        if predicates
          uniq_p = predicates.uniq
          predicates_map = {}
          uniq_p.each do |p|
            i = 0
            key = ("var_#{p.last_part}#{i.to_s}").to_sym
            while predicates_map.include?(key)
              i += 1
              key = ("var_#{p.last_part}#{i.to_s}").to_sym
              break if i > 10
            end
            predicates_map[key] = p
          end
        end
        predicates_map
      end




      def self.get_includes(collection, graphs, incl, klass, optional_patterns, query_options, variables)
        incl = incl.to_a
        incl_direct = incl.select { |a| a.instance_of?(Symbol) }
        variables.concat(incl_direct)
        incl_embed = incl.select { |a| a.instance_of?(Hash) }
        raise ArgumentError, "Not supported case for embed" if incl_embed.length > 1
        incl.delete_if { |a| !a.instance_of?(Symbol) }

        if incl_embed.length.positive?
          incl_embed = incl_embed.first
          embed_variables = incl_embed.keys.sort
          variables.concat(embed_variables)
          incl.concat(embed_variables)
        end
        incl.each do |attr|
          graph, pattern = query_pattern(klass, attr, collection: collection)
          add_rules(attr, klass, query_options)
          optional_patterns << pattern if pattern
          graphs << graph if graph && (!klass.collection_opts || klass.inverse?(attr))
        end
        [incl, incl_embed, variables, graphs, optional_patterns]
      end

      def self.get_binding_as(patterns, predicates_map)
        binding_as = nil
        if predicates_map
          variables = [:id, :object, :bind_as]
          binding_as = []
          predicates_map.each do |var, pre|
            binding_as << [[[:id, pre, :object]], var, :bind_as]
          end
        else
          patterns << [:id, :predicate, :object]
          variables = [:id, :predicate, :object]
        end
        unmapped = true
        return binding_as, unmapped, variables
      end

      def self.bnode_extraction(collection, incl, klass, patterns, variables)
        bnode_conf = incl.first[:bnode]
        klass_attr = bnode_conf.keys.first
        bnode_extraction = klass_attr
        bnode = RDF::Node.new
        patterns << [:id, klass.attribute_uri(klass_attr, collection), bnode]
        bnode_conf[klass_attr].each do |in_bnode_attr|
          variables << in_bnode_attr
          patterns << [bnode, klass.attribute_uri(in_bnode_attr, collection), in_bnode_attr]
        end
        [bnode_extraction, patterns, variables]
      end

      def self.get_models_by_id_hash(ids, klass, klass_struct, models)
        models_by_id = {}
        if models
          ids = []
          models.each do |m|
            unless m.nil?
              ids << m.id
              models_by_id[m.id] = m
            end
          end
        elsif ids
          ids.each do |id|
            models_by_id[id] = klass_struct ? klass_struct.new : klass.new
            models_by_id[id].klass = klass if klass_struct
            models_by_id[id].id = id
          end
        else
          #a where without models

        end
        return ids, models_by_id
      end

      def self.get_graphs(collection, klass)
        graphs = [klass.uri_type(collection)]
        if collection
          if collection.is_a?(Array) && collection.length.positive?
            graphs = collection.map { |x| x.id }
          elsif !collection.is_a? Array
            graphs = [collection.id]
          end
        end
        graphs
      end

      def self.get_structures(aggregate, count, incl, include_pagination, klass, read_only)
        embed_struct = nil
        klass_struct = nil

        if read_only && !count && !aggregate
          include_for_struct = incl
          if !incl && include_pagination
            #read only and pagination we do not know the attributes yet
            include_for_struct = include_pagination
          end
          direct_incl = !include_for_struct ? [] :
                          include_for_struct.select { |a| a.instance_of?(Symbol) }
          incl_embed = include_for_struct.select { |a| a.instance_of?(Hash) }.first
          klass_struct = klass.struct_object(direct_incl + (incl_embed ? incl_embed.keys : []))

          embed_struct = {}
          if incl_embed
            incl_embed.each do |k, vals|
              next if klass.collection?(k)
              attrs_struct = []
              vals.each do |v|
                attrs_struct << v unless v.kind_of?(Hash)
                attrs_struct.concat(v.keys) if v.kind_of?(Hash)
              end
              embed_struct[k] = klass.range(k).struct_object(attrs_struct)
            end
          end
          direct_incl.each do |attr|
            next if embed_struct.include?(attr)
            embed_struct[attr] = klass.range(attr).struct_object([]) if klass.range(attr)
          end

        end
        return embed_struct, klass_struct
      end

      def self.raise_resource_must_persistent_error(models)
        models.each do |m|
          if (not m.nil?) && !m.respond_to?(:klass) #read only
            raise ArgumentError,
                  "To load attributes the resource must be persistent" unless m.persistent?
          end
        end
      end

      def self.include_bnodes(bnodes, collection, klass, models_by_id)
        #group by attribute
        attrs = bnodes.map { |x, y| y.attribute }.uniq
        attrs.each do |attr|
          struct = klass.range(attr)

          #bnodes that are in a range of goo ground models
          #for example parents and children in LD class models
          #we skip this cases for the moment
          next if struct.respond_to?(:model_name)

          bnode_attrs = struct.new.to_h.keys
          ids = bnodes.select { |x, y| y.attribute == attr }.map { |x, y| y.id }
          klass.where.models(models_by_id.select { |x, y| ids.include?(x) }.values)
               .in(collection)
               .include(bnode: { attr => bnode_attrs }).all
        end
      end

      def self.include_embed_attributes(collection, incl_embed, klass, objects_new)
        incl_embed.each do |attr, next_attrs|
          #anything to join ?
          attr_range = klass.range(attr)
          next if attr_range.nil?
          range_objs = objects_new.select { |id, obj|
            obj.instance_of?(attr_range) || (obj.respond_to?(:klass) && obj[:klass] == attr_range)
          }.values
          unless range_objs.empty?
            range_objs.uniq!
            attr_range.where().models(range_objs).in(collection).include(*next_attrs).all
          end
        end
      end

      def self.models_set_all_persistent(models_by_id, options)
        if options[:ids] #newly loaded
          models_by_id.each do |k, m|
            m.persistent = true
          end
        end
      end

      def self.model_set_collection_attributes(collection, klass, models_by_id, objects_new)
        collection_value = get_collection_value(collection, klass)
        if collection_value
          collection_attribute = klass.collection_opts
          models_by_id.each do |id, m|
            m.send("#{collection_attribute}=", collection_value)
          end
          objects_new.each do |id, obj_new|
            if obj_new.respond_to?(:klass)
              collection_attribute = obj_new[:klass].collection_opts
              obj_new[collection_attribute] = collection_value
            elsif obj_new.class.respond_to?(:collection_opts) &&
              obj_new.class.collection_opts.instance_of?(Symbol)
              collection_attribute = obj_new.class.collection_opts
              obj_new.send("#{collection_attribute}=", collection_value)
            end
          end
        end
      end

      def self.get_collection_value(collection, klass)
        collection_value = nil
        if klass.collection_opts.instance_of?(Symbol)
          if collection.is_a?(Array) && (collection.length == 1)
            collection_value = collection.first
          end
          if collection.respond_to? :id
            collection_value = collection
          end
        end
        collection_value
      end

      def self.initialize_empty_attributes(attr_to_load_if_empty, id, models_by_id)
        attr_to_load_if_empty.each do |empty_attr|
          # To avoid bug where the attr is not loaded, we return an empty array (because the data model is really bad)
          unless models_by_id[id].loaded_attributes.include?(empty_attr.to_sym)
            models_by_id[id].send("#{empty_attr}=", [], on_load: true)
          end
        end
      end

      def self.model_map_attributes_values(attr_to_load_if_empty, id, main_lang_hash, models_by_id, object, sol, v)
        if models_by_id[id].respond_to?(:klass)
          models_by_id[id][v] = object if models_by_id[id][v].nil?
        else
          model_attribute_val = models_by_id[id].instance_variable_get("@#{v.to_s}")
          if !models_by_id[id].class.handler?(v) || model_attribute_val.nil?
            if v != :id
              # if multiple language values are included for a given property, set the
              # corresponding model attribute to the English language value - NCBO-1662
              if sol[v].kind_of?(RDF::Literal)
                key = "#{v}#__#{id.to_s}"
                lang = sol[v].language

                #models_by_id[id].send("#{v}=", object, on_load: true) unless var_set_hash[key]
                #var_set_hash[key] = true if lang == :EN || lang == :en

                # We add the value only if it's language is in the main languages or if lang is nil

                if Goo.main_lang.nil?
                  models_by_id[id].send("#{v}=", object, on_load: true)

                elsif (v.to_s.eql?("prefLabel"))
                  # Special treatment for prefLabel where we want to extract the main_lang first, or anything else
                  unless main_lang_hash[key]

                    models_by_id[id].send("#{v}=", object, on_load: true)
                    if Goo.main_lang.include?(lang.to_s.downcase)
                      # If prefLabel from the main_lang found we stop looking for prefLabel
                      main_lang_hash[key] = true
                    end
                  end
                elsif (lang.nil? || Goo.main_lang.include?(lang.to_s.downcase))
                  models_by_id[id].send("#{v}=", object, on_load: true)
                else
                  attr_to_load_if_empty << v
                end
              else
                models_by_id[id].send("#{v}=", object, on_load: true)
              end
            end
          end
        end
      end

      def self.object_to_array(id, klass_struct, models_by_id, object, v)
        pre = klass_struct ? models_by_id[id][v] :
                models_by_id[id].instance_variable_get("@#{v}")
        if object.nil? && pre.nil?
          object = []
        elsif object.nil? && !pre.nil?
          object = pre
        elsif object
          object = !pre ? [object] : (pre.dup << object)
          object.uniq!
        end
        object
      end

      def self.dependent_model_creation(embed_struct, id, models_by_id, object, objects_new, v, options)
        klass = options[:klass]
        read_only = options[:read_only]
        if object.kind_of?(RDF::URI) && v != :id
          range_for_v = klass.range(v)
          if range_for_v
            if objects_new.include?(object)
              object = objects_new[object]
            elsif !range_for_v.inmutable?
              pre_val = get_pre_val(id, models_by_id, object, v, read_only)
              object = get_object_from_range(pre_val, embed_struct, object, objects_new, v, options)
            else
              object = range_for_v.find(object).first
            end
          end
        end
        object
      end

      def self.get_object_from_range(pre_val, embed_struct, object, objects_new, v, options)
        klass = options[:klass]
        read_only = options[:read_only]
        range_for_v = klass.range(v)
        if !read_only
          object = pre_val || klass.range_object(v, object)
          objects_new[object.id] = object
        else
          #depedent read only
          struct = pre_val || embed_struct[v].new
          struct.id = object
          struct.klass = range_for_v
          objects_new[struct.id] = struct
          object = struct
        end
        object
      end

    end
  end
end
