# Opt-in test helpers for asserting SPARQL query budgets. NOT auto-loaded by goo -- a test suite
# requires this file and includes Goo::TestHelpers into its Minitest test base:
#
#   require 'goo/test_helpers'
#   class MyTestCase < Minitest::Test
#     include Goo::TestHelpers
#   end
#
# The query count is deterministic for a given code path + fixture data (unlike wall time), so
# these catch N+1 / query-fan-out regressions identically on a laptop and in CI. Backed by
# Goo.count_sparql_queries (lib/goo.rb), which counts store-bound SPARQL round-trips -- cache
# hits don't count. Relies on the including class providing Minitest's assert/assert_equal.
module Goo
  module TestHelpers
    # Assert the block issues no more than `max` store-bound SPARQL queries. Returns the count.
    def assert_max_sparql_queries(max, msg = nil)
      count = Goo.count_sparql_queries { yield }
      assert count <= max,
             msg || "expected at most #{max} SPARQL queries, got #{count}"
      count
    end

    # Assert the block issues exactly `expected` store-bound SPARQL queries. Returns the count.
    def assert_sparql_queries(expected, msg = nil)
      count = Goo.count_sparql_queries { yield }
      assert_equal expected, count,
                   msg || "expected #{expected} SPARQL queries, got #{count}"
      count
    end
  end
end
