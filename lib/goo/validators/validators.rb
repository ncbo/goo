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
            record.errors[attribute] << \
              (options[:message] || "#{attribute}=#{value} is not an XSD Datetime string")
          end
        rescue ArgumentError => e
          record.errors[attribute] << \
           (options[:message] || "#{attribute}= #{value} is not an XSD Datetime #{e.message}")
        end
      end
    end

    class InstanceOfValidator < Validator 
      def validate_each(record, attribute, value)
        return if value.nil? #other validators will take care of Cardinality.
        vocs = Goo::Naming.get_vocabularies
        values = [value].flatten
        registered_class = nil
        if options[:with].kind_of? Symbol
          if not vocs.is_type_registered?(options[:with])
            raise ArgumentError, "Model #{options[:with]} is not registered."
          end
          registered_class = vocs.get_model_class_for(options[:with])
        else
          registered_class = options[:with]
        end
        values.each do |v|
          if not v.kind_of? registered_class
            record.errors[attribute] << \
             (options[:message] || "#{attribute} contains instances that are not #{options[:with]}")
          end
        end
      end
    end

    class CardinalityValidator < Validator 
      def validate_each(record, attribute, value)
        raise ArgumentError, "CardinalityValidator for #{attribute} needs options :max and/or :minimun." \
          if options.length == 0

        [:max, :minimun].each do |attr|
          raise ArgumentError, "#{attr} has to be a non-negative integer " \
            unless not options[attr] or (options[attr].instance_of?(Fixnum) or options[attr] >= 0)
        end
        
        #presence should catch this validation
        return if value == nil

        if value.kind_of?(Array)
          if (options[:min]  and value.length < options[:min]) or \
              (options[:max]  and value.length > options[:max])
            record.errors[attribute] << \
            (options[:message] || "#{attribute}.length = #{value.length}. It does not satisfy cardinality #{options}")
          end
        else
          #TODO: cardinality check for non-array values. 
          if options[:min] and options[:min] > 1
            record.errors[attribute] << \
            (options[:message] || "#{attribute}.length = #{value.length}. It does not satisfy cardinality #{options}")
          end
        end
      end
    end 
  end
end
