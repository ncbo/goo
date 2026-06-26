module Goo
  module Validators
    class Username < ValidatorBase
      include Validator

      RESERVED_NAMES = %w[
        root support system test guest owner user
        webmaster help contact host mail ftp info api noc security
      ].freeze

      USERNAME_LENGTH_RANGE = (3..32).freeze

      ASCII_ONLY_REGEX = /\A[\x20-\x7E]+\z/
      USERNAME_PATTERN = /\A[a-zA-Z](?!.*[._]{2})[a-zA-Z0-9._]{1,30}[a-zA-Z0-9]\z/
      INVISIBLE_CHARS = /[\u200B-\u200D\uFEFF]/

      key :username

      error_message ->(obj) {
        base_msg = if @value.is_a?(Array)
                     "All values in attribute `#{@attr}` must be valid usernames"
                   else
                     "Attribute `#{@attr}` with the value `#{@value}` must be a valid username"
                   end
        "#{base_msg} (must be 3–32 chars, start with a letter, contain only ASCII letters/digits/dots/underscores, no invisible or reserved terms)"
      }

      validity_check ->(obj) do
        return true if @value.nil?

        Array(@value).all? do |username|
          next false unless username.is_a?(String)
          next false unless username == username.strip

          USERNAME_LENGTH_RANGE.cover?(username.length) &&
            username.match?(ASCII_ONLY_REGEX) &&
            username.match?(USERNAME_PATTERN) &&
            !username.match?(INVISIBLE_CHARS) &&
            !RESERVED_NAMES.include?(username.downcase)
        end
      end
    end
  end
end
