
module Goo
  module Validators
    module Enforce

      class EnforceInstance
        attr_reader :errors_by_opt
        def initialize
          @errors_by_opt = {}
        end

        def enforce(inst,attr,value)
          enforce_opts = enforce_by_attribute(inst.class,attr)
          return nil if enforce_opts.nil? or enforce_opts.length == 0

          enforce_opts.each do |opt|
            case opt
            when :unique
              check Goo::Validators::Unique, inst, attr, value, opt
            when :no_list
              validator = Goo::Validators::DataType.new(inst, attr, value, Array)
              if validator.valid? && !value.nil?
                add_error(opt,
                          "`#{attr}` is defined as non Array - it cannot hold multiple values")
              end
            when :existence
              check Goo::Validators::Existence, inst, attr, value, opt
            when :list, Array
              check Goo::Validators::DataType, inst, attr, value,opt, Array
            when :uri, RDF::URI
              check Goo::Validators::DataType, inst, attr, value,opt, RDF::URI
            when :string, String
              check Goo::Validators::DataType, inst, attr, value,opt, String
            when :integer, Integer
              check Goo::Validators::DataType, inst, attr, value,opt, Integer
            when :boolean
              check Goo::Validators::DataType, inst, attr, value, opt,:boolean
            when :date_time, DateTime
              check Goo::Validators::DataType, inst, attr, value, opt, DateTime
            when :float, Float
              check Goo::Validators::DataType, inst, attr, value, opt, Float
            when :symmetric
              check Goo::Validators::Symmetric, inst, attr, value, opt
            when :email
              check Goo::Validators::Email, inst, attr, value, opt
            when /^distinct_of_/
              check Goo::Validators::DistinctOf, inst, attr, value, opt, opt
            when /^superior_equal_to_/
              check Goo::Validators::SuperiorEqualTo, inst, attr, value, opt, opt
            when /^inverse_of_/
              check Goo::Validators::InverseOf, inst, attr, value, opt, opt
            when Proc
              call_proc(opt, inst, attr)
            when /^max_/, /^min_/
              type = opt.to_s.index("max_") ? :max : :min
              check Goo::Validators::ValueRange, inst, attr, value, type, opt.to_s
            else
              if object_type?(opt)
                check_object_type inst, attr, value, opt
              elsif instance_proc?(inst, opt)
                call_proc(inst.method(opt), inst, attr)
              end
            end
          end

          errors_by_opt.length > 0 ? errors_by_opt : nil
        end

        def enforce_callback(inst, attr)
          callbacks = Array(inst.class.update_callbacks(attr))
          callbacks.each do |proc|
            if instance_proc?(inst, proc)
              call_proc(inst.method(proc), inst, attr)
            elsif proc.is_a?(Proc)
              call_proc(proc, inst, attr)
            end
          end
        end

        private

        def object_type(opt)
          opt.respond_to?(:shape_attribute) ? opt : Goo.model_by_name(opt)
        end

        def object_type?(opt)
          opt.respond_to?(:shape_attribute) ? opt : Goo.model_by_name(opt)
        end

        def instance_proc?(inst, opt)
          opt && (opt.is_a?(Symbol) || opt.is_a?(String)) && inst.respond_to?(opt)
        end

        def check_object_type(inst, attr, value, opt)
          model_range = object_type(opt)
          if model_range && !value.nil?
            check Goo::Validators::ObjectType, inst, attr, value, model_range.model_name, model_range
          end
        end

        def check(validator_class, inst, attr, value, opt, *options)
          validator = validator_class.new(inst, attr, value, *options)
          add_error(opt, validator.error) unless validator.valid?
        end
        def enforce_by_attribute(model, attr)
           model.model_settings[:attributes][attr][:enforce]
        end

        def call_proc(proc,inst, attr)
          # This should return an array like [:name_of_error1, "Error message 1", :name_of_error2, "Error message 2"]
          errors = proc.call(inst, attr)

          return unless !errors.nil? && errors.is_a?(Array)

          errors.each_slice(2) do |e|
            next if e.nil? || e.compact.empty?
            add_error(e[0].to_sym, e[1])
          end
        end

        def add_error(opt, err)
          return if err.nil?
          @errors_by_opt[opt] = err
        end
      end


      def self.enforce(inst,attr,value)
        EnforceInstance.new.enforce(inst,attr,value)
      end

      def self.enforce_callbacks(inst, attr)
        EnforceInstance.new.enforce_callback(inst, attr)
      end
    end
  end
end
