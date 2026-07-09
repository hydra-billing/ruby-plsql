#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Ruby 3.4 compatibility tests for ruby-plsql.
# These tests verify that constants and patterns removed in Ruby 3.4
# (Fixnum, Bignum, BigDecimal.new) are no longer referenced in the codebase
# in MRI/OCI paths. They do NOT require an Oracle database.
#
# Run: ruby -Ilib -Itest test/compatibility/ruby34_compatibility_test.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'minitest/autorun'

class Ruby34CompatibilityTest < Minitest::Test
  SOURCE_FILES = [
    File.expand_path('../../lib/plsql/oci_connection.rb', __dir__),
    File.expand_path('../../lib/plsql/subprogram_call.rb', __dir__),
  ].freeze

  DISALLOWED_PATTERNS = {
    'Fixnum constant'          => /\bFixnum\b/,
    'Bignum constant'          => /\bBignum\b/,
    'BigDecimal.new call'      => /BigDecimal\.new\b/,
  }.freeze

  def test_no_fixnum_bignum_bigdecimal_new_in_source
    SOURCE_FILES.each do |file|
      content = File.read(file)
      DISALLOWED_PATTERNS.each do |name, pattern|
        matches = content.scan(pattern)
        assert matches.empty?,
          "#{File.basename(file)} still contains #{name}: #{matches.inspect}"
      end
    end
  end

  def test_integer_constant_defined
    assert Integer, 'Integer must be defined in Ruby 3.4'
  end

  def test_bigdecimal_new_raises_no_method_error
    require 'bigdecimal'
    err = assert_raises(NoMethodError) do
      BigDecimal.new('1.23')
    end
    assert_match(/undefined method ['`]new'/, err.message)
  end

  def test_bigdecimal_constructor_works
    require 'bigdecimal'
    bd = BigDecimal('1.23')
    assert_equal BigDecimal, bd.class
    assert_equal '0.123e1', bd.to_s
  end

  def test_ruby34_constants_not_defined
    skip 'Fixnum/Bignum removal applies only to Ruby >= 3.4' if RUBY_VERSION < '3.4'
    refute defined?(Fixnum), 'Fixnum should not be defined in Ruby 3.4'
    refute defined?(Bignum), 'Bignum should not be defined in Ruby 3.4'
end

end