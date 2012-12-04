module Goo
  module Validators

    class Validator
      attr_reader :options

      def initialize(options)
        @options = options
      end

      def self.inherited(validator)
        name = validator.name.split("::")[-1].underscore
        if name.end_with? "_validator"
          name = name[0..-11]
        end
        Goo.register_validator name.to_sym, validator
      end

    end

    class DateTimeXsdValidator < Validator
      def validate_each(record, attribute, value)
        begin
          #why do I need module here.
          datetime = Goo::Utils.xsd_date_time_parse(value)
          if not datetime
            record.internals.errors[attribute] << \
              (options[:message] || "#{attribute}=#{value} is not an XSD Datetime string")
          end
        rescue ArgumentError => e
          record.internals.errors[attribute] << \
           (options[:message] || "#{attribute}= #{value} is not an XSD Datetime #{e.message}")
        end
      end
    end

    class InstanceOfValidator < Validator
      def validate_each(record, attribute, value)
        return if value.nil? #other validators will take care of Cardinality.
        values = [value].flatten
        registered_class = nil
        if options[:with].kind_of? Symbol
          classes = Goo.models.select { |m| m.goo_name == options[:with] }
          unless classes.length > 0
            raise ArgumentError, "Model #{options[:with]} is not registered."
          end
          unless classes.length == 1
            raise ArgumentError, "Model #{options[:with]} is registered for more than one model."
          end
          registered_class = classes[0]
        else
          registered_class = options[:with]
        end
        values.each do |v|
          if not v.kind_of? registered_class
            record.internals.errors[attribute] << \
             (options[:message] || "#{attribute} contains instances that are not #{options[:with]}")
          end
        end
      end
    end

    class UniqueValidator < Validator
      def validate_each(record, attribute, value)
        if value.nil?
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute} must contain a value.")
            return
        end
        if value.kind_of? Array and value.length > 1
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute} must contain one single value.")
        elsif value.kind_of? Array and value.length == 0
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute} must contain a value.")
        else
          value = value[0]
        end

        if (record.exist?(reload=true) and not record.internals.persistent)
            record.internals.errors[attribute] << \
            (options[:message] ||  "Object cannot be saved." +
            " Resource '#{@_id}' exist in the store and cannot be replaced")
        end
      end
    end

    class CardinalityValidator < Validator
      def validate_each(record, attribute, value)
        raise ArgumentError, "CardinalityValidator for #{attribute} needs options :max and/or :min." \
          if options.length == 0

        [:max, :min].each do |attr|
          raise ArgumentError, "#{attr} has to be a non-negative integer " \
            unless not options[attr] or (options[attr].instance_of?(Fixnum) or options[attr] >= 0)
        end
        if value.nil? and options[:min] and options[:min] > 0
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute} is nil. It does not satisfy cardinality #{options}")
        elsif value.kind_of?(Array)
          if (options[:min]  and value.length < options[:min]) or \
              (options[:max]  and value.length > options[:max])
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute}.length = #{value.length}. It does not satisfy cardinality #{options}")
          end
        else
          #TODO: cardinality check for non-array values.
          if options[:min] and options[:min] > 1
            record.internals.errors[attribute] << \
            (options[:message] || "#{attribute}.length = #{value.length}. It does not satisfy cardinality #{options}")
          end
        end
      end
    end
  end
end
