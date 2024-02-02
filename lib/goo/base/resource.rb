require 'cgi'
require_relative "settings/settings"

module Goo
  module Base
    AGGREGATE_VALUE = Struct.new(:attribute,:aggregate,:value)

    class IDGenerationError < StandardError; end;

    class Resource
      include Goo::Base::Settings
      include Goo::Search

      attr_reader :loaded_attributes
      attr_reader :modified_attributes
      attr_reader :errors
      attr_reader :aggregates
      attr_reader :unmapped

      attr_reader :id

      def initialize(*args)
        @loaded_attributes = Set.new
        @modified_attributes = Set.new
        @previous_values = nil
        @persistent = false
        @aggregates = nil
        @unmapped = nil

        attributes = args[0] || {}
        opt_symbols = Goo.resource_options
        attributes.each do |attr,value|
          next if opt_symbols.include?(attr)
          self.send("#{attr}=",value)
        end

        @id = attributes.delete :id
      end

      def valid?
        validation_errors = {}
        self.class.attributes.each do |attr|
          inst_value = self.instance_variable_get("@#{attr}")
          attr_errors = Goo::Validators::Enforce.enforce(self,attr,inst_value)
          unless attr_errors.nil?
            validation_errors[attr] = attr_errors
          end
        end

        if !@persistent && validation_errors.length == 0
          uattr = self.class.name_with.instance_of?(Symbol) ? self.class.name_with : :proc_naming
          if validation_errors[uattr].nil?
            begin
              if self.exist?(from_valid=true)
                validation_errors[uattr] = validation_errors[uattr] || {}
                validation_errors[uattr][:duplicate] =
                  "There is already a persistent resource with id `#{@id.to_s}`"
              end
            rescue ArgumentError => e
              (validation_errors[uattr] ||= {})[:existence] = e.message
            end
            if self.class.name_with == :id && @id.nil?
              (validation_errors[:id] ||= {})[:existence] = ":id must be set if configured in name_with"
            end
          end
        end

        @errors = validation_errors
        return @errors.length == 0
      end

      def id=(new_id)
        if !@id.nil? and @persistent
          raise ArgumentError, "The id of a persistent object cannot be changed."
        end
        raise ArgumentError, "ID must be an RDF::URI" unless new_id.kind_of?(RDF::URI)
        @id = new_id
      end

      def id
        @id = generate_id if @id.nil?

        @id
          end

      def persistent?
        return @persistent
      end

      def persistent=(val)
        @persistent=val
      end

      def modified?
        return modified_attributes.length > 0
      end

      def exist?(from_valid = false)
          begin
          id unless self.class.name_with.kind_of?(Symbol)
          rescue IDGenerationError
          # Ignored
          end

        _id = @id
        if from_valid || _id.nil?
          _id = generate_id rescue _id = nil
        end

        return false unless _id
        Goo::SPARQL::Queries.model_exist(self, id = _id)
      end

      def fully_loaded?
        #every declared attributed has been loaded
        return @loaded_attributes == Set.new(self.class.attributes)
      end

      def missing_load_attributes
        #every declared attributed has been loaded
        return Set.new(self.class.attributes) - @loaded_attributes
      end

      def unmapped_set(attribute,value)
        @unmapped ||= {}
        (@unmapped[attribute] ||= Set.new) << value
      end

      def unmmaped_to_array
        cpy = {}
        @unmapped.each do |attr,v|
          cpy[attr] = v.to_a
        end
        @unmapped = cpy
      end

      def delete(*args)
        if self.kind_of?(Goo::Base::Enum)
          unless args[0] && args[0][:init_enum]
            raise ArgumentError, "Enums cannot be deleted"
          end
        end

        raise ArgumentError, "This object is not persistent and cannot be deleted" if !@persistent

        if !fully_loaded?
          missing = missing_load_attributes
          options_load = { models: [ self ], klass: self.class, :include => missing }
          if self.class.collection_opts
            options_load[:collection] = self.collection
          end
          Goo::SPARQL::Queries.model_load(options_load)
        end

        graph_delete,bnode_delete = Goo::SPARQL::Triples.model_delete_triples(self)

        begin
          bnode_delete.each do |attr,delete_query|
            Goo.sparql_update_client.update(delete_query)
          end
          Goo.sparql_update_client.delete_data(graph_delete, graph: self.graph)
        rescue Exception => e
          raise e
        end
        @persistent = false
        @modified = true
        if self.class.inmutable? && self.class.inm_instances
          self.class.load_inmutable_instances
        end
        return nil
      end

      def bring(*opts)
        opts.each do |k|
          if k.kind_of?(Hash)
            k.each do |k2,v|
              if self.class.handler?(k2)
                raise ArgumentError, "Unable to bring a method based attr #{k2}"
              end
              self.instance_variable_set("@#{k2}",nil)
            end
          else
            if self.class.handler?(k)
              raise ArgumentError, "Unable to bring a method based attr #{k}"
            end
            self.instance_variable_set("@#{k}",nil)
          end
        end
        query = self.class.where.models([self]).include(*opts)
        if self.class.collection_opts.instance_of?(Symbol)
          collection_attribute = self.class.collection_opts
          query.in(self.send("#{collection_attribute}"))
        end
        query.all
        self
      end

      def graph
        opts = self.class.collection_opts
        if opts.nil?
          return self.class.uri_type
        end
        col = collection
        if col.is_a?Array
          if col.length == 1
            col = col.first
          else
            raise Exception, "collection in save only can be len=1"
          end
        end
        return col ? col.id : nil
      end

      def self.map_attributes(inst,equivalent_predicates=nil)
        if (inst.kind_of?(Goo::Base::Resource) && inst.unmapped.nil?) ||
            (!inst.respond_to?(:unmapped) && inst[:unmapped].nil?)
          raise ArgumentError, "Resource.map_attributes only works for :unmapped instances"
        end
        klass = inst.respond_to?(:klass) ? inst[:klass] : inst.class
        unmapped = inst.respond_to?(:klass) ? inst[:unmapped] : inst.unmapped
        list_attrs = klass.attributes(:list)
        unmapped_string_keys = Hash.new
        unmapped.each do |k,v|
          unmapped_string_keys[k.to_s] = v
        end
        klass.attributes.each do |attr|
          next if inst.class.collection?(attr) #collection is already there
          next unless inst.respond_to?(attr)
          attr_uri = klass.attribute_uri(attr,inst.collection).to_s
          if unmapped_string_keys.include?(attr_uri.to_s) ||
              (equivalent_predicates && equivalent_predicates.include?(attr_uri))
            object = nil
            if !unmapped_string_keys.include?(attr_uri)
              equivalent_predicates[attr_uri].each do |eq_attr|
                if object.nil? and !unmapped_string_keys[eq_attr].nil?
                  object = unmapped_string_keys[eq_attr].dup
                else
                  if object.is_a?Array
                    if !unmapped_string_keys[eq_attr].nil?
                      object.concat(unmapped_string_keys[eq_attr])
                    end
                  end
                end
              end
              if object.nil?
                inst.send("#{attr}=",
                           list_attrs.include?(attr) ? [] : nil, on_load: true)
                next
              end
            else
              object = unmapped_string_keys[attr_uri]
            end
            object = object.map { |o| o.is_a?(RDF::URI) ? o : o.object }
            if klass.range(attr)
              object = object.map { |o|
                o.is_a?(RDF::URI) ? klass.range_object(attr,o) : o }
            end
            unless list_attrs.include?(attr)
              object = object.first
            end
            if inst.respond_to?(:klass)
              inst[attr] = object
            else
              inst.send("#{attr}=",object, on_load: true)
            end
          else
            inst.send("#{attr}=",
                      list_attrs.include?(attr) ? [] : nil, on_load: true)
            if inst.id.to_s == "http://purl.obolibrary.org/obo/IAO_0000415"
              if attr == :definition
               # binding.pry
              end
            end
          end

        end
      end

      def collection
        opts = self.class.collection_opts
        if opts.instance_of?(Symbol)
          if self.class.attributes.include?(opts)
            value = self.send("#{opts}")
            if value.nil?
              raise ArgumentError, "Collection `#{opts}` is nil"
            end
            return value
          else
            raise ArgumentError, "Collection `#{opts}` is not an attribute"
          end
        end
      end

      def add_aggregate(attribute,aggregate,value)
        (@aggregates ||= []) << AGGREGATE_VALUE.new(attribute,aggregate,value)
      end

      def save(*opts)

        if self.kind_of?(Goo::Base::Enum)
          unless opts[0] && opts[0][:init_enum]
            raise ArgumentError, "Enums can only be created on initialization"
          end
        end
        batch_file = nil
        callbacks = true
        if opts && opts.length > 0 && opts.first.is_a?(Hash)
          if opts.first[:batch] && opts.first[:batch].is_a?(File)
            batch_file = opts.first[:batch]
          end

          callbacks = opts.first[:callbacks]
        end

        if !batch_file
          if not modified?
            return self
          end
          raise Goo::Base::NotValidException, "Object is not valid. Check errors." unless valid?
        end

        #set default values before saving
        unless self.persistent?
          self.class.attributes_with_defaults.each do |attr|
            value = self.send("#{attr}")
            if value.nil?
              value = self.class.default(attr).call(self)
              self.send("#{attr}=", value)
            end
          end
        end

        #call update callback before saving
        if callbacks
          self.class.attributes_with_update_callbacks.each do |attr|
            Goo::Validators::Enforce.enforce_callbacks(self, attr)
          end
        end

        graph_insert, graph_delete = Goo::SPARQL::Triples.model_update_triples(self)
        graph = self.graph


        if graph_delete and graph_delete.size > 0
          begin
            Goo.sparql_update_client.delete_data(graph_delete, graph: graph)
          rescue Exception => e
            raise e
          end
        end
        if graph_insert and graph_insert.size > 0
          begin
            if batch_file
              lines = []
              graph_insert.each do |t|
                lines << [t.subject.to_ntriples,
                          t.predicate.to_ntriples,
                          t.object.to_ntriples,
                          graph.to_ntriples,
                          ".\n" ].join(' ')
              end
              batch_file.write(lines.join(""))
              batch_file.flush()
            else
              Goo.sparql_update_client.insert_data(graph_insert, graph: graph)
            end
          rescue Exception => e
            raise e
          end
        end

        #after save all attributes where loaded
        @loaded_attributes = Set.new(self.class.attributes).union(@loaded_attributes)

        @modified_attributes = Set.new
        @persistent = true
        if self.class.inmutable? && self.class.inm_instances
          self.class.load_inmutable_instances
        end
        return self
      end

      def bring?(attr)
        return @persistent &&
                 !@loaded_attributes.include?(attr) &&
                 !@modified_attributes.include?(attr)
      end

      def bring_remaining
        to_bring = []
        self.class.attributes.each do |attr|
          to_bring << attr if self.bring?(attr)
        end
        self.bring(*to_bring)
      end

      def previous_values
        return @previous_values
      end

      def to_hash
        attr_hash = {}
        self.class.attributes.each do |attr|
          v = self.instance_variable_get("@#{attr}")
          attr_hash[attr]=v unless v.nil?
        end
        if @unmapped
          all_attr_uris = Set.new
          self.class.attributes.each do |attr|
            if self.class.collection_opts
              all_attr_uris << self.class.attribute_uri(attr,self.collection)
            else
              all_attr_uris << self.class.attribute_uri(attr)
            end
          end
          @unmapped.each do |attr,values|
            unless all_attr_uris.include?(attr)
              attr_hash[attr] = values.map { |v| v.to_s }
            end
          end
        end
        attr_hash[:id] = @id
        return attr_hash
      end

      ###
      # Class level methods
      # ##

      def self.range_object(attr,id)
        klass_range = self.range(attr)
        return nil if klass_range.nil?
        range_object = klass_range.new
        range_object.id = id
        range_object.persistent = true
        return range_object
      end

      def self.find(id, *options)
        if !id.instance_of?(RDF::URI) && self.name_with == :id
          id = RDF::URI.new(id)
        end
        unless id.instance_of?(RDF::URI)
          id = id_from_unique_attribute(name_with(),id)
        end
        if self.inmutable? && self.inm_instances && self.inm_instances[id]
          w = Goo::Base::Where.new(self)
          w.instance_variable_set("@result", [self.inm_instances[id]])
          return w
        end
        options_load = { ids: [id], klass: self }.merge(options[-1] || {})
        options_load[:find] = true
        where = Goo::Base::Where.new(self)
        where.where_options_load = options_load
        return where
      end

      def self.in(collection)
        return where.in(collection)
      end

      def self.where(*match)
        return Goo::Base::Where.new(self,*match)
      end

      def self.all
        return self.where.all
      end

      protected

      def id_from_attribute()
        uattr = self.class.name_with
        uvalue = self.send("#{uattr}")
        return self.class.id_from_unique_attribute(uattr, uvalue)
      end

      def generate_id
        return nil unless self.class.name_with

        raise IDGenerationError, ":id must be set if configured in name_with" if self.class.name_with == :id
        custom_name = self.class.name_with
        if custom_name.instance_of?(Symbol)
          id = id_from_attribute
        elsif custom_name
          begin
            id = custom_name.call(self)
          rescue => e
            raise IDGenerationError, "Problem with custom id generation: #{e.message}"
          end
        else
          raise IDGenerationError, "custom_name is nil. settings for this model are incorrect."
        end
        id
      end

    end

  end
end
