module Goo
  module SPARQL
    class SolutionMapper

      BNODES_TUPLES = Struct.new(:id, :attribute)

      def initialize(aggregate_projections, bnode_extraction, embed_struct,
                     incl_embed, klass_struct, models_by_id,
                     predicates_map, unmapped, variables, incl, options)

        @aggregate_projections = aggregate_projections
        @bnode_extraction = bnode_extraction
        @embed_struct = embed_struct
        @incl_embed = incl_embed
        @klass_struct = klass_struct
        @models_by_id = models_by_id
        @predicates_map = predicates_map
        @unmapped = unmapped
        @variables = variables
        @incl = incl
        @options = options


      end

      def map_each_solutions(select)

        count = @options[:count]
        klass = @options[:klass]
        read_only = @options[:read_only]
        collection = @options[:collection]


        found = Set.new
        objects_new = {}
        list_attributes = Set.new(klass.attributes(:list))
        all_attributes = Set.new(klass.attributes(:all))
        @lang_filter = Goo::SPARQL::Solution::LanguageFilter.new

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
          next if sol[:some_type] && klass.type_uri(collection) != sol[:some_type]

          return sol[:count_var].object if count

          found.add(sol[:id])
          id = sol[:id]

          # for troubleshooting specific queries (write 2 of 3)
          # File.write(debug_file, id + "\n", mode: 'a') if select.to_s =~ /OFFSET \d+ LIMIT 2500$/

          if @bnode_extraction
            struct = create_struct(@bnode_extraction, klass, @models_by_id, sol, @variables)
            @models_by_id[id].send("#{@bnode_extraction}=", struct)
            next
          end

          @models_by_id[id] = create_class_model(id, klass, @klass_struct) unless @models_by_id.include?(id)

          if @unmapped
            if @predicates_map.nil?
              model_set_unmapped(@models_by_id, sol)
            else
              model_set_unmapped_with_predicates_map(@models_by_id, @predicates_map, sol)
            end
            next
          end

          @variables.each do |v|
            next if (v == :id) && @models_by_id.include?(id)
            if (v != :id) && !all_attributes.include?(v)
              model_add_aggregation(@aggregate_projections, @models_by_id, sol, v)
              #TODO otther schemaless things
              next
            end
            #group for multiple values
            object = sol[v] || nil

            #bnodes
            if object.kind_of?(RDF::Node) && object.anonymous? && @incl.include?(v)
              initialize_object(id, klass, object, objects_new, v)
              next
            end

            object = object.object if object && !(object.kind_of? RDF::URI)

            #dependent model creation
            object = dependent_model_creation(@embed_struct, id, @models_by_id, object, objects_new, v, @options)

            object = object_to_array(id, @klass_struct, @models_by_id, object, v) if list_attributes.include?(v)

            model_map_attributes_values(id, var_set_hash, @models_by_id, object, sol, v)
          end
        end
        @lang_filter.fill_models_with_other_languages(@models_by_id, list_attributes)

        # for troubleshooting specific queries (write 3 of 3)
        # File.write(debug_file, "\n\n", mode: 'a') if select.to_s =~ /OFFSET \d+ LIMIT 2500$/

        return @models_by_id if @bnode_extraction

        model_set_collection_attributes(collection, klass, @models_by_id, objects_new)

        #remove from models_by_id elements that were not touched
        @models_by_id.select! { |k, m| found.include?(k) }

        models_set_all_persistent(@models_by_id, @options) unless read_only

        #next level of embed attributes
        include_embed_attributes(collection, @incl_embed, klass, objects_new) if @incl_embed && !@incl_embed.empty?


        #bnodes
        bnodes = objects_new.select { |id, obj| id.is_a?(RDF::Node) && id.anonymous? }
        include_bnodes(bnodes, collection, klass, @models_by_id) unless bnodes.empty?

        models_unmapped_to_array(@models_by_id) if @unmapped

        @models_by_id
      end

      private

      def model_set_unmapped(models_by_id, sol)
        id = sol[:id]
        if models_by_id[id].respond_to? :klass #struct
          models_by_id[id][:unmapped] ||= {}
          (models_by_id[id][:unmapped][sol[:predicate]] ||= []) << sol[:object]
        else
          models_by_id[id].unmapped_set(sol[:predicate], sol[:object])
        end
      end

      def create_struct(bnode_extraction, klass, models_by_id, sol, variables)
        list_attributes = Set.new(klass.attributes(:list))
        struct = klass.range(bnode_extraction).new
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

      def include_bnodes(bnodes, collection, klass, models_by_id)
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

      def include_embed_attributes(collection, incl_embed, klass, objects_new)
        incl_embed.each do |attr, next_attrs|
          #anything to join ?
          attr_range = klass.range(attr)
          next if attr_range.nil?
          range_objs = objects_new.select { |id, obj|
            obj.instance_of?(attr_range) || (obj.respond_to?(:klass) && obj[:klass] == attr_range)
          }.values
          unless range_objs.empty?
            range_objs.uniq!
            attr_range.where.models(range_objs).in(collection).include(*next_attrs).all
          end
        end
      end

      def models_set_all_persistent(models_by_id, options)
        if options[:ids] #newly loaded
          models_by_id.each do |k, m|
            m.persistent = true
          end
        end
      end

      def model_set_collection_attributes(collection, klass, models_by_id, objects_new)
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

      def get_collection_value(collection, klass)
        collection_value = nil
        if klass.collection_opts.instance_of?(Symbol)
          collection_value = collection.first if collection.is_a?(Array) && (collection.length == 1)
          collection_value = collection if collection.respond_to? :id
        end
        collection_value
      end

      def model_map_attributes_values(id, object, sol, v)
        #binding.pry if v.eql? :programs
        if @models_by_id[id].respond_to?(:klass)
          @models_by_id[id][v] = object if @models_by_id[id][v].nil?
        else
          model_attribute_val = @models_by_id[id].instance_variable_get("@#{v.to_s}")
          if (!@models_by_id[id].class.handler?(v) || model_attribute_val.nil?) && v != :id
            # if multiple language values are included for a given property, set the
            # corresponding model attribute to the English language value - NCBO-1662
            if sol[v].kind_of?(RDF::Literal)
              index, value = @lang_filter.main_lang_filter id, v, object, sol[v]
              @models_by_id[id].send("#{v}=", value, on_load: true) if index.eql? :no_lang
            elsif model_attribute_val.nil? || !object.nil?
              @models_by_id[id].send("#{v}=", object, on_load: true)
            end
          end
        end
      end


      def object_to_array(id, klass_struct, models_by_id, object, v)
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

      def dependent_model_creation(embed_struct, id, models_by_id, object, objects_new, v, options)
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

      def get_object_from_range(pre_val, embed_struct, object, objects_new, v, options)
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

      def get_pre_val(id, models_by_id, object, v, read_only)
        pre_val = nil
        if models_by_id[id] &&
          ((models_by_id[id].respond_to?(:klass) && models_by_id[id]) ||
            models_by_id[id].loaded_attributes.include?(v))
          pre_val = if !read_only
            models_by_id[id].instance_variable_get("@#{v}")
          else
            models_by_id[id][v]
                    end

          pre_val = pre_val.select { |x| x.id == object }.first if pre_val.is_a?(Array)
        end
        pre_val
      end

      def initialize_object(id, klass, object, objects_new, v)
        range = klass.range(v)
        objects_new[object] = BNODES_TUPLES.new(id, v) if range.respond_to?(:new)
      end

      def model_add_aggregation(aggregate_projections, models_by_id, sol, v)
        id = sol[:id]
        if aggregate_projections && aggregate_projections.include?(v)
          conf = aggregate_projections[v]
          if models_by_id[id].respond_to?(:add_aggregate)
            models_by_id[id].add_aggregate(conf[1], conf[0], sol[v].object)
          else
            (models_by_id[id].aggregates ||= []) <<
              Goo::Base::AGGREGATE_VALUE.new(conf[1], conf[0], sol[v].object)
          end
        end
      end

      def model_set_unmapped_with_predicates_map(models_by_id, predicates_map, sol)
        id = sol[:id]
        no_graphs = sol[:bind_as].to_s.to_sym
        if predicates_map.include?(no_graphs)
          pred = predicates_map[no_graphs]
          if models_by_id[id].respond_to? :klass #struct
            models_by_id[id][:unmapped] ||= {}
            (models_by_id[id][:unmapped][pred] ||= Set.new) << sol[:object]
          else
            models_by_id[id].unmapped_set(pred, sol[:object])
          end
        end
      end
    end
  end
end
