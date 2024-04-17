module Goo
  module SPARQL
    class SolutionMapper
      BNODES_TUPLES = Struct.new(:id, :attribute)

      def initialize(aggregate_projections, bnode_extraction, embed_struct,incl_embed, klass_struct, models_by_id, variables, options)

        @aggregate_projections = aggregate_projections
        @bnode_extraction = bnode_extraction
        @embed_struct = embed_struct
        @incl_embed = incl_embed
        @incl = options[:include]
        @klass_struct = klass_struct
        @models_by_id = models_by_id
        @properties_to_include = options[:properties_to_include]
        @unmapped = options[:include] && options[:include].first.eql?(:unmapped)
        @variables = variables
        @ids = models_by_id.keys
        @klass = options[:klass]
        @read_only = options[:read_only]
        @count = options[:count]
        @collection = options[:collection]
        @options = options
      end

      def map_each_solutions(select)
        found = Set.new
        objects_new = {}
        list_attributes = Set.new(@klass.attributes(:list))

        @lang_filter = Goo::SPARQL::Solution::LanguageFilter.new(requested_lang: @options[:requested_lang].to_s, unmapped: @unmapped,
                                                                 list_attributes: list_attributes)

        if @options[:page]
          # for using prefixes before queries
          # mdorf, 7/27/2023, AllegroGraph supplied a patch (rfe17161-7.3.1.fasl.patch)
          # that enables implicit internal ordering. The patch requires the prefix below
          select.prefix('franzOption_imposeImplicitBasicOrdering: <franz:yes>')
          # mdorf, 1/24/2024, AllegroGraph 8 introduced a new feature that allows caching OFFSET/LIMIT queries
          select.prefix('franzOption_allowCachingResults: <franz:yes>')
        end

        # for troubleshooting specific queries (write 1 of 3)
        # ont_to_parse = 'OAE'
        # sub_id = 171
        # ont_to_parse = 'MONDO'
        # sub_id = 55
        # debug_file = "/srv/ncbo/repository/#{ont_to_parse}/#{sub_id}/#{ont_to_parse}_queries.txt"
        # File.write(debug_file, select.to_s + "\n", mode: 'a') if select.to_s =~ /OFFSET \d+ LIMIT 2500$/

        select.each_solution do |sol|

          next if sol[:some_type] && @klass.type_uri(@collection) != sol[:some_type]
          return sol[:count_var].object if @count

          found.add(sol[:id])
          id = sol[:id]

          # for troubleshooting specific queries (write 2 of 3)
          # File.write(debug_file, id + "\n", mode: 'a') if select.to_s =~ /OFFSET \d+ LIMIT 2500$/

          create_model(id)

          if @bnode_extraction
            add_bnode_to_model(sol)
            next
          end

          if @unmapped
            add_unmapped_to_model(sol)
            next
          end

          if @aggregate_projections
            add_aggregations_to_model(sol)
            next
          end

          predicates = find_predicate(sol[:attributeProperty], inverse: !sol[:inverseAttributeObject].nil?)
          next if predicates.empty?

          object = if sol[:attributeObject]
                     sol[:attributeObject]
                   elsif sol[:inverseAttributeObject]
                     sol[:inverseAttributeObject]
                   end


          predicates.each do |predicate|
            # bnodes
            if bnode_id?(object, predicate)
              objects_new = bnode_id_tuple(id, object, objects_new, predicate)
              next
            end

            objects, objects_new = get_value_object(id, objects_new, object, list_attributes, predicate)
            add_object_to_model(id, objects, object, predicate)
          end

        end
        # for this moment we are not going to enrich models , maybe we will use it if the results are empty
        @lang_filter.fill_models_with_all_languages(@models_by_id)

        # for troubleshooting specific queries (write 3 of 3)
        # File.write(debug_file, "\n\n", mode: 'a') if select.to_s =~ /OFFSET \d+ LIMIT 2500$/

        init_unloaded_attributes(list_attributes)

        return @models_by_id if @bnode_extraction

        model_set_collection_attributes(@models_by_id, objects_new)

        # remove from models_by_id elements that were not touched
        @models_by_id.select! { |k, _m| found.include?(k) }

        models_set_all_persistent(@models_by_id) unless @read_only

        # next level of embed attributes
        include_embed_attributes(@incl_embed, objects_new) if @incl_embed && !@incl_embed.empty?

        # bnodes
        blank_nodes = objects_new.select { |id, _obj| id.is_a?(RDF::Node) && id.anonymous? }
        include_bnodes(blank_nodes, @models_by_id) unless blank_nodes.empty?

        models_unmapped_to_array(@models_by_id) if @unmapped


        @models_by_id
      end

      private

      def find_predicate(predicate, unmapped: false, inverse: false)
        if Goo.backend_4s? || Goo.backend_gb?
          return [] if predicate.nil? || unmapped && @properties_to_include[predicate].nil?
          predicate = predicate.to_s.to_sym
        else
          predicate = @properties_to_include.select { |x, v| v[:uri].to_s.eql?(predicate.to_s) || v[:equivalents]&.any? { |e| e.to_s.eql?(predicate.to_s) } }
          return [] if predicate.empty?

          predicate = predicate.select{|x, y| y[:is_inverse]&.eql?(inverse)}.keys
        end
        Array(predicate)
      end

      def init_unloaded_attributes(list_attributes)
        return if @incl.nil? || @incl.empty?
        # Here we are setting to nil all attributes that have been included but not found in the triplestore
        @models_by_id.each do |id, m|
          @incl.each do |attr_to_incl|
            is_handler = m.respond_to?(:handler?) && m.class.handler?(attr_to_incl)
            next if attr_to_incl.to_s.eql?('unmapped') || is_handler

            loaded = m.respond_to?('loaded_attributes') && m.loaded_attributes.include?(attr_to_incl)
            is_list = list_attributes.include?(attr_to_incl)
            is_struct = m.respond_to?(:klass)

            # Go through all models queried
            if is_struct
              m[attr_to_incl] = [] if is_list && m[attr_to_incl].nil?
            elsif is_list && (!loaded || m.send(attr_to_incl.to_s).nil?)
              m.send("#{attr_to_incl}=", [], on_load: true)
            elsif !loaded && !is_list && m.respond_to?("#{attr_to_incl}=")
              m.send("#{attr_to_incl}=", nil, on_load: true)
            end
          end
        end
      end

      def get_value_object(id, objects_new, object, list_attributes, predicate)
        object = object.object if object && !(object.is_a? RDF::URI)
        range_for_v = @klass.range(predicate)


        if object.is_a?(RDF::URI) && (predicate != :id) && !range_for_v.nil?
          if objects_new.include?(object)
            object = objects_new[object]
          elsif !range_for_v.inmutable?
            pre_val = get_preload_value(id, object, predicate)
            object, objects_new = if !@read_only
                                    preloaded_or_new_object(object, objects_new, pre_val, predicate)
                                  else
                                    # depedent read only
                                    preloaded_or_new_struct(object, objects_new, pre_val, predicate)
                                  end
          else
            object = range_for_v.find(object).first
          end
        end

        if list_attributes.include?(predicate)
          pre = @klass_struct ? @models_by_id[id][predicate] : @models_by_id[id].instance_variable_get("@#{predicate}")

          if object.nil?
            object = pre.nil? ? [] : pre
          else
            object = pre.nil? ? [object] : (Array(pre).dup << object)
            object.uniq!
          end

        end
        [object, objects_new]
      end

      def add_object_to_model(id, objects, current_obj, predicate)

        if @models_by_id[id].respond_to?(:klass)
          @models_by_id[id][predicate] = objects unless objects.nil? && !@models_by_id[id][predicate].nil?
        elsif !@models_by_id[id].class.handler?(predicate) &&
          !(objects.nil? && !@models_by_id[id].instance_variable_get("@#{predicate}").nil?) &&
          predicate != :id
          @lang_filter.set_model_value(@models_by_id[id], predicate, objects, current_obj)
        end
      end

      def get_preload_value(id, object, predicate)
        pre_val = nil
        if predicate_preloaded?(id, predicate)
          pre_val = preloaded_value(id, predicate)
          pre_val = pre_val.select { |x| x.respond_to?(:id) && (x.id == object) }.first if pre_val.is_a?(Array)
        end
        pre_val
      end

      def preloaded_or_new_object(object, objects_new, pre_val, predicate)
        object = pre_val || @klass.range_object(predicate, object)
        objects_new[object.id] = object
        [object, objects_new]
      end

      def preloaded_or_new_struct(object, objects_new, pre_val, predicate)
        struct = pre_val || @embed_struct[predicate].new
        struct.id = object
        struct.klass = @klass.range(predicate)
        objects_new[struct.id] = struct
        [struct, objects_new]
      end

      def preloaded_value(id, predicate)
        if !@read_only
          @models_by_id[id].instance_variable_get("@#{predicate}")

        else
          @models_by_id[id][predicate]
        end
      end

      def predicate_preloaded?(id, predicate)
        @models_by_id[id] &&
          (@models_by_id[id].respond_to?(:klass) || @models_by_id[id].loaded_attributes.include?(predicate))
      end

      def bnode_id?(object, predicate)
        object.is_a?(RDF::Node) && object.anonymous? && @incl.include?(predicate)
      end

      def bnode_id_tuple(id, object, objects_new, predicate)
        range = @klass.range(predicate)
        objects_new[object] = BNODES_TUPLES.new(id, predicate) if range.respond_to?(:new)
        objects_new
      end

      def add_bnode_to_model(sol)
        id = sol[:id]
        struct = create_struct(@bnode_extraction, @models_by_id, sol, @variables)
        @models_by_id[id].send("#{@bnode_extraction}=", struct)
      end

      def create_model(id)
        @models_by_id[id] = create_class_model(id, @klass, @klass_struct) unless @models_by_id.include?(id)
      end


      def create_struct(bnode_extraction, models_by_id, sol, variables)
        list_attributes = Set.new(@klass.attributes(:list))
        struct = @klass.range(bnode_extraction).new
        variables.each do |v|
          next if v == :id

          svalue = sol[v]
          struct[v] = svalue.is_a?(RDF::Node) ? svalue : svalue.object
        end
        if list_attributes.include?(bnode_extraction)
          pre = models_by_id[sol[:id]].instance_variable_get("@#{bnode_extraction}")
          pre = pre ? (pre.dup << struct) : [struct]
          struct = pre
        end
        struct
      end

      def create_class_model(id, klass, klass_struct)
        klass_model = klass_struct ? klass_struct.new : klass.new
        klass_model.id = id
        klass_model.persistent = true unless klass_struct
        klass_model.klass = klass if klass_struct
        klass_model
      end

      def models_unmapped_to_array(models_by_id)
        models_by_id.each do |_idm, m|
          @lang_filter.models_unmapped_to_array(m)
        end
      end


      def is_multiple_langs?
        return true if @requested_lang.is_a?(Array) || @requested_lang.eql?(:ALL)
        false
      end

      def include_bnodes(bnodes, models_by_id)
        # group by attribute
        attrs = bnodes.map { |_x, y| y.attribute }.uniq
        attrs.each do |attr|
          struct = @klass.range(attr)

          # bnodes that are in a range of goo ground models
          # for example parents and children in LD class models
          # we skip this cases for the moment
          next if struct.respond_to?(:model_name)

          bnode_attrs = struct.new.to_h.keys
          ids = bnodes.select { |_x, y| y.attribute == attr }.map { |_x, y| y.id }
          @klass.where.models(models_by_id.select { |x, _y| ids.include?(x) }.values)
                .in(@collection)
                .include(bnode: { attr => bnode_attrs }).all
        end
      end

      def include_embed_attributes(incl_embed, objects_new)
        incl_embed.each do |attr, next_attrs|
          # anything to join ?
          attr_range = @klass.range(attr)
          next if attr_range.nil?

          range_objs = objects_new.select do |_id, obj|
            obj.instance_of?(attr_range) || (obj.respond_to?(:klass) && obj[:klass] == attr_range)
          end.values
          next if range_objs.empty?

          range_objs.uniq!
          query = attr_range.where.models(range_objs).in(@collection).include(*next_attrs)
          query = query.read_only if @read_only
          query.all
        end
      end

      def models_set_all_persistent(models_by_id)
        return unless @ids

        models_by_id.each do |_k, m|
          m.persistent = true
        end
      end

      def model_set_collection_attributes(models_by_id, objects_new)
        collection_value = get_collection_value
        return unless collection_value

        collection_attribute = @klass.collection_opts
        models_by_id.each do |_id, m|
          m.send("#{collection_attribute}=", collection_value)
        end
        objects_new.each do |_id, obj_new|
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

      def get_collection_value
        collection_value = nil
        if @klass.collection_opts.instance_of?(Symbol)
          collection_value = @collection.first if @collection.is_a?(Array) && (@collection.length == 1)
          collection_value = @collection if @collection.respond_to? :id
        end
        collection_value
      end

      def object_to_array(id, klass_struct, models_by_id, object, predicate)
        pre = if klass_struct
                models_by_id[id][predicate]
              else
                models_by_id[id].instance_variable_get("@#{predicate}")
              end
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

      def dependent_model_creation(embed_struct, id, models_by_id, object, objects_new, v, options)
        read_only = options[:read_only]
        if object.is_a?(RDF::URI) && v != :id
          range_for_v = @klass.range(v)
          if range_for_v
            if objects_new.include?(object)
              object = objects_new[object]
            elsif !range_for_v.inmutable?
              pre_val = get_pre_val(id, models_by_id, object, v)
              object = get_object_from_range(pre_val, embed_struct, object, objects_new, v)
            else
              object = range_for_v.find(object).first
            end
          end
        end
        object
      end

      def get_object_from_range(pre_val, embed_struct, object, objects_new, predicate)
        range_for_v = @klass.range(predicate)
        if !@read_only
          object = pre_val || @klass.range_object(predicate, object)
          objects_new[object.id] = object
        else
          # depedent read only
          struct = pre_val || embed_struct[predicate].new
          struct.id = object
          struct.klass = range_for_v
          objects_new[struct.id] = struct
          object = struct
        end
        object
      end

      def get_pre_val(id, models_by_id, object, predicate)
        pre_val = nil
        if models_by_id[id] &&
          ((models_by_id[id].respond_to?(:klass) && models_by_id[id]) ||
            models_by_id[id].loaded_attributes.include?(predicate))
          pre_val = if !@read_only
                      models_by_id[id].instance_variable_get("@#{predicate}")
                    else
                      models_by_id[id][predicate]
                    end

          pre_val = pre_val.select { |x| x.id == object }.first if pre_val.is_a?(Array)
        end
        pre_val
      end

      def add_unmapped_to_model(sol)
        predicates = find_predicate(sol[:attributeProperty])
        predicates.each do |predicate|
          if Goo.backend_4s? || Goo.backend_gb?
            predicate = @properties_to_include[predicate][:uri]
          else
            predicate = sol[:attributeProperty]
          end
          id = sol[:id]
          value = sol[:attributeObject]
          @lang_filter.set_unmapped_value(@models_by_id[id], predicate, value)
        end
      end

      def add_aggregations_to_model(sol)
        id = sol[:id]
        @aggregate_projections&.each do |aggregate_key, aggregate_val|
          if @models_by_id[id].respond_to?(:add_aggregate)
            @models_by_id[id].add_aggregate(aggregate_val[1], aggregate_val[0], sol[aggregate_key].object)
          else
            (@models_by_id[id].aggregates ||= []) << Goo::Base::AGGREGATE_VALUE.new(aggregate_val[1],
                                                                                    aggregate_val[0],
                                                                                    sol[aggregate_key].object)
          end
        end
      end
    end
  end
end
