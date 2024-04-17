module Goo
  module Validators

    class ValidatorBase

      def initialize(inst, attr, value)
        @inst = inst
        @attr = attr
        @value = value
      end

      def valid?
        self.instance_eval(&self.class.validator_settings[:check])
      end

      def error
        message =  self.class.validator_settings[:message]
        if message.is_a? Proc
          self.instance_eval(&message)
        else
          message
        end
      end

    end

    module Validator

      def self.included(base)
        base.extend(ClassMethods)
      end


      module ClassMethods

        def key(id)
          validator_settings[:id] = id
        end

        def keys(ids)
          key ids
        end

        def validity_check(block)
          validator_settings[:check] = block
        end

        def error_message(message)
          validator_settings[:message] = message
        end

        def validator_settings
          @validator_settings ||= {}
        end

        def ids
          Array(validator_settings[:id])
        end

        def property(key)
          key[ids.first.size..key.size].to_sym
        end

        def respond_to?(attr, object)
          object && object.respond_to?(attr)
        end


        def equivalent_value?(object1, object2)
          if object1.respond_to?(:id) && object2.respond_to?(:id)
            object1.id.eql?(object2.id)
          else
            object2 == object1
          end
        end

        def attr_value(attr, object)
          object.bring attr if object.respond_to?(:bring?) && object.bring?(attr)

          Array(object.send(attr))
        end

        def empty_value?(value)
          value.nil? || empty?(value) || empty_array?(value)
        end
        def empty?(value)
          empty_string?(value) || empty_to_s?(value)
        end
        def empty_string?(string)
          string.is_a?(String) && string.strip.empty?
        end

        def empty_to_s?(object)
          begin
            object && object.to_s&.strip.empty?
          rescue
            return false
          end
        end

        def empty_array?(array)
          array.is_a?(Array) && array && array.reject{|x|  x.nil? || empty?(x)}.empty?
        end
      end





    end
  end
end

