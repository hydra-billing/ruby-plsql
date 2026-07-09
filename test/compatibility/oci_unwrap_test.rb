#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Tests for raw_oci_connection unwrapping behavior.
# These tests verify that ruby-plsql can correctly unwrap:
#   - bare OCI8 connection
#   - wrapper with @raw_connection (current oracle-enhanced contract)
#   - wrapper with @connection (legacy oracle-enhanced contract)
# They do NOT require an Oracle database.
#
# Run: ruby -Ilib -Itest test/compatibility/oci_unwrap_test.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'minitest/autorun'

# Load ruby_plsql, handling the case where OCI8 is not installed.
begin
  require 'ruby_plsql'
rescue LoadError => _e
  # OCI8 may not be installed. Load just enough for the tests.
  require 'plsql/connection'
  require 'plsql/version'
  require 'plsql/helpers'
  # Stub OCI8 to avoid the real dependency
  unless defined?(OCI8)
    OCI8 = Class.new
  end
  require 'plsql/oci_connection'
end

class OciUnwrapTest < Minitest::Test
  # Fake OCI8-like class so we can test without loading ruby-oci8.
  class FakeOCI8
    attr_reader :id

    def initialize(id = 'real_oci8')
      @id = id
    end

    def get_tdo_by_class(_klass)
      :fake_tdo
    end
  end

  # Simulates an oracle-enhanced adapter wrapper that stores OCI8 in @raw_connection.
  class WrapperWithRawConnection
    attr_reader :raw_connection

    def initialize(oci8)
      @raw_connection = oci8
    end
  end

  # Simulates a legacy oracle-enhanced adapter wrapper that stores OCI8 in @connection.
  class WrapperWithConnection
    attr_reader :connection

    def initialize(oci8)
      @connection = oci8
    end
  end

  # Simulates a wrapper that has neither @raw_connection nor @connection.
  class UnknownWrapper
  end

  def setup
    @real_oci8 = FakeOCI8.new('primary')
  end

  def test_unwraps_wrapper_with_raw_connection
    wrapper = WrapperWithRawConnection.new(@real_oci8)
    conn = PLSQL::OCIConnection.new(wrapper)

    result = conn.send(:raw_oci_connection)

    assert_equal @real_oci8, result,
      'Expected raw_oci_connection to return OCI8 from @raw_connection'
  end

  def test_unwraps_wrapper_with_connection
    wrapper = WrapperWithConnection.new(@real_oci8)
    conn = PLSQL::OCIConnection.new(wrapper)

    result = conn.send(:raw_oci_connection)

    assert_equal @real_oci8, result,
      'Expected raw_oci_connection to return OCI8 from @connection (legacy)'
  end

  def test_prefers_raw_connection_over_connection
    # If both ivars exist, @raw_connection should take priority
    wrapper = Object.new
    wrapper.instance_variable_set(:@raw_connection, FakeOCI8.new('raw'))
    wrapper.instance_variable_set(:@connection, FakeOCI8.new('old'))

    conn = PLSQL::OCIConnection.new(wrapper)
    result = conn.send(:raw_oci_connection)

    assert_equal 'raw', result.id,
      'Expected @raw_connection to take priority over @connection'
  end

  def test_returns_nil_for_unknown_wrapper
    wrapper = UnknownWrapper.new
    conn = PLSQL::OCIConnection.new(wrapper)

    result = conn.send(:raw_oci_connection)

    assert_nil result,
      'Expected nil when wrapper has neither @raw_connection nor @connection'
  end

  def test_get_tdo_by_class_works_through_unwrap
    # Verify that raw_oci_connection.get_tdo_by_class works through unwrapping.
    oci8 = FakeOCI8.new('tdo_test')
    wrapper = WrapperWithRawConnection.new(oci8)
    conn = PLSQL::OCIConnection.new(wrapper)

    unwrapped = conn.send(:raw_oci_connection)

    assert_equal :fake_tdo, unwrapped.get_tdo_by_class(Class.new),
      'Expected get_tdo_by_class to work through unwrapped connection'
  end
end
