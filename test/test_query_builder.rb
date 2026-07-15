require_relative 'test_case'

class TestQueryBuilder < Goo::TestCase
  class QueryBuilderProbe < Goo::SPARQL::QueryBuilder
    attr_reader :query

    def initialize
      @query = SPARQL::Client::Query.select(:id)
                                    .where([:id, RDF.type, RDF::URI('http://example.org/Resource')])
    end
  end

  def test_ids_filter_uses_values_instead_of_a_disjunctive_filter
    ids = [RDF::URI('http://example.org/one'), RDF::URI('http://example.org/two')]
    builder = QueryBuilderProbe.new

    with_4store(false) { builder.ids_filter(ids) }

    query = builder.query.to_s
    assert_includes query, 'VALUES (?id) { ( <http://example.org/one> ) ( <http://example.org/two> ) }'
    refute_includes query, 'FILTER'
    refute_includes query, '||'
  end

  def test_ids_filter_keeps_filter_fallback_for_4store
    ids = [RDF::URI('http://example.org/one'), RDF::URI('http://example.org/two')]
    builder = QueryBuilderProbe.new

    with_4store(true) { builder.ids_filter(ids) }

    query = builder.query.to_s
    assert_includes query, 'FILTER(?id = <http://example.org/one> || ?id = <http://example.org/two>)'
    refute_includes query, 'VALUES'
  end

  def test_ids_filter_is_a_no_op_for_an_empty_id_list
    builder = QueryBuilderProbe.new
    query_without_ids = builder.query.to_s

    builder.ids_filter([])

    assert_equal query_without_ids, builder.query.to_s
    refute builder.query.options.key?(:values)
  end

  def test_ids_filter_preserves_percent_encoded_spaces_for_virtuoso
    id = RDF::URI('http://example.org/with space')
    builder = QueryBuilderProbe.new

    with_4store(false) { builder.ids_filter([id]) }

    query = builder.query.to_s
    assert_includes query, '<http://example.org/with%20space>'
    refute_includes query, '\u0020'
    assert_equal 'http://example.org/with space', id.to_s
  end

  def test_ids_filter_keeps_large_id_sets_in_one_values_block
    ids = 500.times.map { |index| RDF::URI("http://example.org/#{index}") }
    builder = QueryBuilderProbe.new

    with_4store(false) { builder.ids_filter(ids) }

    values = builder.query.options.fetch(:values)
    assert_equal [:id], values.first.map(&:name)
    assert_equal ids, values.drop(1).flatten
    assert_equal 1, builder.query.to_s.scan('VALUES').length
  end

  private

  def with_4store(enabled)
    original = Goo.method(:backend_4s?)
    Goo.define_singleton_method(:backend_4s?) { enabled }
    yield
  ensure
    Goo.define_singleton_method(:backend_4s?, original)
  end
end
