require_relative "settings/settings"
require_relative "../utils/rdf"

module Goo
  module Base

    class Resource < OpenStruct
      include Goo::Base::Settings

      attr_reader :attributes
      
      def initialize(attributes) 
        model = self.class.goop_settings[:model]
        raise ArgumentError, "Can't create model, model settings do not contain model type." \
          unless model != nil
        raise ArgumentError, "Can't create model, model settings do not contain graph policy." \
          unless self.class.goop_settings[:graph_policy] != nil
        super()

        @attributes = attributes.dup
        @attributes[:internals] = Internals.new(self)
        @attributes[:internals].new_resource

        @_cached_exist = nil
        shape_me

        #anon objects have an uuid property
        policy = self.class.goop_settings[:unique][:generator]
        if policy == :anonymous
          if not @table.include? :uuid
            self.uuid = Goo.uuid.generate
          end
        end
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

      def shape_attribute(attr)
        attr = attr.to_sym
        validators = self.class.attribute_validators(attr)
        cardinality_opt = validators[:cardinality]
        card_validator = nil
        if cardinality_opt
          card_validator = Goo::Validators::CardinalityValidator.new(cardinality_opt)
        end
        prx = AttributeValueProxy.new(card_validator,
                                      @attributes[:internals])
        define_singleton_method("#{attr}=") do |*args|
          current_value = @table[attr]
          tvalue = prx.call({ :value => args, :attr => attr, 
                              :current_value => current_value })
          if attr == :uuid
            #uuid forced to be unique
            tvalue = tvalue[0] 
          end
          if internals.persistent?
            if not internals.lazy_loaded? and
               self.class.goop_settings[:unique] and 
               self.class.goop_settings[:unique][:fields] and
               self.class.goop_settings[:unique][:fields].include? attr and
               @table[attr] != tvalue
               raise KeyFieldUpdateError, "Attribute '#{attr}' cannot be changed in a persisted object."
            end
          end
          if @table[attr] != tvalue and attr != :uuid
            internals.modified = true
          end
          @table[attr] = tvalue
        end
        define_singleton_method("#{attr}") do |*args|
          return @table[attr]
        end
      end 

      def shape_me
        if @attributes.length > 1 #size 1 is internals
          check_rdftype_inconsistency
          
          #set to nil all the known properties via validators
          keys_attr = @attributes.keys
          self.class.attributes.each do |att_name, options|
            keys_attr << att_name
          end
          keys_attr.each do |attr|
            next if attr == :internals
            shape_attribute(attr)
          end

          #if attributes are set then set values for properties.
          @attributes.each_pair do |attr,value|
            next if attr == :internals
            self.send("#{attr}=", value)
          end
        end
        internal_status = @attributes[:internals] 
        @table[:internals] = internal_status
        @attributes = @table
      end
    
      def method_missing(sym, *args, &block)
        if sym.to_s[-1] == "="
          shape_attribute(sym.to_s.chomp "=")
          return self.send(sym,args)
        end
        return nil
        #raise NoMethodError, "undefined method `#{sym}'"
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
          q = """SELECT (count(?o) as ?c) WHERE { #{resource_id.to_turtle} a ?o }"""
          rs = epr.query(q)
          rs.each_solution do |sol|
            @_cached_exist = sol.get(:c).parsed_value > 0
          end
        end
        return @_cached_exist
      end

      def check_rdftype_inconsistency
        self.class.goop_settings[:model]
        @attributes.each_pair do |k,v|
          attr_type = RDF.rdf_type?(k)
          if attr_type and \
              not Goo::Utils.symbol_str_equals(@attributes[k], model_class)
            raise ArgumentError,'Object type cannot be redefined in attributes'
          elsif attr_type
            @attributes.delete(k)
          end
        end
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
      
      def lazy_loaded
        internals.lazy_loaded
      end

      def load(resource_id=nil)
        if resource_id.nil? and internals.id(false).nil?
          raise StatusException, "Cannot load Resource without a resource in paramater or internals"
        end
        if resource_id.nil?
          resource_id = internals.id(false)
        end
        unless (resource_id.kind_of? SparqlRd::Resultset::Node and
               not resource_id.kind_of? SparqlRd::Resultset::Literal)
          raise ArgumentError, "resource_id must be an instance of RDF:IRI or RDF::BNode"
        end
        internals.load?

        model_class = Goo::Queries.get_resource_class(resource_id,internals.store_name)
        if model_class.nil?
          raise ArgumentError, "ResourceID '#{resource_id}' does not exist"
        end
        if model_class != self.class
          raise ArgumentError, 
              "ResourceID '#{resource_id}' is an instance of type #{model_class} in the store"
        end

        store_attributes = Goo::Queries.get_resource_attributes(resource_id, self.class, 
                                                           internals.store_name)
        internal_status = @attributes[:internals]
        @attributes = store_attributes
        @attributes[:internals] = internal_status

        shape_me
        internals.id=resource_id
        internals.loaded
      end

      def delete(in_update=false)
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
          next if in_update and not linked_obj.loaded?
          if to_delete.include? linked_obj.resource_id
            unless linked_obj.loaded?
              linked_obj.load
            end
            objects_to_delete << linked_obj
          end
        end
        queries = Goo::Queries.build_sparql_delete_query(objects_to_delete)
        return false if queries.length.nil? or queries.length == 0
        epr = Goo.store(@store_name)
        queries.each do |query|
          epr.update(query) 
        end

        internals.deleted
        if in_update
          return objects_to_delete
        end
      end

      def save()
        internals.save?
        return if not self.modified?
        if not valid?
            exc = NotValidException.new("Object is not valid. It cannot be saved. Check errors.")
            exc.errors = linked_obj.errors
            raise exc
        end
        self.each_linked_base do |attr_name,linked_obj|
          next unless linked_obj.internals.loaded?
          if not linked_obj.valid?
            exc = NotValidException.new("Attribute '#{attr_name}' links to a non-valid object.")
            exc.errors = linked_obj.errors
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
            copy.load(mmodel.resource_id)
            copy.delete(in_update=true)
          end
        end

        if modified_models.length > 0
          queries = Goo::Queries.build_sparql_update_query(modified_models)
          return false if queries.length.nil? or queries.length == 0
          epr = Goo.store(@store_name)
          queries.each do |query|
            epr.update(query) 
          end
        end

        if not self.uuid.nil?
          self.resource_id= Goo::Queries.get_resource_id_by_uuid(self.uuid, self.class, @store_name)
        end
        self.each_linked_base do |attr_name, umodel|
          if umodel.resource_id.bnode? and umodel.modified?
            umodel.resource_id= Goo::Queries.get_resource_id_by_uuid(umodel.uuid, umodel.class, @store_name)
            umodel.internals.saved
          end
        end

        modified_models.each do |model|
          model.internals.saved
        end
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

      def self.search(attributes)
        epr = Goo.store(@store_name)
        search_query = Goo::Queries.search_by_attributes(attributes, self, @store_name)
        rs = epr.query(search_query)
        items = []
        rs.each_solution do |sol|
          resource_id = sol.get(:subject)
          item = self.new
          item.internals.lazy_loaded
          item.resource_id = resource_id
          items << item
        end
        return items
      end

      def self.load(resource_id, store_name=nil)
        model_class = Queries.get_resource_class(resource_id, store_name)
        if model_class.nil?
          return nil
        end
        inst = model_class.new
        inst.load(resource_id)
        return inst
      end

      def valid?
        binding.pry
      end

    end
  end
end
