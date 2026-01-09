require_relative 'test_case.rb'

module Goo
  module Validators
    class TestEmail < MiniTest::Unit::TestCase

      def dummy_instance
        @dummy ||= Object.new
      end

      def validate(value)
        Email.new(dummy_instance, :email, value)
      end

      def assert_valid(value)
        validator = validate(value)
        assert validator.valid?, "Expected #{value.inspect} to be valid"
      end

      def assert_invalid(value)
        validator = validate(value)
        refute validator.valid?, "Expected #{value.inspect} to be invalid"
      end

      def test_valid_emails
        assert_valid nil
        assert_valid "user@example.com"
        assert_valid "john.doe+test@sub.domain.org"
        assert_valid "a_b-c@foo-bar.co.uk"
        assert_valid "user123@domain.io"
      end

      def test_invalid_emails_structure
        assert_invalid ""
        assert_invalid "plainaddress"
        assert_invalid "user@localhost"
        assert_invalid "user@com"
        assert_invalid "user@.com"
        assert_invalid "user@com."
        assert_invalid "user@-domain.com"
        assert_invalid "user@domain-.com"
        assert_invalid "user.@example.com"
        assert_invalid "user..user@example.com"
        assert_invalid "user@domain..com"
        assert_invalid "user@"
      end

      def test_email_length_limits
        too_short = "a@b.c"  # 5 chars
        assert_invalid too_short

        long_local = "a" * 65
        assert_invalid "#{long_local}@example.com"

        long_domain = ("a" * 63 + ".") * 4 + "com"
        assert_invalid "user@#{long_domain}"

        too_long = "#{'a'*64}@#{'b'*189}.com"  # 258 chars
        assert_invalid too_long
      end

      def test_array_with_all_valid_emails
        validator = validate(["valid@example.com", "foo.bar@domain.co"])
        assert validator.valid?
      end

      def test_array_with_one_invalid_email
        validator = validate(["good@domain.com", "bad@domain..com"])
        refute validator.valid?
      end

      def test_error_message_for_single_invalid_email
        validator = validate("invalid-email")
        refute validator.valid?
        assert_match(/must be a valid email address/i, validator.error)
      end

      def test_error_message_for_array_with_invalid
        validator = validate(["invalid@", "also@bad"])
        refute validator.valid?
        assert_match(/All values.*must be valid email addresses/i, validator.error)
      end
    end
  end
end