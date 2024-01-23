require 'active_support/core_ext/string'

module Goo
  module Base
    module Settings
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_accessor :model_settings
        attr_reader :model_name
        attr_reader :attribute_uris

        def default_model_options
          return {}
        end

        def model(*args)

          if args.length == 0
            raise ArgumentError, "model should have args"
          end

          model_name = args[0]
          @model_name = model_name.to_sym

          #a hash with options is expected
          options = args.last
          @inmutable = (args.include? :inmutable)
          if @inmutable
            @inm_instances = nil
          end

          @model_settings = default_model_options.merge(options || {})

          unless options.include?:name_with
            raise ArgumentError, "The model `#{model_name}` definition should include the :name_with option"
          end
          Goo.add_model(@model_name,self)
          @attribute_uris = {}
          @namespace = Goo.vocabulary(@model_settings[:namespace])
          @uri_type = @namespace[@model_name.to_s.camelize]
          @model_settings[:range] = {}
          @model_settings[:attributes] = {}
          @model_settings[:rdf_type] = options[:rdf_type]

          #registering a new models forces to redo ranges
          Goo.models.each do |k,m|
            m.attributes(:all).each do |attr|
              next if m.range(attr)
              m.set_range(attr)
            end
          end
        end

        def attributes(*options)
          if options and options.length > 0
            filt = options.first
            if filt == :all
              return @model_settings[:attributes].keys
            end
            if filt == :inverse
              return @model_settings[:attributes].keys.
                select{ |k| @model_settings[:attributes][k][:inverse] }
            end
            atts = (@model_settings[:attributes].
                    select{ |attr,opts| opts[:enforce].include?(filt) }).keys()
            atts.concat(attributes(:inverse)) if filt == :list
            return atts
          end
          return @model_settings[:attributes].keys.
            select{ |k| @model_settings[:attributes][k][:inverse].nil? }.
            select{ |k| !handler?(k) }
        end

        def inmutable?
          return @inmutable
        end

        def collection?(attr)
          return @model_settings[:collection] == attr
        end

        def collection_opts
          return @model_settings[:collection]
        end

        def attributes_with_defaults
          return (@model_settings[:attributes].
                  select{ |attr,opts| opts[:default] }).keys()
        end

        def default(attr)
          return @model_settings[:attributes][attr][:default]
        end

        def attribute_namespace(attr)
          return @model_settings[:attributes][attr][:namespace]
        end

        def range(attr)
          @model_settings[:range][attr]
        end

        def attribute_settings(attr)
          @model_settings[:attributes][attr]
        end

        def cardinality(attr)
          return nil if @model_settings[:attributes][attr].nil?
          cardinality = {}
          enforce = @model_settings[:attributes][attr][:enforce]
          min = enforce.map {|e| e.to_s.split("_").last.to_i if e.to_s.start_with?("min_") }.compact
          max = enforce.map {|e| e.to_s.split("_").last.to_i if e.to_s.start_with?("max_") }.compact
          cardinality[:min] = min.first unless min.empty?
          cardinality[:max] = max.first unless max.empty?
          cardinality.empty? ? nil : cardinality
        end

        def required?(attr)
          return false if @model_settings[:attributes][attr].nil?
          @model_settings[:attributes][attr][:enforce].include?(:existence)
        end

        def unique?(attr)
          return false if @model_settings[:attributes][attr].nil?
          @model_settings[:attributes][attr][:enforce].include?(:unique)
        end

        def list?(attr)
          return false if @model_settings[:attributes][attr].nil?
          @model_settings[:attributes][attr][:enforce].include?(:list)
        end

        def transitive?(attr)
          return false if !@model_settings[:attributes].include?(attr)
          return (@model_settings[:attributes][attr][:transitive] == true)
        end

        def alias?(attr)
          return false if !@model_settings[:attributes].include?(attr)
          return (@model_settings[:attributes][attr][:alias] == true)
        end

        def handler?(attr)
          return false if @model_settings[:attributes][attr].nil?
          return (!@model_settings[:attributes][attr][:handler].nil?)
        end

        def handler(attr)
          return false if @model_settings[:attributes][attr].nil?
          return @model_settings[:attributes][attr][:handler]
        end

        def inverse?(attr)
          return false if @model_settings[:attributes][attr].nil?
          return (!@model_settings[:attributes][attr][:inverse].nil?)
        end

        def inverse_opts(attr)
          return @model_settings[:attributes][attr][:inverse]
        end

        def set_range(attr)
          @model_settings[:attributes][attr][:enforce].each do |opt|
            if Goo.models.include?(opt) || opt.respond_to?(:model_name) || (opt.respond_to?(:new) && opt.new.kind_of?(Struct))
              opt = Goo.models[opt] if opt.instance_of?(Symbol)
              @model_settings[:range][attr]=opt
              break
            end
          end
          if @model_settings[:attributes][attr][:inverse]
            on = @model_settings[:attributes][attr][:inverse][:on]
            if Goo.models.include?(on) || on.respond_to?(:model_name)
              on = Goo.models[on] if on.instance_of?(Symbol)
              @model_settings[:range][attr]=on
            end
          end
        end

        def attribute(*args)
          options = args.reverse
          attr_name = options.pop
          attr_name = attr_name.to_sym
          options = options.pop
          options = {} if options.nil?

          options[:enforce] ||= []

          set_data_type(options)
          set_no_list_by_default(options)

          @model_settings[:attributes][attr_name] = options
          shape_attribute(attr_name)
          namespace = attribute_namespace(attr_name)
          namespace = namespace || @model_settings[:namespace]
          vocab = Goo.vocabulary(namespace) #returns default for nil input
          if options[:property].is_a?(Proc)
            @attribute_uris[attr_name] = options[:property]
          else
            @attribute_uris[attr_name] = vocab[options[:property] || attr_name]
          end
          if options[:enforce].include?(:unique) and options[:enforce].include?(:list)
            raise ArgumentError, ":list options cannot be combined with :list"
          end
          set_range(attr_name)
        end

        def attribute_uri(attr,*args)
          if attr == :id
            raise ArgumentError, ":id cannot be treated as predicate for .where, use find "
          end
          uri = @attribute_uris[attr]
          if uri.is_a?(Proc)
            uri = uri.call(*args.flatten)
          end
          return uri unless uri.nil?
          attr_string = attr.to_s
          Goo.namespaces.keys.each do |ns|
            nss = ns.to_s
            if attr_string.start_with?(nss)
              return Goo.vocabulary(ns)[attr_string[nss.length+1..-1]]
            end
          end
          #default
          return Goo.vocabulary(nil)[attr]
        end

        def shape_attribute(attr)
          return if attr == :resource_id
          attr = attr.to_sym
          define_method("#{attr}=") do |*args|
            if self.class.handler?(attr)
              raise ArgumentError, "Method based attributes cannot be set"
            end
            if self.class.inverse?(attr) && !(args && args.last.instance_of?(Hash) && args.last[:on_load])
              raise ArgumentError,
                "`#{attr}` is an inverse attribute. Values cannot be assigned."
            end
            @loaded_attributes.add(attr)
            value = args[0]
            unless args.last.instance_of?(Hash) and args.last[:on_load]
              if self.persistent? and self.class.name_with == attr
                raise ArgumentError, 
                    "`#{attr}` attribute is used to name this resource and cannot be modified."
              end
              prev = self.instance_variable_get("@#{attr}")
              if !prev.nil? and !@modified_attributes.include?(attr)
                if prev != value
                  @previous_values = @previous_values || {}
                  @previous_values[attr] = prev
                end
              end
              @modified_attributes.add(attr)
            end
            if value.instance_of?(Array)
              value = value.dup.freeze
            end
            self.instance_variable_set("@#{attr}",value)
          end
          define_method("#{attr}") do |*args|
            if self.class.handler?(attr)
              if @loaded_attributes.include?(attr)
                return self.instance_variable_get("@#{attr}")
              end
              value = self.send("#{self.class.handler(attr)}")
              self.instance_variable_set("@#{attr}",value)
              @loaded_attributes << attr
              return value
            end
            if (not @persistent) or @loaded_attributes.include?(attr)
              return self.instance_variable_get("@#{attr}")
            else
              raise Goo::Base::AttributeNotLoaded, "Attribute `#{attr}` is not loaded for #{self.id}. Loaded attributes: #{@loaded_attributes.inspect}."
            end
          end
        end

        def uuid_uri_generator(inst)
          model_name_uri = model_name.to_s
          model_name_uri = model_name_uri.pluralize if Goo.pluralize_models?
          if Goo.id_prefix
            return RDF::URI.new(Goo.id_prefix + model_name_uri + '/' + Goo.uuid)
          end
          return namespace[ model_name_uri + '/' + Goo.uuid]
        end

        def uri_type(*args)
          if @model_settings[:rdf_type]
            return @model_settings[:rdf_type].call(*args)
          end
          return @uri_type
        end
        alias :type_uri :uri_type
        def namespace
          return @namespace
        end

        def id_prefix
          model_name_uri = model_name.to_s
          model_name_uri = model_name_uri.pluralize if Goo.pluralize_models?
          if Goo.id_prefix
            return RDF::URI.new(Goo.id_prefix + model_name_uri + '/')
          end
          return namespace[model_name_uri + '/']
        end

        def id_from_unique_attribute(attr,value_attr)
          if value_attr.nil?
            raise Goo::Base::IDGenerationError, "`#{attr}` value is nil. Id for resource cannot be generated."
          end
          uri_last_fragment = CGI.escape(value_attr)
          model_prefix_uri = id_prefix()
          return model_prefix_uri + uri_last_fragment
        end

        def enum(*values)
          include Goo::Base::Enum
          (@model_settings[:enum] = {})[:initialize] = false
          @model_settings[:enum][:values] = values.first
          @model_settings[:enum][:lock] = Mutex.new
        end

        def name_with
          return @model_settings[:name_with]
        end

        def load_inmutable_instances
          #TODO this should be SYNC
          @inm_instances = nil
          ins = self.where.include(self.attributes).all
          @inm_instances = {}
          ins.each do |ins|
            @inm_instances[ins.id] = ins
          end
        end

        def attribute_loaded?(attr)
          return @loaded_attributes.include?(attr)
        end

        def inm_instances
          @inm_instances
        end

        def struct_object(attrs)
          attrs = attrs.dup
          attrs << :id unless attrs.include?(:id)
          attrs << :klass
          attrs << :aggregates
          attrs << :unmapped
          attrs << collection_opts if collection_opts
          attrs.uniq!
          return Struct.new(*attrs)
        end

        STRUCT_CACHE = {}
        ##
        # Return a struct-based, 
        # read-only instance for a class that is populated with the contents of `attributes`
        def read_only(attributes)
          if !attributes.is_a?(Hash) || attributes.empty?
            raise ArgumentError, "`attributes` must be a hash of attribute/value pairs"
          end
          unless attributes.key?(:id)
            raise ArgumentError, "`attributes` must contain a key for `id`"
          end
          attributes = attributes.symbolize_keys
          STRUCT_CACHE[attributes.keys.hash] ||= struct_object(attributes.keys)
          cls = STRUCT_CACHE[attributes.keys.hash]
          instance = cls.new
          instance.klass = self
          attributes.each {|k,v| instance[k] = v}
          instance
        end

        private

        def set_no_list_by_default(options)
          if options[:enforce].nil? or !options[:enforce].include?(:list)
            options[:enforce] = options[:enforce] ? (options[:enforce] << :no_list) : [:no_list]
          end
        end
        def set_data_type(options)
          if options[:type]
            options[:enforce] += Array(options[:type])
            options[:enforce].uniq!
            options.delete :type
          end
        end
      end
    end
  end
end
