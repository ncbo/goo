
module Goo
  module Base

    class AttributeValueProxy
      def initialize(validator,internals)
        @validator = validator
        @internals = internals
      end

      def cardinality_transform(attr, value, current_value)
        if @validator.nil?
          unless value.kind_of? Array
            raise ArgumentError, "Attribute '#{attr} must be an array. No cardinality configured.'"
          end
          return value
        end
        value = value.first if value.is_a?(Array) && value.first.is_a?(SparqlRd::Resultset::BooleanLiteral)
        if value.kind_of? Array
          if @validator.options[:max] and value.length > @validator.options[:max]
            #TODO review this
            return value[0] if attr == :prefLabel
            raise ArgumentError, "Attribute '#{attr}' does not satisfy max cardinality."
          end
          if @validator.options[:min] and value.length < @validator.options[:min]
            raise ArgumentError, "Attribute '#{attr}' does not satisfy min cardinality."
          end
          if @validator.options[:max] and @validator.options[:max] == 1
            return value[0]
          end
        else #not an array
          if (not @validator.options[:max]) or @validator.options[:max] > 1
            return [value]
          end
          if @validator.options[:max] and @validator.options[:max] == 1
            return value
          end
          if @validator.options[:min] and @validator.options[:min] > 0
            return [value]
          end
        end
        if not value.kind_of? Array and current_value.kind_of? Array
          raise ArgumentError,
                  "Multiple value objects cannot be replaced for non-array objects"
        end
        if value.kind_of? Array then value else [value] end
      end

      def call(*args)
        options = args[0]
        value = options[:value]
        attr = options[:attr]
        current_value = options[:current_value]
        tvalue = cardinality_transform(attr,value,current_value)
      end
    end
  end
end
