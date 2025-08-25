require 'uri'

module Goo
  module Validators
    class DataType < ValidatorBase
      include Validator
      MAX_URL_LENGTH = 2048

      keys %i[list uri url string integer boolean date_time float]

      error_message ->(_obj) {
        if @value.is_a?(Array)
          "All values in attribute `#{@attr}` must be `#{@type}`"
        else
          "Attribute `#{@attr}` with the value `#{@value}` must be `#{@type}`"
        end
      }

      validity_check ->(_obj) { enforce_type(@type, @value) }

      def initialize(inst, attr, value, type)
        super(inst, attr, value)
        @type = type
      end

      def enforce_type(type, value)
        return true if value.nil?
        return enforce_type_boolean(value) if type == :boolean
        return enforce_type_uri(value)     if [:uri, RDF::URI].include?(type)
        return enforce_type_url(value)     if type == :url
        return value.is_a?(Array)          if type == Array
        return value.all? { |x| x.is_a?(type) } if value.is_a?(Array)

        value.is_a?(type)
      end

      def enforce_type_uri(value)
        return true if value.nil?
        return value.all? { |x| uri?(x) } if value.is_a?(Array)

        uri?(value)
      end

      def enforce_type_url(value)
        return true if value.nil?
        return value.all? { |x| url?(x) } if value.is_a?(Array)

        url?(value)
      end

      def enforce_type_boolean(value)
        if value.is_a?(Array)
          value.all? { |x| boolean?(x) }
        else
          boolean?(value)
        end
      end

      private

      def boolean?(value)
        value.instance_of?(TrueClass) || value.instance_of?(FalseClass)
      end

      def uri?(value)
        value.is_a?(RDF::URI) && value.valid?
      end

      def url?(value)
        s = value.to_s
        return false if s.empty? || s.length > MAX_URL_LENGTH

        uri = URI.parse(s)
        uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
