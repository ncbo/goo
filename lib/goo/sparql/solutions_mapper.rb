module Goo
  module SPARQL
    class SolutionMapper

      BNODES_TUPLES = Struct.new(:id, :attribute)

      def initialize(aggregate_projections, bnode_extraction, embed_struct,
                     incl_embed, klass_struct, models_by_id,
                     properties_to_include, unmapped, variables,ids, options)

        @aggregate_projections = aggregate_projections
        @bnode_extraction = bnode_extraction
        @embed_struct = embed_struct
        @incl_embed = incl_embed
        @klass_struct = klass_struct
        @models_by_id = models_by_id
        @properties_to_include = properties_to_include
        @unmapped = unmapped
        @variables = variables
        @ids = ids
        @klass = options[:klass]
        @klass = options[:klass]
        @read_only = options[:read_only]
        @incl = options[:include]
        @count = options[:count]
        @collection = options[:collection]
      end

      def map_each_solutions(select)


        found = Set.new
        objects_new = {}
        var_set_hash = {}
        list_attributes = Set.new(@klass.attributes(:list))
        all_attributes = Set.new(@klass.attributes(:all))

        
        select.each_solution do |sol|
          next if sol[:some_type] && @klass.type_uri(@collection) != sol[:some_type]
          return sol[:count_var].object if @count

          found.add(sol[:id])
          id = sol[:id]

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

          v = sol[:attributeProperty].to_s.to_sym

          next if v.nil? || !all_attributes.include?(v)

          object = sol[:attributeObject]

          #bnodes
          if bnode_id?(object, v)
            objects_new = bnode_id_tuple(id, object, objects_new, v)
            next
          end

          object, objects_new = get_value_object(id, objects_new, object, list_attributes, v)
          add_object_to_model(id, object, v, var_set_hash)
        end

        init_unloaded_attributes(found, list_attributes)

        return @models_by_id if @bnode_extraction

        model_set_collection_attributes(@models_by_id, objects_new)

        #remove from models_by_id elements that were not touched
        @models_by_id.select! { |k, m| found.include?(k) }

        models_set_all_persistent(@models_by_id) unless @read_only

        #next level of embed attributes
        include_embed_attributes(@incl_embed, objects_new) if @incl_embed && !@incl_embed.empty?

        #bnodes
        blank_nodes = objects_new.select { |id, obj| id.is_a?(RDF::Node) && id.anonymous? }
        include_bnodes(blank_nodes, @models_by_id) unless blank_nodes.empty?

        models_unmapped_to_array(@models_by_id) if @unmapped

        @models_by_id
      end

      private

      def init_unloaded_attributes(found, list_attributes)
        return if @incl.nil?

        # Here we are setting to nil all attributes that have been included but not found in the triplestore
        found.uniq.each do |model_id|
          m = @models_by_id[model_id]
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
        #binding.pry if v.eql?(:enrolled)
        #dependent model creation

        if object.is_a?(RDF::URI) && (predicate != :id) && !range_for_v.nil?
          if objects_new.include?(object)
            object = objects_new[object]
          elsif !range_for_v.inmutable?
            pre_val = get_preload_value(id, object, predicate)
            object, objects_new = if !@read_only
                                    preloaded_or_new_object(object, objects_new, pre_val, predicate)
                                  else
                                    #depedent read only
                                    preloaded_or_new_struct(object, objects_new, pre_val, predicate)
                                  end
          else
            object = range_for_v.find(object).first
          end
        end

        if list_attributes.include?(predicate)
          # To handle attr that are lists
          pre = if @klass_struct
                  @models_by_id[id][predicate]
                else
                  @models_by_id[id].instance_variable_get("@#{predicate}")
                end
          if object.nil? && pre.nil?
            object = []
          elsif object.nil? && !pre.nil?
            object = pre
          elsif object
            object = !pre ? [object] : (pre.dup << object)
            object.uniq!
          end
        end
        [object,objects_new]
      end

      def add_object_to_model(id, object, predicate, var_set_hash)
        if @models_by_id[id].respond_to?(:klass)
          @models_by_id[id][predicate] = object unless object.nil? && !@models_by_id[id][predicate].nil?
        elsif !@models_by_id[id].class.handler?(predicate) &&
          !(object.nil? && !@models_by_id[id].instance_variable_get("@#{predicate}").nil?) &&
          predicate != :id
          # if multiple language values are included for a given property, set the
          # corresponding model attribute to the English language value - NCBO-1662
          if object.is_a?(RDF::Literal)
            key = "#{predicate}#__#{id}"
            @models_by_id[id].send("#{predicate}=", object, on_load: true) unless var_set_hash[key]
            lang = object.language
            var_set_hash[key] = true if %i[EN en].include?(lang)
          else
            @models_by_id[id].send("#{predicate}=", object, on_load: true)
          end
        end
      end

      def get_preload_value(id, object, predicate)
        pre_val = nil
        if predicate_preloaded?(id, predicate)
          pre_val = preloaded_value(id, predicate)
          pre_val = pre_val.select { |x| x.id == object }.first if pre_val.is_a?(Array)
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
        if range.respond_to?(:new)
          objects_new[object] = BNODES_TUPLES.new(id, predicate)
        end
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

      def model_set_unmapped(id, predicate, value)

        if @models_by_id[id].respond_to? :klass #struct
          @models_by_id[id][:unmapped] ||= {}
          (@models_by_id[id][:unmapped][predicate] ||= []) << value
        else
          @models_by_id[id].unmapped_set(predicate, value)
        end
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
        models_by_id.each do |idm, m|
          m.unmmaped_to_array
        end
      end

      def include_bnodes(bnodes, models_by_id)
        #group by attribute
        attrs = bnodes.map { |x, y| y.attribute }.uniq
        attrs.each do |attr|
          struct = @klass.range(attr)

          #bnodes that are in a range of goo ground models
          #for example parents and children in LD class models
          #we skip this cases for the moment
          next if struct.respond_to?(:model_name)

          bnode_attrs = struct.new.to_h.keys
          ids = bnodes.select { |x, y| y.attribute == attr }.map { |x, y| y.id }
          @klass.where.models(models_by_id.select { |x, y| ids.include?(x) }.values)
               .in(@collection)
               .include(bnode: { attr => bnode_attrs }).all
        end
      end

      def include_embed_attributes(incl_embed, objects_new)
        incl_embed.each do |attr, next_attrs|
          #anything to join ?
          attr_range = @klass.range(attr)
          next if attr_range.nil?
          range_objs = objects_new.select { |id, obj|
            obj.instance_of?(attr_range) || (obj.respond_to?(:klass) && obj[:klass] == attr_range)
          }.values
          unless range_objs.empty?
            range_objs.uniq!
            attr_range.where().models(range_objs).in(@collection).include(*next_attrs).all
          end
        end
      end

      def models_set_all_persistent(models_by_id)
        return unless @ids
        models_by_id.each do |k, m|
          m.persistent = true
        end
      end

      def model_set_collection_attributes(models_by_id, objects_new)
        collection_value = get_collection_value
        if collection_value
          collection_attribute = @klass.collection_opts
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

      def get_collection_value
        collection_value = nil
        if @klass.collection_opts.instance_of?(Symbol)
          if @collection.is_a?(Array) && (@collection.length == 1)
            collection_value = @collection.first
          end
          if @collection.respond_to? :id
            collection_value = @collection
          end
        end
        collection_value
      end

      def model_map_attributes_values(id, var_set_hash, models_by_id, object, sol, v)
        if models_by_id[id].respond_to?(:klass)
          models_by_id[id][v] = object if models_by_id[id][v].nil?
        else
          model_attribute_val = models_by_id[id].instance_variable_get("@#{v.to_s}")
          if (!models_by_id[id].class.handler?(v) || model_attribute_val.nil?) && v != :id
            # if multiple language values are included for a given property, set the
            # corresponding model attribute to the English language value - NCBO-1662
            if sol[v].is_a?(RDF::Literal)
              key = "#{v}#__#{id.to_s}"
              models_by_id[id].send("#{v}=", object, on_load: true) unless var_set_hash[key]
              lang = sol[v].language
              var_set_hash[key] = true if %i[EN en EN en EN en].include?(lang)
            else
              models_by_id[id].send("#{v}=", object, on_load: true)
            end
          end
        end
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
              pre_val = get_pre_val(id, models_by_id, object, v, read_only)
              object = get_object_from_range(pre_val, embed_struct, object, objects_new, v, options)
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
          #depedent read only
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
        predicate = sol[:attributeProperty].to_s.to_sym
        return unless @properties_to_include[predicate]

        id = sol[:id]
        value = sol[:attributeObject]

        model_set_unmapped(id, @properties_to_include[predicate][:uri], value)
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

