require_relative 'test_case'
require_relative 'models'

class TestLogging < Goo::TestCase

  def before_all
    GooTestData.create_test_case_data
    Goo.use_cache = true
    Goo.redis_client.flushdb
    Goo.add_query_logger(enabled: true, file: "test.log")
  end

  def after_all
    GooTestData.delete_test_case_data
    Goo.add_query_logger(enabled: false, file: nil)
    File.delete("test.log") if File.exist?("test.log")
    Goo.redis_client.flushdb
    Goo.use_cache = false
  end

  def setup
    Goo.redis_client.flushdb
  end

  def test_logging
    Goo.logger.info("Test logging")
    University.all
    recent_logs = Goo.logger.get_logs
    assert_equal 2, recent_logs.length
    assert recent_logs.any? { |x| x['query'].include?("Test logging") }
    assert File.read("test.log").include?("Test logging")
  end

  def test_last_10s_logs
    Goo.logger.info("Test logging 2")
    University.all
    recent_logs = Goo.logger.queries_last_n_seconds(10)
    assert_equal 2, recent_logs.length
    assert recent_logs.any? { |x| x['query'].include?("Test logging 2") }
    assert File.read("test.log").include?("Test logging 2")
    sleep 1
    recent_logs = Goo.logger.queries_last_n_seconds(0)
    assert_equal 0, recent_logs.length
  end

  def test_auto_clean_logs
    Goo.logger.info("Test logging 3")
    (1..3000).each do |_i|
      University.all
    end
    recent_logs = Goo.logger.get_logs
    assert recent_logs.length < 2000
  end
end
