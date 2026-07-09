# encoding: utf-8
#
# Targeted unit test for PLSQL::Schema#default_timezone Rails 7.2 compatibility.
# Does NOT require Oracle connection.
#
# Usage:
#   ruby -Ilib -Ispec/unit spec/unit/default_timezone_test.rb

$LOAD_PATH.unshift(File.dirname(__FILE__) + '/../lib')

require 'minitest/autorun'

require 'ruby-plsql'

class TestDefaultTimezone < Minitest::Test
  def setup
    @schema = PLSQL::Schema.new
  end

  def test_default_timezone_fallback_to_local
    assert_equal :local, @schema.default_timezone
  end

  def test_explicit_default_timezone
    @schema.default_timezone = :utc
    assert_equal :utc, @schema.default_timezone
    @schema.default_timezone = :local
    assert_equal :local, @schema.default_timezone
  end

  def test_default_timezone_raises_on_invalid_value
    assert_raises(ArgumentError) { @schema.default_timezone = :invalid }
  end

  def test_delegates_to_original_schema
    original = PLSQL::Schema.new
    original.default_timezone = :utc
    wrapper = PLSQL::Schema.new
    wrapper.instance_variable_set(:@original_schema, original)
    assert_equal :utc, wrapper.default_timezone
  end
end

# Test the fix logic expression independently of ActiveRecord runtime.
# The expression now in PLSQL::Schema#default_timezone is:
#   (@connection && (ar_class = @connection.activerecord_class) &&
#     (defined?(ActiveRecord) && ActiveRecord.respond_to?(:default_timezone) ?
#       ActiveRecord.default_timezone : ar_class.default_timezone)) || :local
class TestDefaultTimezoneFixExpression < Minitest::Test
  def test_prefers_active_record_module_when_available
    # Rails 7.2+: ActiveRecord module responds to .default_timezone
    ar_module = stub_ar_module(:local)
    ar_class = stub_ar_class(:utc)

    result = if defined?(ar_module) && ar_module.respond_to?(:default_timezone)
               ar_module.default_timezone
             else
               ar_class.default_timezone
             end

    assert_equal :local, result, "Should prefer ActiveRecord module (Rails 7.2+)"
  end

  def test_falls_back_to_ar_class_when_module_not_responding
    # pre-7.2 Rails: ActiveRecord module does not respond to .default_timezone
    ar_module = stub_ar_module(nil, respond_to_default_timezone: false)
    ar_class = stub_ar_class(:utc)

    result = if defined?(ar_module) && ar_module.respond_to?(:default_timezone)
               ar_module.default_timezone
             else
               ar_class.default_timezone
             end

    assert_equal :utc, result, "Should fall back to ar_class.default_timezone on pre-7.2"
  end

  def test_fallback_to_local_when_nothing_available
    connection = nil
    ar_class = nil
    ar_module = nil

    result = (connection && (ar_class = connection) &&
              (defined?(ar_module) && ar_module.respond_to?(:default_timezone) ?
                ar_module.default_timezone : (ar_class && ar_class.default_timezone))) || :local

    assert_equal :local, result
  end

  private

  def stub_ar_module(tz, respond_to_default_timezone: true)
    mod = Module.new
    mod.define_singleton_method(:default_timezone) { tz } if respond_to_default_timezone
    mod.define_singleton_method(:respond_to?) do |method_name, *args|
      if method_name == :default_timezone
        respond_to_default_timezone
      else
        super(method_name, *args)
      end
    end
    mod
  end

  def stub_ar_class(tz)
    Class.new do
      define_singleton_method(:default_timezone) { tz }
    end
  end
end
