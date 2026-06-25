require 'active_support/core_ext/string'
require 'active_support/core_ext/object/blank' # blank?/present? — no longer pulled in transitively by core_ext/string in activesupport 8
require_relative 'yaml_settings'
require_relative 'hooks'
require_relative 'attribute'

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
        attr_reader :namespace

        include YAMLScheme ,AttributeSettings, Hooks

        def default_model_options
          {name_with: lambda {|x| uuid_uri_generator(x)}}
        end

        def model(*args)

          if args.length == 0
            raise ArgumentError, "model should have args"
          end

          model_name = args[0]
          @model_name = model_name.to_sym

          # a hash with options is expected
          options = args.last

          @model_settings = default_model_options.merge(options || {})

          init_yaml_scheme_settings

          unless options.include? :name_with
            raise ArgumentError, "The model `#{model_name}` definition should include the :name_with option"
          end

          Goo.add_model(@model_name, self)
          @attribute_uris = {}
          @namespace = Goo.vocabulary(@model_settings[:namespace])
          @uri_type = @namespace[@model_name.to_s.camelize]
          @model_settings[:range] = {}
          @model_settings[:attributes] = {}
          @model_settings[:rdf_type] = options[:rdf_type]

          # registering a new models forces to redo ranges
          Goo.models.each do |k, m|
            m.attributes(:all).each do |attr|
              next if m.range(attr)
              m.set_range(attr)
            end
          end
        end

        def set_range(attr)
          attribute_settings(attr)[:enforce].each do |opt|
            if Goo.models.include?(opt) || opt.respond_to?(:model_name) || (opt.respond_to?(:new) && opt.new.kind_of?(Struct))
              opt = Goo.models[opt] if opt.instance_of?(Symbol)
              @model_settings[:range][attr] = opt
              break
            end
          end
          if attribute_settings(attr)[:inverse]
            on = attribute_settings(attr)[:inverse][:on]
            if Goo.models.include?(on) || on.respond_to?(:model_name)
              on = Goo.models[on] if on.instance_of?(Symbol)
              @model_settings[:range][attr] = on
            end
          end
        end

        def collection?(attr)
          @model_settings[:collection] == attr
        end

        def collection_opts
          @model_settings[:collection]
        end

        def uuid_uri_generator(inst)
          model_name_uri = model_name.to_s
          model_name_uri = model_name_uri.pluralize if Goo.pluralize_models?
          if Goo.id_prefix
            return RDF::URI.new(Goo.id_prefix + model_name_uri + '/' + Goo.uuid)
          end
          namespace[model_name_uri + '/' + Goo.uuid]
        end

        def uri_type(*args)
          @model_settings[:rdf_type] ? @model_settings[:rdf_type].call(*args) : @uri_type
        end

        alias :type_uri :uri_type

        def id_prefix
          model_name_uri = model_name.to_s
          model_name_uri = model_name_uri.pluralize if Goo.pluralize_models?
          if Goo.id_prefix
            return RDF::URI.new(Goo.id_prefix + model_name_uri + '/')
          end
          namespace[model_name_uri + '/']
        end

        def id_from_unique_attribute(attr, value_attr)
          if value_attr.nil?
            raise Goo::Base::IDGenerationError, "`#{attr}` value is nil. Id for resource cannot be generated."
          end
          uri_last_fragment = CGI.escape(value_attr)
          id_prefix + uri_last_fragment
        end

        def enum(*values)
          include Goo::Base::Enum
          (@model_settings[:enum] = {})[:initialize] = false
          @model_settings[:enum][:values] = values.first
          @model_settings[:enum][:lock] = Mutex.new
        end

        def name_with
          @model_settings[:name_with]
        end

        def attribute_loaded?(attr)
          @loaded_attributes.include?(attr)
        end

        def struct_object(attrs)
          attrs = attrs.dup
          attrs << :id unless attrs.include?(:id)
          attrs << :klass
          attrs << :aggregates
          attrs << :unmapped
          attrs << collection_opts if collection_opts
          attrs.uniq!
          Struct.new(*attrs)
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
          attributes.each { |k, v| instance[k] = v }
          instance
        end

        def show_all_languages?(args)
          args.first.is_a?(Hash) && args.first.keys.include?(:include_languages) && args.first[:include_languages]
        end

        def not_show_all_languages?(values, args)
          values.is_a?(Hash) && !show_all_languages?(args)
        end
        
      end
    end
  end
end
