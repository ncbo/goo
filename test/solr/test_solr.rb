require_relative '../test_case'
require 'benchmark'


class TestSolr < MiniTest::Unit::TestCase
  def self.before_suite
    @@connector = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    @@connector.delete_alias('test_alias')
    @@connector.delete_collection('test')
    @@connector.delete_collection('test2')
    @@connector.delete_collection('test3')
    @@connector.delete_collection('test_reindex')
    @@connector.delete_collection('test_existing_bootstrap')
    @@connector.delete_collection('test_schema_generator')
    @@connector.init
  end

  def self.after_suite
    @@connector.delete_alias('test_alias')
    @@connector.delete_collection('test')
    @@connector.delete_collection('test2')
    @@connector.delete_collection('test3')
    @@connector.delete_collection('test_reindex')
    @@connector.delete_collection('test_existing_bootstrap')
    @@connector.delete_collection('test_schema_generator')
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

  def test_alias_lifecycle
    connector = @@connector
    connector.create_collection('test2')
    connector.create_collection('test3')

    connector.create_or_update_alias('test_alias', 'test2')

    assert connector.alias_exists?('test_alias')
    assert_equal ['test2'], connector.resolve_alias('test_alias')

    connector.create_or_update_alias('test_alias', %w[test2 test3])

    assert_equal %w[test2 test3], connector.resolve_alias('test_alias')

    connector.delete_alias('test_alias')

    refute connector.alias_exists?('test_alias')
    assert_equal [], connector.resolve_alias('test_alias')
  end

  def test_create_reindex_collection_initializes_physical_collection
    connector = @@connector
    connector.delete_collection('test_reindex')

    connector.create_reindex_collection('test_reindex')

    assert connector.collection_exists?('test_reindex')
    assert_equal 'test', connector.collection_name
  ensure
    connector.delete_collection('test_reindex')
  end

  def test_missing_alias_uses_existing_bootstrap_without_reinitializing_schema
    connector = @@connector
    alias_name = 'test_alias'
    bootstrap_collection = 'test_existing_bootstrap'
    connector.delete_alias(alias_name)
    connector.delete_collection(bootstrap_collection)
    connector.create_collection(bootstrap_collection)

    before_dynamic_fields = nil
    connector.send(:with_collection, bootstrap_collection) do
      before_dynamic_fields = connector.fetch_all_dynamic_fields.map { |f| f['name'] }
    end

    alias_connector = SOLR::SolrConnector.new(Goo.search_conf, alias_name)
    alias_connector.init(false, bootstrap_collection: bootstrap_collection)

    assert_equal [bootstrap_collection], connector.resolve_alias(alias_name)

    after_dynamic_fields = nil
    connector.send(:with_collection, bootstrap_collection) do
      after_dynamic_fields = connector.fetch_all_dynamic_fields.map { |f| f['name'] }
    end

    assert_equal before_dynamic_fields, after_dynamic_fields
  ensure
    connector.delete_alias(alias_name) if connector
    connector.delete_collection(bootstrap_collection) if connector
  end

  def test_promote_alias_preserves_old_collection
    connector = @@connector
    connector.delete_alias('test_alias')
    connector.delete_collection('test2')
    connector.delete_collection('test3')
    connector.create_collection('test2')
    connector.create_collection('test3')
    connector.create_or_update_alias('test_alias', 'test2')

    old_collection = connector.promote_alias('test3', alias_name: 'test_alias')

    assert_equal 'test2', old_collection
    assert_equal ['test3'], connector.resolve_alias('test_alias')
    assert connector.collection_exists?('test2')
  ensure
    connector.delete_alias('test_alias')
    connector.delete_collection('test2')
    connector.delete_collection('test3')
  end

  def test_swap_alias_and_delete_old_removes_previous_collection
    connector = @@connector
    connector.delete_alias('test_alias')
    connector.delete_collection('test2')
    connector.delete_collection('test3')
    connector.create_collection('test2')
    connector.create_collection('test3')
    connector.create_or_update_alias('test_alias', 'test2')

    connector.swap_alias_and_delete_old('test3', alias_name: 'test_alias')

    assert_equal ['test3'], connector.resolve_alias('test_alias')
    refute connector.collection_exists?('test2')
  ensure
    connector.delete_alias('test_alias')
    connector.delete_collection('test2')
    connector.delete_collection('test3')
  end

  def test_schema_generator
    collection_name = "test_schema_generator_#{Time.now.to_i}_#{rand(10_000)}"
    connector = SOLR::SolrConnector.new(Goo.search_conf, collection_name)
    connector.init
    wait_for_generated_schema(connector)

    begin
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
      wait_for_generated_schema_removal(connector)
      all_fields = connector.all_fields
      connector.schema_generator.fields_to_add.each do |f|
        next if %w[id _version_ _text_].include?(f[:name].to_s)

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
    ensure
      connector.delete_collection(collection_name)
    end
  end

  def test_add_field
    connector = @@connector
    add_field('test', connector)
    wait_for_field(connector, 'test')


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
    wait_for_field(connector, 'test')

    connector.delete_field('test')
    wait_for_field_removal(connector, 'test')

    field = connector.fetch_all_fields.select { |f| f['name'] == 'test' }.first

    assert_nil field
  end

  private

  def wait_for_generated_schema(connector, timeout: 5)
    wait_until(timeout: timeout) do
      field_names = connector.fetch_all_fields.map { |f| f['name'] }
      copy_sources = connector.fetch_all_copy_fields.map { |f| f['source'] }
      dynamic_names = connector.fetch_all_dynamic_fields.map { |f| f['name'] }

      connector.schema_generator.fields_to_add.all? { |f| field_names.include?(f[:name].to_s) } &&
        connector.schema_generator.copy_fields_to_add.all? { |f| copy_sources.include?(f[:source].to_s) } &&
        connector.schema_generator.dynamic_fields_to_add.all? { |f| dynamic_names.include?(f[:name].to_s) }
    end
  end

  def wait_for_generated_schema_removal(connector, timeout: 5)
    wait_until(timeout: timeout) do
      field_names = connector.fetch_all_fields.map { |f| f['name'] }
      copy_sources = connector.fetch_all_copy_fields.map { |f| f['source'] }
      dynamic_names = connector.fetch_all_dynamic_fields.map { |f| f['name'] }

      connector.schema_generator.fields_to_add.none? { |f| field_names.include?(f[:name].to_s) } &&
        connector.schema_generator.copy_fields_to_add.none? { |f| copy_sources.include?(f[:source].to_s) } &&
        connector.schema_generator.dynamic_fields_to_add.none? { |f| dynamic_names.include?(f[:name].to_s) }
    end
  end

  def wait_for_field(connector, name, timeout: 5)
    wait_until(timeout: timeout) { connector.fetch_field(name) }
  end

  def wait_for_field_removal(connector, name, timeout: 5)
    wait_until(timeout: timeout) { connector.fetch_field(name).nil? }
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    result = yield
    until result || Time.now >= deadline
      sleep 0.2
      result = yield
    end
    result
  end

  def add_field(name, connector)
    if connector.fetch_field(name)
      connector.delete_field(name)
    end
    connector.add_field(name, 'string', indexed: true, stored: true, multi_valued: true)
  end
end
