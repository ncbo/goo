
module Goo
  module Base
    module Settings

      @@_cardinality_shortcuts = {
        :single_value => { :max => 1 },
        :optional => { :min => 0 },
        :not_nil => { :min => 1 },
        :unique => { :min => 1, :max => 1 }
      }

      def self.included(base)
        base.extend(ClassMethods)
      end

      def self.is_validator(opt_name)
        return (Goo.validators.include? opt_name.to_sym or @@_cardinality_shortcuts.include? opt_name)
      end

      def self.set_attribute_model(model_class,att_name)
        model_class.goop_settings[:attributes][att_name.to_sym] = {}
        model_class.goop_settings[:attributes][att_name.to_sym][:validators] = {}
      end

      def self.set_namespace_options(model_class, att_name, options)
        ns = nil
        if options.kind_of? Hash
          ns = options[:with]
        else
          ns = options
        end
        ns = ns.to_sym
        if not Goo.namespaces.include? ns
          raise ArgumentError, "Namespace #{ns} is not registered in Goo"
        end

        model_class.goop_settings[:attributes][att_name.to_sym][:namespace] = ns
      end

      def self.set_unique_options(model_class, att_name, options)
        generator = nil
        if options.kind_of? Hash
          generator = options[:generator]
        else
          generator = Goo::Naming.default_graph_id_generator
        end
        model_class.goop_settings[:unique][:fields] = att_name
        model_class.goop_settings[:unique][:generator] = generator
      end

      def self.set_validator_options(model_class, att_name,val_name, options)
        val_name = val_name.to_sym
        att =  model_class.goop_settings[:attributes][att_name.to_sym]
        if not att[:validators].include? val_name
          att[:validators][val_name] = {}
        end
        if options.kind_of? Hash
          att[:validators][val_name].merge!(options)
        else
          att[:validators][val_name].merge!({ :with => options })
        end
      end

      def self.set_default_options(model_class, att_name, options)
        att =  model_class.goop_settings[:attributes][att_name.to_sym]
        att[:default] = options
      end

      def self.set_inverse_options(model_class, att_name, options)
        att =  model_class.goop_settings[:attributes][att_name.to_sym]
        att[:inverse_of] = options
      end

      def self.cardinality_shortcuts
        @@_cardinality_shortcuts
      end

      module ClassMethods
        attr_accessor :goop_settings

        def attribute_validators(attr)
          if self.goop_settings[:attributes].include? attr.to_sym
            return self.goop_settings[:attributes][attr][:validators].clone
          end
          return {}
        end

        def search_options(*args)
          self.goop_settings[:search_options] = args.first
        end

        def attributes(*args)
          return self.goop_settings[:attributes].clone
        end

        def type_uri
          goop_settings[:model_prefix_camelize] ||= prefix + goop_settings[:model].to_s.camelize
          return goop_settings[:model_prefix_camelize]
        end

        def collection_attribute? attr
          return false if goop_settings[:collection].nil?
          return goop_settings[:collection][:attribute] == attr
        end

        def collection(instance,attributes=nil)
          return nil if goop_settings[:collection].nil?
          raise ArgumentError "Collection needs instance or attributes" if instance.nil? and attributes.nil?

          id = nil
          opts = goop_settings[:collection]
          attr_name = opts[:attribute]
          if instance
            attr_value = instance.internals.collection
            id = opts[:with].call(attr_value)
          end
          if id.nil? and attributes.include? attr_name
            attr_value = attributes[attr_name]
            unless attr_value.kind_of? Resource
              raise ArgumentError, "Search on attribute `#{attr_name}` must use a Resource as value"
            end
            id = opts[:with].call(attr_value)
          end
          if id
            return id.value if id.kind_of? SparqlRd::Resultset::IRI
            return id
          end
          raise ArgumentError, "Unable to compute collection ID"
        end

        def attr_for_predicate_uri(uri)
          return :rdf_type if RDF.rdf_type? uri
          prefix = Goo.find_prefix_for_uri(uri)
          return nil unless prefix
          fragment = uri[(namespace prefix).length .. -1]
          #return fragment.underscore.to_sym
          return fragment.to_sym
        end

        def uri_for_predicate(att)
          if att == :uuid
            return (namespace :default) + "uuid"
          end
          att_fragment = att
          if goop_settings[:attributes][att]
            att_fragment = goop_settings[:attributes][att][:alias] || att
          end
          att_fragment = att_fragment.to_s
          if not goop_settings[:attributes].include? att
            return prefix + att_fragment.to_s
          end
          if not goop_settings[:attributes][att].include? :namespace
            return prefix + att_fragment.to_s
          end
          return namespace( goop_settings[:attributes][att][:namespace] ) + att_fragment.to_s
        end

        def namespace(symb)
          pref = Goo.namespaces[symb]
          if pref.nil?
            raise ArgumentError, "Namespace `#{symb}` not configured in Goo. " +
              "Check registered namespaces"
          end
          if pref.kind_of? Symbol
            return Goo.namespaces[pref]
          end
          return pref
        end

        def prefix
          ns = self.goop_settings[:namespace]
          return namespace ns
        end

        def goo_name
          @goop_settings[:model_underscore] ||= @goop_settings[:model].to_s.underscore.to_sym
          return @goop_settings[:model_underscore]
        end

        def model(*args)
          options = args.reverse
          if options.length == 0 or (not options[-1].kind_of? Symbol)
            type = (self.name.split "::")[-1].underscore.to_sym
          else
            type = options.pop
          end
          if instance_variables.index(:@goop_settings) == nil
            @goop_settings = {}
          end
          Goo.models << self
          @goop_settings[:model] = type
          @goop_settings[:schemaless] = false
          @goop_settings[:attributes] = {}
          @goop_settings[:graph_policy] =
            @goop_settings[:graph_policy] || :type_id_graph_policy
          @goop_settings[:unique] = { :generator => :anonymous }
          @goop_settings[:namespace] = :default
          options.each do |opt|
            @goop_settings.merge!(opt)
          end
        end

        def attribute(*args)
          options = args.reverse
          attr_name = options.pop
          Settings.set_attribute_model(self,attr_name)
          if attr_name == :resource_id
            Settings.set_validator_options(self,attr_name,:unique,{})
          end
          if attr_name == :resource_id
              goop_settings[:unique][:generator] = :resource_id
              goop_settings[:unique][:fields] = []
          end
          options.each do |opt|
            if opt.kind_of? Hash
              opt.each do |opt_name,sub_options|
                if opt_name == :default
                    Settings.set_default_options(self,attr_name,sub_options)
                end
                if opt_name == :inverse_of
                  Settings.set_inverse_options(self,attr_name,sub_options)
                end
                if sub_options == false# things like :not_nil => false
                  next
                end
                if Settings.is_validator(opt_name)
                  if Settings.cardinality_shortcuts.include? opt_name
                    Settings.set_validator_options(self,attr_name,:cardinality,
                                                   Settings.cardinality_shortcuts[opt_name])
                    if opt_name == :unique
                      if goop_settings[:unique][:generator] == :anonymous
                        goop_settings[:unique][:generator] = :concat_and_encode
                        goop_settings[:unique][:fields] = []
                      end
                      goop_settings[:unique][:fields] << attr_name
                      Settings.set_validator_options(self,attr_name,:unique,sub_options)
                    end
                  else
                    Settings.set_validator_options(self,attr_name,opt_name,sub_options)
                  end
                elsif opt_name == :namespace
                  Settings.set_namespace_options(self,attr_name,sub_options)
                elsif opt_name == :collection
                  unless self.goop_settings[:collection].nil?
                    raise ArgumentError, "A Goo model only can contain one collection attribute"
                  end
                  self.goop_settings[:collection] = { attribute: attr_name, with: sub_options }
                elsif opt_name == :alias
                  self.goop_settings[:alias_table] = {} if self.goop_settings[:alias_table].nil?
                  next if opt.include? :inverse_of
                  if self.goop_settings[:alias_table].include? sub_options
                    raise ArgumentError, "Configuration error. More than one :alias with name `#{sub_options}`"
                  end
                  self.goop_settings[:alias_table][sub_options] = attr_name
                  goop_settings[:attributes][attr_name][opt_name]=sub_options
                else
                  goop_settings[:attributes][attr_name][opt_name]=sub_options
                end
              end
            end
          end
          check_rdftype_inconsistency(attr_name)
          shape_attribute(attr_name)
        end


        def shape_attribute(attr)
          return if attr == :resource_id
          attr = attr.to_sym

          define_method("#{attr}=") do |*args|


            in_load = false
            if args[-1].kind_of? Hash
              in_load = args[-1].include? :in_load
              args = args[0,args.length-1]
            end
            if self.class.goop_settings[:collection] and\
               self.class.goop_settings[:collection][:attribute] == attr
              if args.length > 1
                raise ArgumentError, "#{attr} is a collection value and must have a single value"
              end
              value = args[0]
              self.internals.collection = value
              return self.instance_variable_set("@#{attr}",value)
            end
            if !in_load and internals.lazy_loaded? and !(internals.loaded_attrs.include? attr.to_sym)
              raise NotLoadedResourceError,
                "Object has been lazy loaded. Call `load` to access/write attributes"
            end
            if self.class.inverse_attr?(attr)
              raise ArgumentError, "#{attr} is defined as inverse property and cannot be set."
            end
            current_value = @attributes[attr]
            value = args.flatten
            if value and !value.instance_of? SparqlRd::Resultset::Literal
              if !value.respond_to? :goop_settings
                value.map! do |v|
                  next if v.kind_of? Hash and v.include? :in_load
                  if v.nil?
                    nil
                  else
                    if v.kind_of? Resource
                      v
                    else
                      SparqlRd::Resultset.get_literal_from_object(v)
                    end
                  end
                end
              end
            end

            validators = self.class.attribute_validators(attr)
            cardinality_opt = validators[:cardinality]
            card_validator = nil
            if cardinality_opt
              card_validator = Goo::Validators::CardinalityValidator.new(cardinality_opt)
            end

            prx = AttributeValueProxy.new(card_validator,
                                          @attributes[:internals])
            tvalue = prx.call({ :value => value, :attr => attr,
                                :current_value => current_value })
            if attr == :uuid
              #uuid forced to be unique
              tvalue = tvalue[0]
            end

            if internals.persistent?
              if not internals.lazy_loaded? and
                 not in_load and
                 self.class.goop_settings[:unique] and
                 self.class.goop_settings[:unique][:fields] and
                 self.class.goop_settings[:unique][:fields].include? attr
                 unless value[0] == self.send("#{attr}")
                   raise KeyFieldUpdateError,
                     "Attribute '#{attr}' cannot be changed in a persisted object."
                 end
              end
            end
            if !in_load
              if attr != :uuid and @attributes[attr]
                internals.modified = internals.modified || (@attributes[attr] != tvalue)
              elsif attr != :uuid
                internals.modified = true
              end
            end
            if attr == :uuid
              self.uuid = tvalue
            else
              @attributes[attr] = tvalue
            end
          end

          define_method("#{attr}") do |*args|
            as_instance_val = self.instance_variable_get("@#{attr}")
            return as_instance_val unless as_instance_val.nil?

            attr_cpy = attr
            if self.class.goop_settings[:collection] and\
               self.class.goop_settings[:collection][:attribute] == attr_cpy
              return self.internals.collection
            end

            return aggregate(attr) if self.class.aggregate? attr

            origin_attr = attr_cpy
            use_as_attr = self.class.use_as attr_cpy
            attr_cpy = use_as_attr unless use_as_attr.nil?

            if (not self.class.inverse_attr? attr_cpy) and
              internals.lazy_loaded? and (!internals.loaded_attrs.include?(attr_cpy.to_sym) or use_as_attr)
              return load_on_demand([attr_cpy], use_as_attr.nil? ? nil : [origin_attr])
            end

            return inverse_attr_values(attr_cpy,origin_attr) if self.class.inverse_attr? attr_cpy

            attr_value = @attributes[origin_attr]
            #returning default value
            if attr_value.nil?
              return nil unless self.persistent?
              attrs = self.class.goop_settings[:attributes]
              if attrs.include? attr_cpy
                if attrs[attr_cpy].include? :default
                  default_value = attrs[attr_cpy][:default].call(self)
                  @attributes[attr_cpy] = default_value
                  return default_value
                end
              end
            end

            return attr_value
          end
        end

        def check_rdftype_inconsistency(k)
          pred = uri_for_predicate(k)
          if RDF.rdf_type?(pred)
            raise ArgumentError, "A model cannot use the rdf:type predicate. This is a reserved predicate for internal use."
          end
        end

        def unique(*args)
          if args[-1].is_a?(Hash)
            options = args.pop
          else
            options = {}
          end
          options[:generator] = options[:generator] || :concat_and_encode
          options[:policy] = options[:policy] || :unique
          unique_context = { :fields => args }.merge(options)
          @goop_settings[:unique] = unique_context
        end

        def graph_policy(graph_policy)
          @goop_settings[:graph_policy] = graph_policy
        end

        def save_policy(save_policy)
          @goop_settings[:save_policy] = save_policy
        end

        def depends(*dependencies)
          @goop_settings[:depends] = []
          @goop_settings[:depends] << dependencies
        end

        def range_class(attr)
          if inverse_attr?(attr)
            return inverse_attr_options(attr)[0]
          end
          attr = attr.to_sym
          vals = attribute_validators(attr)
          if vals.include? :instance_of
            model_sym = vals[:instance_of][:with]
            cls = Goo.find_model_by_name(model_sym)
            return cls
          end
          nil
        end

        def inverse_attr?(attr)
          attr = attr.to_sym
          return ((goop_settings[:attributes].include? attr) and
                  (goop_settings[:attributes][attr].include? :inverse_of))
        end

        def attr_query_options(attr)
          attr = attr.to_sym
          return ((goop_settings[:attributes].include? attr) ?
                  (goop_settings[:attributes][attr][:query_options]) : nil)
        end

        def use_as(attr)
          return nil if goop_settings[:attributes][attr].nil?
          return goop_settings[:attributes][attr][:use]
        end

        def defined_attribute?(attr)
          return !goop_settings[:attributes][attr].nil?
        end

        def defined_attributes
          return goop_settings[:attributes].keys
        end

        def defined_attributes_not_transient
          attrs = defined_attributes
          attrs.select! { |attr| self.attr_query_options(attr).nil? }
          attrs.select! { |attr| !self.inverse_attr?(attr) }
          attrs.select! { |attr| !self.aggregate?(attr) }
          attrs.delete :resource_id
          return attrs
        end

        def collection_attribute
          return nil unless self.goop_settings.include? :collection
          return self.goop_settings[:collection][:attribute]
        end
        def collection_from_args(*args)
          return nil if self.goop_settings[:collection].nil?
          return nil if (args.length == 0) || (!args[0].kind_of? Hash)
          return args[0][self.goop_settings[:collection][:attribute]]
        end

        def anonymous?
          return false if !goop_settings.include? :unique
          return false if !goop_settings[:unique].include? :generator
          return goop_settings[:unique][:generator] == :anonymous
        end

        def inverse_attr_options(attr)
          attr = attr.to_sym
          options = goop_settings[:attributes][attr][:inverse_of]
          return Goo.find_model_by_name(options[:with]), options[:attribute]
        end

        def aggregate?(attr)
          return false if !goop_settings[:attributes].include? attr
          return !goop_settings[:attributes][attr][:aggregate].nil?
        end

        def aggregate_options(attr)
          return nil if !goop_settings[:attributes].include? attr
          return goop_settings[:attributes][attr][:aggregate]
        end

        def schemaless?
          return @goop_settings[:schemaless]
        end

      end
    end
  end
end
