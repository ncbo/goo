require_relative "settings/settings"
require_relative "../utils/rdf"

class OpenStruct
  def keys
    @table.keys
  end

  def each_key(&block)
    @table.each_key(block)
  end
end

class GooStruct < Struct
  # Override the initialize to handle hashes of named parameters
  def initialize(*args)
    if (args.length == 1 and args.first.instance_of? Hash) then
      args.first.each_pair do |k, v|
        if members.include? k then
          self[k] = v
        end
      end
    else
      super *args
    end
  end

  alias :keys :members
  alias :has_key? :include?

  def [](member)
    return nil if member.nil?
    self.send(member) rescue nil
  end

  def []=(member, values)
    self.send("#{member}=", values)
  end

  def include?(member)
    @_members_set ||= Set.new(self.members)
    @_members_set.include?(member)
  end

  def empty?
    self.values.empty?
  end
end

module Goo
  module Base

    class Resource
      STRUCT_DEFS = {}
      include Goo::Base::Settings
      include Goo::Search

      attr_reader :attributes
      attr_reader :inverse_atttributes
      attr_reader :errors

      attr_accessor :internals, :uuid

      def initialize(attributes = {})
        if self.class.goop_settings[:schemaless]
          @attributes = attributes
        else
          members = self.class.goop_settings[:attributes].keys
          struct_cls = STRUCT_DEFS[members.hash]
          if struct_cls.nil?
            struct_cls = GooStruct.new(self.class.name.gsub("::", ""), *members)
            STRUCT_DEFS[members.hash] = struct_cls
          end
          @attributes = struct_cls.new(*attributes.values)
        end


        model = self.class.goop_settings[:model]
        raise ArgumentError, "Can't create model, model settings do not contain model type." \
          unless model != nil
        raise ArgumentError, "Can't create model, model settings do not contain graph policy." \
          unless self.class.goop_settings[:graph_policy] != nil
        super()

        @internals = Internals.new(self)
        @internals.new_resource

        @_cached_exist = nil
        shape_instance

        #anon objects have an uuid property
        policy = self.class.goop_settings[:unique][:generator]
        if policy == :anonymous
          if !self.uuid
            self.class.shape_attribute :uuid
          end
          if !self.uuid
            self.uuid = Goo.uuid.generate
          end
        end
      end

      def self.read_only(resource_id,data,model=nil)
        if (data.include? :resource_id) or (data.include? "resource_id")
          data = data.dup
          data.delete :resource_id
          data.delete "resource_id"
        end
        if model.nil?
          model = self
        end
        unless model.respond_to? :type_uri
          raise ArgumentError, "Model must be a Goo model"
        end
        inst = model.new(data)
        inst.internals.read_only = true
        unless (resource_id.kind_of? SparqlRd::Resultset::IRI)
          resource_id = SparqlRd::Resultset::IRI.new resource_id
        end
        inst.internals.id = resource_id
        return inst
      end

      def self.inherited(subclass)
        #hook to set up default configuration.
        subclass.model
      end

      def contains_data?
        ((@attributes.has_key? :internals) and @attributes.length > 1) or
          ((not @attributes.has_key? :internals) and @attributes.length > 0)
      end

      def internals()
        @attributes[:internals]
      end

      def shape_instance

        #set to nil all the known properties via validators
        keys_attr = @attributes.keys
        self.class.attributes.each do |att_name, options|
          keys_attr << att_name
        end

        #if attributes are set then set values for properties.
        @attributes.each_pair do |attr,value|
          self.send("#{attr}=", *value, :in_load => true)
        end

        @attributes
      end

      def method_missing(sym, *args, &block)
        raise NoMethodError, "This Resource is defined as not schemaless. Object cannot respond to `#{sym}`"\
          if !self.class.goop_settings[:schemaless]
        if sym.to_s[-1] == "="
          self.class.shape_attribute(sym.to_s.chomp "=")
          return self.send(sym,args)
        end
        return nil
      end

      #set resource id wihout loading the rest of the attributes.
      def resource_id=(resource_id)
        internals.id=resource_id
      end

      def resource_id()
        internals.id
      end

      def exist?(reload=false)
        if @_cached_exist.nil? or reload
          epr = Goo.store(@store_name)
          return false if resource_id.bnode? and (not resource_id.skolem?)
          q = Queries.get_exist_query(self)
          rs = epr.query(q)
          @_cached_exist = false
          rs.each_solution do |sol|
            @_cached_exist = true
          end
        end
        return @_cached_exist
      end

      def each_linked_base
        raise ArgumentError, "No block given" unless block_given?
        @attributes.each do |key,values|
          mult_values = if values.kind_of? Array then values else [values] end
          mult_values.each do |object|
            if object.kind_of? Resource
              yield key,object
            end
          end
        end
      end

      def lazy_loaded?
        internals.lazy_loaded?
      end

      def lazy_loaded
        internals.lazy_loaded
      end

      def load(*args)
        self.resource_id = args[0] || self.resource_id
        raise ArgumentError, "Object #{resource_id.value} is already loaded" if loaded?
        unless (resource_id.kind_of? SparqlRd::Resultset::Node and\
               not resource_id.kind_of? SparqlRd::Resultset::Literal)
          raise ArgumentError, "resource_id must be an instance of RDF:IRI or RDF::BNode"
        end

        model_class = self.class

        opts = {}
        opts = args[1] if args.length > 1

        load_attrs = (opts.delete :load_attrs) || (self.class.goop_settings[:schemaless] ? nil : :defined)
        loaded = (load_attrs == :defined || load_attrs == :all)
        query_options = opts.delete :query_options
        if (load_attrs == :defined) || (load_attrs == :all && !self.class.schemaless?)
          load_attrs = self.class.defined_attributes_not_transient
        end
        load_attrs.delete :resource_id if load_attrs and load_attrs != :all
        store_name = opts.delete :store_name

        graph_id = nil
        collection = nil
        if self.class.goop_settings[:collection]
          unless self.internals.collection
            raise ArgumentError,
              "Find method needs collection parameter `#{self.class.goop_settings[:collection][:attribute]}`"\
              if args.length < 2
            raise ArgumentError,
              "Find method needs collection parameter `#{self.class.goop_settings[:collection][:attribute]}`"\
              unless args[1].include? self.class.goop_settings[:collection][:attribute]
            self.internals.collection = args[1][self.class.goop_settings[:collection][:attribute]]
          end
          lamb = self.class.goop_settings[:collection][:with]
          graph_id = lamb.call(self.internals.collection)
        end
        self.internals.graph_id = graph_id || self.class.type_uri

        shape_instance
        if !load_attrs.nil? && (load_attrs.length > 0)
          where_opts = Hash.new
          where_opts[:items] = { self.resource_id.value => self }
          where_opts[:load_attrs] = load_attrs
          where_opts[:all] = true if loaded and self.class.schemaless?
          if self.internals.collection
            coll_attr = self.class.goop_settings[:collection][:attribute]
            where_opts[coll_attr]=self.send(coll_attr)
          end
          self.class.where where_opts
        end
        if loaded
          self.internals.loaded
        else
          self.internals.lazy_loaded
        end
        return self
      end

      def delete(in_update=false)
        if self.internals.read_only
          raise Exception, "Read only objects cannot be deleted"
        end

        self.load unless self.loaded?
        internals.delete? unless in_update

        reached = Set.new
        reached = Goo::Queries.reachable_objects_from(resource_id, internals.store_name,
                                                      count_backlinks = true)
        to_delete = Set.new
        reached.each do |info|
          #include to delete related bnodes with no extra backlinks
          if info[:id].bnode? and info[:backlink_count] < 2
            to_delete << info[:id]
          end
        end
        objects_to_delete = [self]
        #find those extra bnodes as objects and load them.
        self.each_linked_base do |attr_name, linked_obj|
          next if !linked_obj.resource_id.bnode? #disable dependent
          next if in_update and not linked_obj.loaded?
          if to_delete.include? linked_obj.resource_id
            unless linked_obj.loaded?
              linked_obj.load
            end
            objects_to_delete << linked_obj
          end
        end
        queries = Goo::Queries.build_sparql_delete_query(objects_to_delete)
        if queries.length.nil? or queries.length == 0
          raise ArgumentError, "Internal error, no queries generated for delete"
        end
        epr = Goo.store(@store_name)
        queries.each do |query|
          epr.update(query)
        end

        internals.deleted
        if in_update
          return objects_to_delete
        end
        return nil
      end

      def save()
        if self.internals.read_only
          raise Exception, "Read only objects cannot be saved"
        end
        return nil if not self.modified?
        if not valid?
            exc = NotValidException.new
              "Object is not valid. It cannot be saved. Check errors."
            exc.errors = self.internals.errors
            raise exc
        end
        self.each_linked_base do |attr_name,linked_obj|
          next unless linked_obj.internals.loaded?
          if not linked_obj.valid?
            exc = NotValidException.new
              "Attribute '#{attr_name}' links to a non-valid object."
            exc.errors = linked_obj.internals.errors
            raise exc
          end
        end
        modified_models = []
        modified_models << self if self.modified?
        Goo::Queries.recursively_collect_modified_models(self, modified_models)

        modified_models.each do |mmodel|
          if mmodel.exist?(reload=true)
            #an update: first delete a copy from the store
            copy = mmodel.class.new
            if mmodel.internals.collection
              copy.internals.collection = mmodel.internals.collection
            end
            copy.load(mmodel.resource_id, load_attrs: :all)
            copy.delete(in_update=true)
          end
        end

        if modified_models.length > 0
          queries = Goo::Queries.build_sparql_update_query(modified_models)
          return nil if queries.length.nil? or queries.length == 0
          epr = Goo.store(@store_name)
          queries.each do |query|
            epr.update(query)
          end
        end

        if self.uuid
          self.resource_id=
              Goo::Queries.get_resource_id_by_uuid(self.uuid, self.class, @store_name)
        end
        self.each_linked_base do |attr_name, umodel|
          if umodel.resource_id.bnode? and umodel.modified?
            umodel.resource_id=
              Goo::Queries.get_resource_id_by_uuid(umodel.uuid, umodel.class, @store_name)
            umodel.internals.saved
          end
        end

        modified_models.each do |model|
          model.internals.saved
        end
        return self
      end

      def loaded?
        internals.loaded?
      end
      def persistent?
        internals.persistent?
      end
      def modified?
        return internals.modified? if internals.modified?
        self.each_linked_base do |attr_name,linked_obj|
          return linked_obj.modified? if linked_obj.modified?
        end
        return false
      end

      def lazy_load_attr(attr,value)
        internals.loaded_attrs << attr
        if !self.respond_to? attr
          self.class.shape_attribute(attr.to_s)
        end
        if @attributes[attr].kind_of? Array
          return if value.nil?
          @attributes[attr] << value unless @attributes[attr].include? value
        else
          value = [] if value.nil?
          if self.class.inverse_attr?(attr)
            if self.instance_variable_get("@#{attr}").nil?
              self.instance_variable_set("@#{attr}",[value])
            else
              self.instance_variable_get("@#{attr}") << value
            end
          else
            return send("#{attr}=",value,:in_load => true)
          end
        end
      end

      def self.all(*args)
        (args << {:load_attrs => []}) if args.length == 0
        return self.where(*args)
      end

      def self.page(*args)
        args[0] = [] if args[0].nil?
        page_n = args[0].delete(:page) || 1
        raise ArgumentError, "page mush be a number > 0" if (page_n < 1 or !(page_n.kind_of? Fixnum))
        size = args[0].delete(:size) || 20
        load_attrs = args.delete(:load_attrs)

        offset = (page_n-1) * size

        #first query gets the count
        count = self.where(args[-1].merge({count: true}))
        page_count = ((count+0.0)/size).ceil

        #second query gets the page
        items_hash = self.where(args[-1].merge({offset: offset, size: size + 1}))

        #third fills the collection with the attributes
        if items_hash.length > 0 and count > 0
          items = self.where(args[-1].merge({ items: items_hash }))
        else
          items = []
        end

        next_page = items.size > size
        items = items[0..-2] if items.length > size

        return Goo::Base::Page.new(page_n,next_page,page_count,items)
      end

      public
      def self.where(*args)
        if (args.length == 0) or (args.length > 1) or (not args[0].kind_of? Hash)
          raise ArgumentError,
            "#{self.class.name}.where accepts (attribute => value) associations or :all"
        end
        attributes = args[0]
        if attributes
          attributes.each_key do |attr|
            raise ArgumentError, "`#{attr}` value `nil` is not allowed in `where` call." if attributes[attr].nil?
          end
        end
        if attributes.include? :resource_id
          raise ArgumentError, ":resource_id is not an attribute. It cannot be used in :where"
        end

        items = attributes.delete(:items)
        offset = attributes.delete(:offset)
        size = attributes.delete(:size)
        in_aggregate = attributes.delete(:in_aggregate)
        count = attributes.delete(:count)
        only_known = (attributes.delete :only_known) || true
        extra_filter = attributes.delete :filter
        load_attrs = (attributes.delete :load_attrs) || :defined
        mark_as_loaded = (load_attrs == :defined)
        load_attrs = defined_attributes_not_transient if load_attrs == :defined
        load_attrs << :uuid if anonymous? and load_attrs.class == Array
        load_attrs[:uuid]=true if anonymous? and load_attrs.class == Hash
        all_attributes = false
        if self.schemaless?
          all_attributes = attributes.delete(:all)
          all_attributes = all_attributes || (load_attrs == :all)
          load_attrs = {} if all_attributes
        end

        query_options = attributes.delete :query_options
        ignore_inverse = attributes.include?(:ignore_inverse) and attributes[:ignore_inverse]
        attributes.delete(:ignore_inverse)
        collection = collection_from_args(*args)
        collection_attr = collection_attribute

        search_query = Goo::Queries.search_by_attributes(
                          attributes, self, @store_name,
                          ignore_inverse, load_attrs,only_known,
                          offset, size, count, items, extra_filter,
                          in_aggregate, all_attributes)

        epr = Goo.store(@store_name)
        rs = epr.query(search_query,options = (query_options || {}))

        aggs = (load_attrs == :all) ? [] : load_attrs.select { |x,v| aggregate?(x) }
        unless load_attrs == :all
          load_attrs = load_attrs.select { |x,v| !aggregate?(x) }
        end

        if count
          rs.each_solution do |sol|
            return sol.get(:count).parsed_value
          end
        end
        items = items || Hash.new
        dependent_items = Hash.new
        rs.each_solution do |sol|
          resource_id = sol.get(:subject)
          if in_aggregate
            agg_value = sol.get(:agg_value)
            items[resource_id.value].instance_variable_set("@#{aggs.keys.first.to_s}",agg_value)
            next
          end
          if !items[resource_id.value]
            item = self.new
            item.internals.lazy_loaded
            item.resource_id = resource_id
            items[resource_id.value] = item
            if collection
              item.internals.collection = collection
              item.internals.graph_id = collection.resource_id.value
            else
              graph_id = Goo::Naming.get_graph_id(self)
              item.internals.graph_id = graph_id
            end
            item.internals.lazy_loaded
          end
          item = items[resource_id.value]
          if all_attributes
            pred = sol.get :predicate
            obj = sol.get :object
            attr = item.class.attr_for_predicate_uri(pred.value)
            if attr.nil? && self.schemaless?
              item.attributes.include?(pred) ? item.attributes[pred] << obj : item.attributes[pred] =[obj]
              next
            end
            range = range_class(attr)
            unless range.nil?
              obj = range.find obj, load_attrs: []
            end
            item.lazy_load_attr(attr,obj)
          end
          next if load_attrs.nil?
          if load_attrs.length > 0
            sol.get_vars.each do |var|
              next if var == "subject"
              value = (sol.get var.to_sym)
              (sol_attr, sol_model) = var.split "_onmodel_"
              next if sol_model.nil?
              if self.goo_name == sol_model.to_sym
                if (value.kind_of? SparqlRd::Resultset::IRI) ||
                   (value.kind_of? SparqlRd::Resultset::BNode)
                  #create nested stuff or find
                  range = range_class(sol_attr.to_sym)
                  unless range.nil?
                    if dependent_items.include? value
                      value = dependent_items[value]
                    else
                      if item.internals.collection
                        value = range.find value,
                                item.class.goop_settings[:collection][:attribute] => item.internals.collection,
                                load_attrs: []
                      else
                        value = range.find value, load_attrs: []
                      end
                      value.internals.graph_id = range.type_uri
                      dependent_items[value.resource_id]= value
                    end
                  end
                end
                unless sol_attr.to_sym == collection_attr
                  item.lazy_load_attr(sol_attr.to_sym, value)
                end
              end
            end
          end
        end
        if mark_as_loaded
          items.values.each do |v|
            v.internals.loaded
          end
        end
        if in_aggregate
          items.values.each do |v|
            value = v.instance_variable_get("@#{aggs.keys.first.to_s}")
            v.instance_variable_set("@#{aggs.keys.first.to_s}",SparqlRd::Resultset::IntegerLiteral.new(0)) if value.nil?
          end
        end
        if aggs.length > 0 and !in_aggregate
          aggs.each do |agg,opts|
            #only know how to do one at a time
            options = { load_attrs:{ agg => opts}, items: items, in_aggregate: true }
            options[collection_attr]=collection if collection
            self.where options
          end
        end
        if dependent_items.length > 0 && (load_attrs.kind_of? Hash)
          types = dependent_items.map { |k,v| v.class }.uniq
          by_types = Hash.new
          types.each do |t| by_types[t] = Hash.new end
          dependent_items.each do |k,v|
            by_types[v.class][v.resource_id.value] = v
          end
          by_types.each do |t,ts|
            #do I need more stuff for type t
            #yes if there is a hash for a property where the range is t
            nested_attr_to_load = Hash.new
            load_attrs.each do |k,v|
              if v.kind_of? Hash
                if self.range_class(k) == t
                  v.each do |sk,sv| nested_attr_to_load[sk] = sv end
                end
              end
            end
            if nested_attr_to_load.length > 0
              t.where(load_attrs: nested_attr_to_load, items: ts )
            end
          end
        end
        return offset ? items : items.values
      end

      def self.find(*args)
        param = args[0]
        opts = {}
        opts = args[1] if args.length > 1 and args[1]

        load_attributes = opts.delete :load_attributes
        load_attributes = false if load_attributes.nil? #default
        store_name = opts.delete :store_name

        unless goop_settings[:collection].nil?
          unless opts.nil? || (opts.include? goop_settings[:collection][:attribute])
            raise ArgumentError,
              "This is a collection model that needs the attribute `#{goop_settings[:collection][:attribute]}` to run find."
          end
        end

        #with :resource_id in DSL we do not check for :unique attributes
        unless self.goop_settings[:attributes].include? :resource_id
          if (self.goop_settings[:unique][:fields].nil? or
             self.goop_settings[:unique][:fields].length != 1)
            mess = "The call #{self.name}.find cannot be used " +
                   " if the model has no `:unique => true` attributes"
            #raise ArgumentError, mess
          end
        end

        if (param.kind_of? String) && goop_settings[:unique][:fields]
          key_attribute = goop_settings[:unique][:fields][0]
          raise ArgumentError, "Find should receive a IRI in a collection model."\
            if key_attribute.nil? && !args[0].kind_of?(SparqlRd::Resultset::IRI)
          where_opts = key_attribute.nil? ? Hash.new : { key_attribute => param }
          where_opts.merge! args[1] if args[1]
          ins = self.where where_opts
          if ins.length > 1
            raise ArgumentError,
              "Inconsistent model behaviour. There are #{ins.length} instance with #{key_attribute} => #{param}"
          end
          return nil if ins.length == 0
          ins[0].load(nil,load_attrs: :all) if load_attributes
          return ins[0]
        elsif ((param.kind_of? SparqlRd::Resultset::BNode) || (param.kind_of? SparqlRd::Resultset::IRI))
          iri = param
        else
          raise ArgumentError,
            "#{self.class.name}.find only accepts IRIs as input or String if accessing :unique fields."
        end
        opts = args[1] ? opts.merge(args[1])  : opts;
        return self.load(iri,opts)
      end

      def self.load(*args)
        resource_id = args[0]
        opts = {}
        opts = args[1] if args.length > 1

        load_attributes = opts.delete :load_attributes
        store_name = opts.delete :store_name

        model_class = self
        if model_class == Goo::Base::Resource
          model_class = Queries.get_resource_class(resource_id, store_name)
          if model_class.nil?
            return nil
          end
        end
        inst = model_class.new
        inst.load(*args)
        return inst
      end

      def errors
        return internals.errors
      end

      def attr_loaded? attr
        return (loaded? or (internals.loaded_attrs.include? attr))
      end

      def valid?
        internals.errors = Hash.new()
        self.class.attributes.each do |att,att_options|
          internals.errors[att] = []
        end
        self.class.attributes.each do |att,att_options|
          if att_options[:validators] and att_options[:validators].length > 0
            att_options[:validators].each do |val, val_options|
              if not Goo.validators.include? val
                raise ArgumentError, "Validator #{val} cannot be found"
              end
              if not val_options.include? :instance
                validator = Goo.validators[val].new(val_options)
                val_options[:instance] = validator
              end
              val_options[:instance].validate_each(self,att,@attributes[att])
            end
          end
        end

        new_objects_check

        internals.errors.reject! { |att,val| val.length == 0 }
        return (internals.errors.length == 0)
      end

      private
      def load_on_demand(attrs,original_attrs=nil,store_name=nil)
        graph_id = self.internals.graph_id
        if graph_id.nil?
          raise ArgumentError, "Graph ID must be known at this point"
        end
        query_options = {}
        unless original_attrs.nil?
          original_attrs.each do |attr|
            att_opts = self.class.attr_query_options(attr)
            query_options = query_options.merge(att_opts) if att_opts
          end
        end
        loaded_attributes = Queries.get_resource_attributes(resource_id, self.class,
                                                            store_name, graph_id,
                                                            attributes=attrs,
                                                            query_options=query_options,
                                                            collection=self.internals.collection)

        if original_attrs
          return loaded_attributes.values[0]
        else
          attrs.each do |attr|
            #actually we only use one value
            return lazy_load_attr(attr,loaded_attributes.values[0])
          end
        end
        return loaded_attributes.values[0]
      end

      def alias_rename(atts)
        return atts if self.class.goop_settings[:alias_table].nil? || (self.class.goop_settings[:alias_table].length == 0)
        atts_out = {}
        index_table = self.class.goop_settings[:alias_table]
        atts.each do |k,v|
          if not (self.class.goop_settings[:alias_table].include? k)
            atts_out[k] = v
          else
            atts_out[index_table[k]] = v
          end
        end
        return atts_out
      end

      def new_objects_check
        #checking if there are new objects that already exist
        self.attributes.each do |att,att_options|
          values = self.attributes[att]
          next if values.nil?
          values = [values] unless values.kind_of? Array
          values.each do |value|
            if value.kind_of? Goo::Base::Resource
              next if value.persistent?
              #value is new but already exists
              if value.exist?(reload=true)
                self.internals.errors[att] = [] if self.internals.errors[att].nil?
                self.internals.errors[att] << "Attribute '#{att}' references a new object that already exists #{value.resource_id.value}"
              end
            end
          end
        end
      end

      def inverse_attr_values(attr,origin_attr=nil,load_attrs=nil)
        query_options = self.class.attr_query_options(origin_attr)
        inv_cls, inv_attr = self.class.inverse_attr_options(attr)
        where_opts = { inv_attr => self, ignore_inverse: true }
        if inv_cls.goop_settings[:collection]
          #assume same collection
          where_opts[inv_cls.goop_settings[:collection][:attribute]] = self.internals.collection
        end
        where_opts[:query_options] = query_options unless query_options.nil?
        where_opts[:load_attrs] = load_attrs if !load_attrs.nil?
        values = inv_cls.where(where_opts)
        return values
      end

      def aggregate(attr)
        #try to see if it is in the attribute hash
        value = instance_variable_get("@#{attr}")
        return value unless value.nil?

        aggregate_opts = self.class.aggregate_options(attr)

        #only count is supported
        aggregate_operation = aggregate_opts[:with]
        on_attribute = aggregate_opts[:attribute]
        if !self.attributes[on_attribute].nil?
          value = self.attributes[on_attribute].count
          instance_variable_set("@#{attr}",value)
          return value
        end

        if self.class.inverse_attr? on_attribute
          values = inverse_attr_values(on_attribute,on_attribute,load_attrs=[])
          instance_variable_set("@#{attr}",values.count)
          return values.count
        else
          load_on_demand([on_attribute], nil)
          return self.attributes[on_attribute].count
        end
      end
    end
  end
end
