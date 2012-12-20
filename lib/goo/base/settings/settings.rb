
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

        def attributes(*args)
          return self.goop_settings[:attributes].clone
        end

        def type_uri
          return prefix + goop_settings[:model].to_s.camelize
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
          att = att.to_s
          if not goop_settings[:attributes].include? att
            return prefix + att
          end
          if not goop_settings[:attributes][att].include? :namespace
            return prefix + att
          end
          return namespace( goop_settings[:attributes][att] ) + att
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
          return @goop_settings[:model].to_s.underscore.to_sym
        end

        def model(*args)
          options = args.reverse
          if options.length == 0 or (not options[-1].kind_of? Symbol)
            type = self.to_s.to_sym
          else
            type = options.pop
          end
          if instance_variables.index(:@goop_settings) == nil
            @goop_settings = {}
          end
          Goo.models << self
          @goop_settings[:model] = type
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
                end
              end
            end
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

        def inverse_attr_options(attr)
          attr = attr.to_sym
          options = goop_settings[:attributes][attr][:inverse_of]
          return Goo.find_model_by_name(options[:with]), options[:attribute]
        end
      end
    end
  end
end
