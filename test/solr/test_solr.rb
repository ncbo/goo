require_relative '../test_case'
require 'benchmark'


class TestSolr < MiniTest::Unit::TestCase
  BOOTSTRAP_COLLECTION = 'test_bootstrap'

  def self.before_suite
    @@connector = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    @@connector.delete_alias('test')
    @@connector.delete_collection(BOOTSTRAP_COLLECTION)
    @@connector.delete_collection('test_reindex')
    @@connector.init(bootstrap_collection: BOOTSTRAP_COLLECTION)
  end

  def self.after_suite
    @@connector.delete_alias('test')
    @@connector.delete_collection(BOOTSTRAP_COLLECTION)
    @@connector.delete_collection('test_reindex')
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

    # init should have created the bootstrap collection and an alias
    assert connector.collection_exists?(BOOTSTRAP_COLLECTION), "Expected #{BOOTSTRAP_COLLECTION} collection to exist"
    assert connector.alias_exists?('test'), 'Expected test alias to exist'
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test')
    assert_equal 'test', connector.alias_name
    assert_equal BOOTSTRAP_COLLECTION, connector.collection_name
    assert connector.aliased?, 'Connector should be in aliased mode'
  end

  def test_alias_aware_init_skips_when_alias_exists
    # Create a fresh connector with the same alias name
    connector2 = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    connector2.init(bootstrap_collection: 'should_not_be_created')

    # Should reuse existing alias and collection, not create a new one
    assert connector2.alias_exists?('test')
    assert_equal BOOTSTRAP_COLLECTION, connector2.resolve_alias('test')
    assert_equal BOOTSTRAP_COLLECTION, connector2.collection_name
    refute connector2.collection_exists?('should_not_be_created')
  end

  def test_init_without_bootstrap_creates_plain_collection
    # When no bootstrap_collection is given, alias_name == bootstrap_name,
    # so it creates a plain collection (no alias)
    connector2 = SOLR::SolrConnector.new(Goo.search_conf, 'test_plain')
    connector2.init

    assert connector2.collection_exists?('test_plain')
    refute connector2.alias_exists?('test_plain'), 'Should not create an alias when names match'
    refute connector2.aliased?, 'Connector should not be in aliased mode'

    connector2.delete_collection('test_plain')
  end

  def test_list_aliases
    connector = @@connector
    # Clean up in case of prior failed run
    connector.delete_alias('test_alias')

    aliases_before = connector.list_aliases
    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
    aliases_after = connector.list_aliases

    assert_equal aliases_after.size, aliases_before.size + 1
    assert_equal BOOTSTRAP_COLLECTION, aliases_after['test_alias']

    connector.delete_alias('test_alias')
  end

  def test_alias_exists
    connector = @@connector
    connector.delete_alias('test_alias')

    refute connector.alias_exists?('test_alias')

    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
    assert connector.alias_exists?('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_resolve_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    assert_nil connector.resolve_alias('test_alias')

    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_create_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
    assert connector.alias_exists?('test_alias')
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
  end

  def test_create_alias_overwrites_existing
    connector = @@connector
    connector.create_collection('test3')
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test_alias')

    # CREATEALIAS overwrites atomically — this is the swap mechanism
    connector.create_alias('test_alias', 'test3')
    assert_equal 'test3', connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')
    connector.delete_collection('test3')
  end

  def test_delete_alias
    connector = @@connector
    connector.delete_alias('test_alias')

    connector.create_alias('test_alias', BOOTSTRAP_COLLECTION)
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

  def test_create_reindex_collection
    connector = @@connector

    new_name = connector.create_reindex_collection('test_reindex')
    assert_equal 'test_reindex', new_name
    assert connector.collection_exists?('test_reindex')

    # Alias should still point to the bootstrap collection
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test')
    assert_equal BOOTSTRAP_COLLECTION, connector.collection_name

    connector.delete_collection('test_reindex')
  end

  def test_create_reindex_collection_requires_name
    connector = @@connector

    assert_raises(ArgumentError) { connector.create_reindex_collection(nil) }
    assert_raises(ArgumentError) { connector.create_reindex_collection('') }
  end

  def test_reindex_not_available_without_alias
    plain_connector = SOLR::SolrConnector.new(Goo.search_conf, 'test_plain2')
    plain_connector.init

    assert_raises(RuntimeError) { plain_connector.create_reindex_collection('some_name') }
    assert_raises(RuntimeError) { plain_connector.swap_alias_and_delete_old('some_name') }

    plain_connector.delete_collection('test_plain2')
  end

  def test_create_reindex_collection_rejects_existing
    connector = @@connector

    assert_raises(ArgumentError) do
      connector.create_reindex_collection(BOOTSTRAP_COLLECTION)
    end
  end

  def test_swap_alias_and_delete_old
    connector = @@connector

    # Create a reindex collection
    connector.create_reindex_collection('test_reindex')
    assert connector.collection_exists?('test_reindex')
    assert connector.collection_exists?(BOOTSTRAP_COLLECTION)

    # Swap alias and delete old
    connector.swap_alias_and_delete_old('test_reindex')

    assert_equal 'test_reindex', connector.resolve_alias('test')
    assert_equal 'test_reindex', connector.collection_name
    refute connector.collection_exists?(BOOTSTRAP_COLLECTION), 'Old collection should have been deleted'

    # Restore state for other tests: create bootstrap again and swap back
    connector.create_reindex_collection(BOOTSTRAP_COLLECTION)
    connector.swap_alias_and_delete_old(BOOTSTRAP_COLLECTION)
    assert_equal BOOTSTRAP_COLLECTION, connector.resolve_alias('test')
  end

  private

  def add_field(name, connector)
    if connector.fetch_field(name)
      connector.delete_field(name)
    end
    connector.add_field(name, 'string', indexed: true, stored: true, multi_valued: true)
  end
end
