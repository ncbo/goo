module Goo
  module Validators
    class SafeText < ValidatorBase
      include Validator

      SAFE_TEXT_REGEX = /\A[\p{L}\p{N} .,'\-@()&!$%\/\[\]:;*+=?#^_{}|~"]+\z/u.freeze
      DISALLOWED_UNICODE = /[\u0000-\u001F\u007F\u00A0\u200B-\u200F\u2028-\u202F\u202E\u2066-\u2069]/u.freeze

      key :safe_text

      error_message ->(obj) {
        # Truncate long string values for clarity
        truncated_value = if @value.is_a?(String) && @value.length > 60
                            "#{@value[0...57]}..."
                          else
                            @value
                          end

        prefix = if @value.is_a?(Array)
                   "All values in attribute `#{@attr}`"
                 else
                   "Attribute `#{@attr}` with the value `#{truncated_value}`"
                 end

        suffix = "must be safe text (no control or invisible Unicode characters, newlines, or disallowed punctuation)"
        length_note = @max_length ? " and must not exceed #{@max_length} characters" : ""

        "#{prefix} #{suffix}#{length_note}"
      }

      validity_check ->(obj) do
        return true if @value.nil?

        Array(@value).all? do |val|
          next false unless val.is_a?(String)

          length_ok = @max_length.nil? || val.length <= @max_length
          length_ok &&
            val !~ /\R/ &&
            val =~ SAFE_TEXT_REGEX &&
            val !~ DISALLOWED_UNICODE
        end
      end

      def initialize(inst, attr, value, opt)
        @max_length = nil
        super(inst, attr, value)
        match = opt.match(/_(\d+)$/)
        @max_length = match[1].to_i if match && match[1]
      end

    end
  end
end