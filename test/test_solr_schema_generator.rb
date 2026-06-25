require 'minitest/autorun'

require_relative '../lib/goo/search/solr/solr_schema_generator'

class TestSolrSchemaGenerator < Minitest::Test
  def setup
    @types = SOLR::SolrSchemaGenerator.new.field_types_to_add
  end

  def find_type(name)
    @types.find { |t| t[:name] == name }
  end

  def test_string_ci_exact_type_exists
    refute_nil find_type('string_ci_exact'),
               'expected a string_ci_exact field type to be defined'
  end

  def test_string_ci_exact_omits_term_freq_and_positions
    assert_equal true, find_type('string_ci_exact')[:omitTermFreqAndPositions],
                 'string_ci_exact must set omitTermFreqAndPositions for binary scoring'
  end

  def test_string_ci_exact_mirrors_string_ci_analysis
    sci  = find_type('string_ci')
    scie = find_type('string_ci_exact')
    assert_equal sci[:class], scie[:class]
    assert_equal sci[:omitNorms], scie[:omitNorms]
    assert_equal sci[:sortMissingLast], scie[:sortMissingLast]
    assert_equal sci[:queryAnalyzer], scie[:queryAnalyzer]
  end

  def test_baseline_string_ci_unchanged
    assert_nil find_type('string_ci')[:omitTermFreqAndPositions],
               'string_ci must NOT become binary; only the dedicated type does'
  end
end
