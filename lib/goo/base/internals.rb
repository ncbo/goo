
module Goo
  module Base

    class Internals
      attr_reader :persistent
      attr_reader :modified
      attr_reader :loaded_dependencies
      attr_reader :store_name
      attr_accessor :errors

      alias :modified? :modified

      def initialize(base_instance)
        @_base_instance = base_instance
        @_id = nil
      end

      def new_resource(store_name = nil)
        @persistent = false
        @loaded = false
        @modified = @_base_instance.contains_data?
        @loaded_dependencies = false
        @store_name = store_name
      end

      def id=(resource_id)
        if not lazy_loaded?
          #this cannot evaluated in lazy loading since now props are loaded
          return if (@_base_instance.resource_id and
                      (@_base_instance.resource_id.value == resource_id.value))
        end

        if @persistent and not lazy_loaded?
          if not (@_base_instance.resource_id.bnode? and
                  not @_base_instance.resource_id.skolem?)
            raise StatusException,
                  "Cannot set up resource_ID #{resource_id} in a persistent obj."
          end
        end
        if not SparqlRd::Utils::Http.valid_uri?(resource_id.value)
          raise ArgumentError, "resource_id '#{resource_id}' must be a valid IRI."
        end
        @_id = resource_id
        if not lazy_loaded?
          @persistent = false
        end
        @loaded_dependencies = false
      end

      def id(auto_load=true)
        if auto_load and @_id.nil?
          @_id = Goo::Naming.getResourceId(@_base_instance)
        end
        return @_id
      end

      def load?
        if (@persistent and not lazy_loaded?) or @modified
          raise StatusException, "Resource cannot be loaded if object contains attributes."
        end
        true
      end

      def loaded
        @persistent = true
        @modified = false
        @loaded = true
      end

      def update?
        if not persistent
          raise StatusException, "Object not persistent. It cannot be updated. Save first"
        end
      end

      def saved
        @persistent = true
        @modified= false
        @loaded = true
      end

      def delete?
        if @modified
          raise StatusException, "Modified objects cannot be deleted"
        end
        #TODO: other constraints here.
        true
      end

      def deleted
        @persistent = false
        @modified = true
      end

      def modified=(vm)
        @modified=vm
      end

      def loaded?
        @loaded
      end

      def persistent?
        @persistent
      end

      def lazy_loaded?
        return (@persistent and not @loaded)
      end

      def lazy_loaded
        @persistent = true
        @loaded = false
      end
    end
  end
end
