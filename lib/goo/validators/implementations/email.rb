module Goo
  module Validators
    class Email < ValidatorBase
      include Validator
      DOMAIN_LABEL = /(?!-)[a-z0-9-]{1,63}(?<!-)/
      TLD_LABEL = /(?:[a-z]{2,}|xn--(?!-)[a-z0-9-]{1,59}(?<!-))/

      # Matches reasonably valid ASCII email addresses.
      # This validator intentionally does not support non-ASCII local parts or Unicode domains;
      # internationalized domains must be provided in ASCII punycode form.
      EMAIL_REGEXP = /\A
      [a-z0-9!#$%&'*+\/=?^_`{|}~-]+             # local part
      (?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*       # dot-separated continuation in local
      @
      (?:#{DOMAIN_LABEL}\.)+                     # domain labels
      #{TLD_LABEL}                               # top-level domain or punycode TLD
      \z/ix

      MIN_LENGTH = 6       # Smallest valid email: a@b.cd
      MAX_LENGTH = 254     # RFC 5321 limits email length to 254 characters
      LOCAL_PART_MAX = 64  # Per RFC
      DOMAIN_PART_MAX = 253

      key :email

      error_message ->(obj) {
        if @value.kind_of? Array
          return "All values in attribute `#{@attr}` must be valid email addresses"
        else
          return "Attribute `#{@attr}` with the value `#{@value}` must be a valid email address"
        end
      }

      private

      validity_check ->(obj) do
        return true if @value.nil?

        values = @value.is_a?(Array) ? @value : [@value]

        values.all? do |email|
          next false unless email.is_a?(String)
          next false unless email.length.between?(MIN_LENGTH, MAX_LENGTH)

          local, domain = email.split('@', 2)
          next false if local.nil? || domain.nil?
          next false if local.length > LOCAL_PART_MAX || domain.length > DOMAIN_PART_MAX

          email.match?(EMAIL_REGEXP)
        end
      end
    end
  end
end
