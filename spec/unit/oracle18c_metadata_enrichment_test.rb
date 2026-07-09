# encoding: utf-8
#
# Unit test for Oracle 18c+ composite metadata enrichment in
# PLSQL::ProcedureCommon#enrich_composite_metadata_from_plsql_views.
# Does NOT require Oracle connection.
#
# Usage:
#   ruby -Ilib -Ispec/unit spec/unit/oracle18c_metadata_enrichment_test.rb
#

$LOAD_PATH.unshift(File.dirname(__FILE__) + '/../lib')

require 'minitest/autorun'
require 'ruby-plsql'

class TestOracle18cMetadataEnrichment < Minitest::Test
  # Mock schema that returns canned responses for select_first / select_all
  class MockSchema
    attr_reader :schema_name

    def initialize(schema_name = 'HR')
      @schema_name = schema_name
    end

    def select_first(sql, *bindvars)
      # Simulate ALL_PLSQL_COLL_TYPES lookup
      if sql.include?('all_plsql_coll_types')
        # Package-local query has package_name in WHERE clause
        if sql.include?('package_name')
          type_name = bindvars[0]
          package_name = bindvars[2]
          case [type_name, package_name]
          when ['T_PKG_TABLE', 'MY_PKG']
            # TABLE OF T_PKG_REC (package-local record element -> has fields)
            ['TABLE', 'T_PKG_REC', 'HR', 'MY_PKG', nil, nil, nil]
          when ['T_PKG_VC_TABLE', 'MY_PKG']
            # TABLE OF VARCHAR2 (scalar element -> no fields)
            ['TABLE', 'VARCHAR2', nil, nil, 100, nil, nil]
          else
            nil
          end
        else
          type_name = bindvars[0]
          case type_name
          when 'T_RECORD_TABLE'
            # TABLE OF T_RECORD (object/record element -> has fields)
            ['TABLE', 'T_RECORD', 'HR', nil, nil, nil, nil]
          when 'T_VC_TABLE'
            # TABLE OF VARCHAR2 (scalar element -> no fields)
            ['TABLE', 'VARCHAR2', nil, nil, 100, nil, nil]
          when 'T_NUM_TABLE'
            # TABLE OF NUMBER (scalar element -> no fields)
            ['TABLE', 'NUMBER', nil, nil, nil, 10, 2]
          when 'T_NO_TYPE'
            # Collection type not found in ALL_PLSQL_COLL_TYPES
            nil
          else
            nil
          end
        end
      else
        nil
      end
    end

    def select_all(sql, *bindvars, &block)
      # Simulate ALL_PLSQL_TYPE_ATTRS lookup
      if sql.include?('all_plsql_type_attrs')
        # Package-local query
        if sql.include?('package_name')
          type_name = bindvars[0]
          package_name = bindvars[2]
          case [type_name, package_name]
          when ['T_PKG_REC', 'MY_PKG']
            rows = [
              ['ID',   'NUMBER',   1, nil, 10, 0, nil],
              ['NAME', 'VARCHAR2', 2, 100, nil, nil, nil],
            ]
            if block
              rows.each { |r| block.call(r) }
              rows.size
            else
              rows
            end
          else
            []
          end
        else
          type_name = bindvars[0]
          case type_name
          when 'T_RECORD'
            rows = [
              ['ID',   'NUMBER',   1, nil, 10, 0, nil],
              ['NAME', 'VARCHAR2', 2, 100, nil, nil, nil],
            ]
            if block
              rows.each { |r| block.call(r) }
              rows.size
            else
              rows
            end
          else
            []
          end
        end
      else
        []
      end
    end

    def execute(sql, *bindvars)
      nil
    end
  end

  def setup
    @mock_schema = MockSchema.new('HR')
    @return = {}
  end

  # Simulate a ProcedureCommon enrichment call by calling
  # enrich_composite_metadata_from_plsql_views on a test object.
  def create_test_procedure(return_meta)
    obj = Object.new
    obj.extend(PLSQL::ProcedureCommon)

    # Set instance variables the enrichment method expects
    obj.instance_variable_set(:@schema, @mock_schema)
    obj.instance_variable_set(:@return, { 0 => return_meta })
    obj.instance_variable_set(:@schema_name, 'HR')
    obj.instance_variable_set(:@arguments, { 0 => {} })

    obj
  end

  def test_collection_of_record_enriches_element_and_fields
    # Simulate Oracle 18c+ ALL_ARGUMENTS return:
    # one row, data_type='TABLE', type_name='T_RECORD_TABLE'
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_RECORD_TABLE',
      type_owner: 'HR',
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element], 'TABLE element should be populated from ALL_PLSQL_COLL_TYPES'
    assert_equal 'PL/SQL RECORD', enriched[:element][:data_type],
      'Element data_type should be PL/SQL RECORD for object/record element'
    assert_equal 'T_RECORD', enriched[:element][:type_name]

    fields = enriched[:element][:fields]
    refute_nil fields, 'Fields should be populated for record element'
    refute_empty fields, 'Fields should not be empty'

    id_field = fields[:id]
    refute_nil id_field, 'Should have :id field'
    assert_equal 'NUMBER', id_field[:data_type]
    assert_equal 1, id_field[:position]
    assert_equal 10, id_field[:data_precision]
    assert_equal 0, id_field[:data_scale]

    name_field = fields[:name]
    refute_nil name_field, 'Should have :name field'
    assert_equal 'VARCHAR2', name_field[:data_type]
    assert_equal 2, name_field[:position]
    assert_equal 100, name_field[:data_length]
  end

  def test_collection_of_scalar_enriches_element_without_fields
    # TABLE OF VARCHAR2
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_VC_TABLE',
      type_owner: 'HR',
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element], 'Scalar TABLE element should be populated'
    assert_equal 'VARCHAR2', enriched[:element][:data_type],
      'Element data_type should be VARCHAR2 for scalar element'
    assert_equal 100, enriched[:element][:data_length]
    assert_nil enriched[:element][:fields],
      'Scalar element should NOT have :fields'
  end

  def test_collection_of_number_enriches_element_without_fields
    # TABLE OF NUMBER(10,2)
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_NUM_TABLE',
      type_owner: 'HR',
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element]
    assert_equal 'NUMBER', enriched[:element][:data_type],
      'Element data_type should be NUMBER'
    assert_equal 10, enriched[:element][:data_precision]
    assert_equal 2, enriched[:element][:data_scale]
    assert_nil enriched[:element][:fields]
  end

  def test_skips_when_type_not_in_plsql_coll_types
    # Collection type not found in ALL_PLSQL_COLL_TYPES
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_NO_TYPE',
      type_owner: 'HR',
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    assert_nil enriched[:element],
      'Should skip enrichment when type not found in ALL_PLSQL_COLL_TYPES'
  end

  def test_skips_when_element_already_present
    # Pre-18c case: element is already populated
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_RECORD_TABLE',
      type_owner: 'HR',
      type_subname: nil,
      element: { data_type: 'PL/SQL RECORD' },
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    # Should NOT overwrite existing element
    assert_equal 'PL/SQL RECORD', enriched[:element][:data_type],
      'Should keep pre-existing element metadata'
  end

  def test_package_local_collection_of_record_enriches_element_and_fields
    # Oracle 18c+: package-local type with type_subname
    # TYPE_NAME=package, TYPE_SUBNAME=local collection type
    return_meta = {
      data_type: 'TABLE',
      type_name: 'MY_PKG',
      type_owner: 'HR',
      type_subname: 'T_PKG_TABLE',  # package-local type
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element],
      'Package-local TABLE element should be populated from ALL_PLSQL_COLL_TYPES'
    assert_equal 'PL/SQL RECORD', enriched[:element][:data_type],
      'Element data_type should be PL/SQL RECORD for record element'
    assert_equal 'T_PKG_REC', enriched[:element][:type_name]

    fields = enriched[:element][:fields]
    refute_nil fields, 'Fields should be populated for package-local record element'
    refute_empty fields, 'Fields should not be empty'

    id_field = fields[:id]
    refute_nil id_field, 'Should have :id field'
    assert_equal 'NUMBER', id_field[:data_type]
    assert_equal 1, id_field[:position]

    name_field = fields[:name]
    refute_nil name_field, 'Should have :name field'
    assert_equal 'VARCHAR2', name_field[:data_type]
    assert_equal 2, name_field[:position]
  end

  def test_package_local_collection_of_scalar_enriches_element_without_fields
    # Package-local TABLE OF VARCHAR2
    return_meta = {
      data_type: 'TABLE',
      type_name: 'MY_PKG',
      type_owner: 'HR',
      type_subname: 'T_PKG_VC_TABLE',  # package-local type
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element],
      'Package-local scalar TABLE element should be populated'
    assert_equal 'VARCHAR2', enriched[:element][:data_type],
      'Element data_type should be VARCHAR2 for scalar element'
    assert_equal 100, enriched[:element][:data_length]
    assert_nil enriched[:element][:fields],
      'Scalar element should NOT have :fields'
  end

  def test_skips_package_local_type_not_found_in_coll_types
    # Package-local collection type that is NOT found in ALL_PLSQL_COLL_TYPES
    return_meta = {
      data_type: 'TABLE',
      type_name: 'MY_PKG',
      type_owner: 'HR',
      type_subname: 'T_UNKNOWN',  # not defined in ALL_PLSQL_COLL_TYPES
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    assert_nil enriched[:element],
      'Should skip package-local type when not found in ALL_PLSQL_COLL_TYPES'
  end

  def test_skips_when_return_is_not_a_collection
    # Non-collection composite type: PL/SQL RECORD (not a TABLE/VARRAY)
    return_meta = {
      data_type: 'PL/SQL RECORD',
      type_name: 'T_RECORD',
      type_owner: 'HR',
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
      fields: {},
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:fields],
      'PL/SQL RECORD should not be affected by enrichment'
    assert_nil enriched[:element],
      'PL/SQL RECORD should not get :element key'
  end

  def test_enriches_owner_fallback_to_schema_name
    # When type_owner is nil, enrichment should fall back to @schema_name
    return_meta = {
      data_type: 'TABLE',
      type_name: 'T_RECORD_TABLE',
      type_owner: nil,
      type_subname: nil,
      position: nil,
      in_out: 'OUT',
    }

    procedure = create_test_procedure(return_meta)
    procedure.send(:enrich_composite_metadata_from_plsql_views)

    enriched = procedure.instance_variable_get(:@return)[0]

    refute_nil enriched[:element],
      'Element should be populated even when type_owner is nil (fallback to schema_name)'
    assert_equal 'PL/SQL RECORD', enriched[:element][:data_type]
  end
end
