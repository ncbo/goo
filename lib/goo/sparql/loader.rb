require 'request_store'
module Goo
  module SPARQL
    module Loader
      class << self
        include Goo::SPARQL::QueryPatterns

        def model_load(*options)
          options = options.last
          set_request_lang(options)
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
            models_by_id
          else
            model_load_sliced(options)
          end
        end

        ##
        # always a list of attributes with subject == id
        ##
        def model_load_sliced(*options)
          options = options.last
          klass = options[:klass]
          incl = options[:include]
          models = options[:models]
          collection = options[:collection]

          embed_struct, klass_struct = get_structures(options[:aggregate],  options[:count] , incl, options[:include_pagination], klass, options[:read_only])
          raise_not_persistent_error(models) if models

          graphs = get_graphs(collection, klass)
          models_by_id = get_models_by_id_hash( options[:ids], klass, klass_struct, models)

          #TODO: breaks the reasoner
          patterns = [[:id, RDF.type, klass.uri_type(collection)]]

          incl_embed = nil
          bnode_extraction = nil
          properties_to_include = []
          variables = [:id]
          if incl && !incl.empty?
            if incl.first.is_a?(Hash) && incl.first.include?(:bnode)
              #limitation only one level BNODE
              bnode_extraction, patterns, variables = get_bnode_extraction(collection, incl, klass, patterns)
            else
              variables = %i[id attributeProperty attributeObject]
              if incl.first == :unmapped
                properties_to_include = predicate_map(options[:predicates])
              else
                graphs, properties_to_include, incl_embed = get_includes(collection, graphs, incl, klass)
              end
            end
          end


          options[:properties_to_include] = properties_to_include


          select, aggregate_projections = Goo::SPARQL::QueryBuilder.new(options)
                                                                   .build_query(models_by_id.keys, variables, graphs, patterns)

          solution_mapper = Goo::SPARQL::SolutionMapper.new aggregate_projections, bnode_extraction,
                                                            embed_struct, incl_embed, klass_struct, models_by_id,
                                                            variables, options

          solution_mapper.map_each_solutions(select)
        end

        private

        def set_request_lang(options)
          options[:requested_lang] = RequestStore.store[:requested_lang]
        end

        def predicate_map(predicates)
          predicates_map = nil
          if predicates
            uniq_p = predicates.uniq
            predicates_map = {}
            uniq_p.each do |p|
              i = 0
              key = ('var_' + p.last_part + i.to_s).to_sym
              while predicates_map.include?(key)
                i += 1
                key = ('var_' + p.last_part + i.to_s).to_sym
                break if i > 10
              end
              predicates_map[key] = { uri: p, is_inverse: false }
            end
          end
          predicates_map
        end

        def get_includes(collection, graphs, incl, klass)
          incl_embed ,incl = get_embed_includes(incl)
          incl = incl.to_a
          incl.delete_if { |a| !a.instance_of?(Symbol) }
          properties_to_include = {}
          incl.each do |attr|
            graph, pattern = query_pattern(klass, attr, collection: collection)
            if klass.attributes(:all).include?(attr)
              properties_to_include[attr] = { uri: pattern[1], is_inverse: klass.inverse?(attr) } # [property_attr, property_uri , inverse: true]
            end
            graphs << graph if graph && (!klass.collection_opts || klass.inverse?(attr))
          end
          [graphs, properties_to_include, incl_embed]
        end

        def get_bnode_extraction(collection, incl, klass, patterns)
          bnode_conf = incl.first[:bnode]
          klass_attr = bnode_conf.keys.first
          bnode_extraction = klass_attr
          bnode = RDF::Node.new
          variables = [:id]
          patterns << [:id, klass.attribute_uri(klass_attr, collection), bnode]
          bnode_conf[klass_attr].each do |in_bnode_attr|
            variables << in_bnode_attr
            patterns << [bnode, klass.attribute_uri(in_bnode_attr, collection), in_bnode_attr]
          end
          [bnode_extraction, patterns, variables]
        end

        def get_models_by_id_hash(ids, klass, klass_struct, models)
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
          models_by_id
        end

        def get_graphs(collection, klass)
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

        def get_structures(aggregate, count, incl, include_pagination, klass, read_only)
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
          [embed_struct, klass_struct]
        end

        def raise_not_persistent_error(models)
          models.each do |m|
            if (not m.nil?) && !m.respond_to?(:klass) #read only
              raise ArgumentError,
                    'To load attributes the resource must be persistent' unless m.persistent?
            end
          end
        end

        def get_embed_includes(incl)
          incl_embed = incl.select { |a| a.instance_of?(Hash) }
          raise ArgumentError, 'Not supported case for embed' if incl_embed.length > 1
          if incl_embed.length.positive?
            incl_embed = incl_embed.first
            embed_variables = incl_embed.keys.sort
            #variables.concat(embed_variables)
            incl.concat(embed_variables)
          end
          [incl_embed, incl]
        end
      end

    end
  end
end
