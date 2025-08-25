require_relative 'test_case'
require 'goo/validators/validator'
require 'goo/validators/implementations/data_type'
require 'rdf'

class UrlTestModel < Goo::Base::Resource
  model :url_test_model, name_with: :name
  attribute :url, enforce: %i[url]
  attribute :urls, enforce: %i[list url]
end

class UrlValidatorTest < Minitest::Unit::TestCase
  def test_url_scalar
    u = UrlTestModel.new
    u.url = RDF::URI.new('https://example.com/path?x=1')
    assert u.valid?, "expected https URL to be valid, got errors: #{u.errors.inspect}"

    u.url = [RDF::URI.new('https://example.com/path?x=1')]
    refute u.valid?, "expected to reject array, got errors: #{u.errors.inspect}"
    assert u.errors[:url][:no_list], "errors: #{u.errors.inspect}"
  end

  def test_url_scalar_rejects_non_http_schemes
    [
      '', 'http://', 'wrong/uri', 'mailto:user@nodomain.org', 'ftp://test.com/',
      'urn:isbn:123456', 'ssh://root@localhost:22', 'file:///etc/passwd',
      'http://', 'http://[::gggg]',
      '//example.org/path',
      "https://example.com/too_long_url/#{'a' * 2050}"
    ].each do |bad|
      u = UrlTestModel.new
      u.url = RDF::URI.new(bad)
      refute u.valid?, "expected invalid for #{bad.inspect}"
      assert u.errors[:url][:url], "expected :url error key for #{bad.inspect}"
    end
  end

  def test_url_list
    u = UrlTestModel.new
    u.urls = [RDF::URI.new('http://example.com/'),
              RDF::URI.new('https://example2.com/ok')]
    assert u.valid?, "expected valid list of URLs, got: #{u.errors.inspect}"

    u.urls = [RDF::URI.new('https://example.com/')]
    assert u.valid?

    u.urls = RDF::URI.new('http://example.com/')
    refute u.valid?
    assert u.errors[:urls]
  end

  def test_url_list_must_all_be_valid
    u = UrlTestModel.new
    u.urls = [RDF::URI.new('https://ok.example'),
              RDF::URI.new('mailto:bad@example.org')]
    refute u.valid?
    assert u.errors[:urls][:url]

    u.urls = [RDF::URI.new('https://ok.example'), true]
    refute u.valid?
    assert u.errors[:urls][:url]
  end
end
