require_relative '../test_case'
require 'benchmark'


class TestSolr < MiniTest::Unit::TestCase
  def self.before_suite
    @@connector = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    @@connector.delete_alias('test')
    @@connector.delete_collection('test_v1')
    @@connector.init
  end

  def self.after_suite
    @@connector.delete_alias('test')
    @@connector.delete_collection('test_v1')
  end

  def test_add_collection
    connector = @@connector
    connector.create_collection('test2')
    all_collections = connector.fetch_all_collections
    assert_includes all_collections, 'test2'
  end

  def test_delete_collection
    connector = @@connector
    test_add_collection
    connector.delete_collection('test2')

    all_collections = connector.fetch_all_collections
    refute_includes all_collections, 'test2'
  end

  def test_schema_generator
    connector = @@connector

    all_fields = connector.all_fields

    connector.schema_generator.fields_to_add.each do |f|
      field = all_fields.select { |x| x["name"].eql?(f[:name]) }.first
      refute_nil field
      assert_equal field["type"], f[:type]
      assert_equal field["indexed"], f[:indexed]
      assert_equal field["stored"], f[:stored]
      assert_equal field["multiValued"], f[:multiValued]
    end

    copy_fields = connector.all_copy_fields
    connector.schema_generator.copy_fields_to_add.each do |f|
      field = copy_fields.select { |x| x["source"].eql?(f[:source]) }.first
      refute_nil field
      assert_equal field["source"], f[:source]
      assert_includes f[:dest], field["dest"]
    end

    dynamic_fields = connector.all_dynamic_fields

    connector.schema_generator.dynamic_fields_to_add.each do |f|
      field = dynamic_fields.select { |x| x["name"].eql?(f[:name]) }.first
      refute_nil field
      assert_equal field["name"], f[:name]
      assert_equal field["type"], f[:type]
      assert_equal field["multiValued"], f[:multiValued]
      assert_equal field["stored"], f[:stored]
    end

    connector.clear_all_schema
    connector.fetch_schema
    all_fields = connector.all_fields
    connector.schema_generator.fields_to_add.each do |f|
      field = all_fields.select { |x| x["name"].eql?(f[:name]) }.first
      assert_nil field
    end

    copy_fields = connector.all_copy_fields
    connector.schema_generator.copy_fields_to_add.each do |f|
      field = copy_fields.select { |x| x["source"].eql?(f[:source]) }.first
      assert_nil field
    end

    dynamic_fields = connector.all_dynamic_fields
    connector.schema_generator.dynamic_fields_to_add.each do |f|
      field = dynamic_fields.select { |x| x["name"].eql?(f[:name]) }.first
      assert_nil field
    end
  end

  def test_add_field
    connector = @@connector
    add_field('test', connector)


    field = connector.fetch_all_fields.select { |f| f['name'] == 'test' }.first

    refute_nil field
    assert_equal field['type'], 'string'
    assert_equal field['indexed'], true
    assert_equal field['stored'], true
    assert_equal field['multiValued'], true

    connector.delete_field('test')
  end

  def test_delete_field
    connector = @@connector

    add_field('test', connector)

    connector.delete_field('test')

    field = connector.all_fields.select { |f| f['name'] == 'test' }.first

    assert_nil field
  end

  def test_alias_aware_init
    connector = @@connector

    # init should have created a versioned collection and an alias
    assert connector.collection_exists?('test_v1'), 'Expected test_v1 collection to exist'
    assert connector.alias_exists?('test'), 'Expected test alias to exist'
    assert_equal 'test_v1', connector.resolve_alias('test')
    assert_equal 'test', connector.alias_name
    assert_equal 'test_v1', connector.collection_name
  end

  def test_alias_aware_init_skips_when_alias_exists
    # Create a fresh connector with the same alias name
    connector2 = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    connector2.init

    # Should reuse existing alias and collection, not create test_v1 again
    assert connector2.alias_exists?('test')
    assert_equal 'test_v1', connector2.resolve_alias('test')
    assert_equal 'test_v1', connector2.collection_name
  end

  def test_list_aliases
    connector = @@connector
    # Clean up in case of prior failed run
    connector.delete_alias('test_alias')

    aliases_before = connector.list_aliases
    connector.create_alias('test_alias', 'test_v1')
    aliases_after = connector.list_aliases

    assert_equal aliases_after.size, aliases_before.size + 1
    assert_equal 'test_v1', aliases_after['test_alias']

    connector.delete_alias('test_alias')
  end

  def test_alias_exists
    connector = @@connector
    connector.delete_alias('test_alias')

    refute connector.alias_exists?('test_alias')

    connector.create_alias('test_alias', 'test_v1')
    assert connector.alias_exists?('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_resolve_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    assert_nil connector.resolve_alias('test_alias')

    connector.create_alias('test_alias', 'test_v1')
    assert_equal 'test_v1', connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_create_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', 'test_v1')
    assert connector.alias_exists?('test_alias')
    assert_equal 'test_v1', connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_create_alias_overwrites_existing
    connector = @@connector
    connector.create_collection('test3')
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', 'test_v1')
    assert_equal 'test_v1', connector.resolve_alias('test_alias')

    # CREATEALIAS overwrites atomically — this is the swap mechanism
    connector.create_alias('test_alias', 'test3')
    assert_equal 'test3', connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
    connector.delete_collection('test3')
  end

  def test_delete_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', 'test_v1')
    assert connector.alias_exists?('test_alias')

    connector.delete_alias('test_alias')
    refute connector.alias_exists?('test_alias')
  end

  def test_delete_alias_nonexistent_is_noop
    connector = @@connector
    connector.delete_alias('nonexistent_alias')
    # Should not raise — just returns silently
    refute connector.alias_exists?('nonexistent_alias')
  end

  private

  def add_field(name, connector)
    if connector.fetch_field(name)
      connector.delete_field(name)
    end
    connector.add_field(name, 'string', indexed: true, stored: true, multi_valued: true)
  end
end
