module PLSQL

  module ProcedureClassMethods #:nodoc:
    def find(schema, procedure_name, package_name = nil, override_schema_name = nil)
      if package_name
        find_procedure_in_package(schema, package_name, procedure_name, override_schema_name)
      else
        find_procedure_in_schema(schema, procedure_name) || find_procedure_by_synonym(schema, procedure_name)
      end
    end

    def find_procedure_in_schema(schema, procedure_name)
      row = schema.select_first(<<-SQL, schema.schema_name, procedure_name.to_s.upcase)
        SELECT object_id
        FROM   all_procedures
        WHERE  owner = :owner
        AND    object_name = :object_name
        AND    object_type IN ('PROCEDURE', 'FUNCTION')
        AND    pipelined = 'NO'
      SQL
      new(schema, procedure_name, nil, nil, row[0]) if row
    end

    def find_procedure_by_synonym(schema, procedure_name)
      row = schema.select_first(<<-SQL, schema.schema_name, procedure_name.to_s.upcase)
        SELECT p.owner, p.object_name, p.object_id
        FROM   all_synonyms s,
               all_procedures p
        WHERE  s.owner IN (:owner, 'PUBLIC')
        AND    s.synonym_name = :synonym_name
        AND    p.owner        = s.table_owner
        AND    p.object_name  = s.table_name
        AND    p.object_type IN ('PROCEDURE','FUNCTION')
        AND    p.pipelined    = 'NO'
        ORDER BY DECODE(s.owner, 'PUBLIC', 1, 0)
      SQL
      new(schema, row[1], nil, row[0], row[2]) if row
    end

    def find_procedure_in_package(schema, package_name, procedure_name, override_schema_name = nil)
      schema_name = override_schema_name || schema.schema_name
      row = schema.select_first(<<-SQL, schema_name, package_name, procedure_name.to_s.upcase)
        SELECT o.object_id
        FROM   all_procedures p,
               all_objects o
        WHERE  p.owner       = :owner
        AND    p.object_name = :object_name
        AND    p.procedure_name = :procedure_name
        AND    p.pipelined   = 'NO'
        AND    o.owner       = p.owner
        AND    o.object_name = p.object_name
        AND    o.object_type = 'PACKAGE'
      SQL
      new(schema, procedure_name, package_name, override_schema_name, row[0]) if row
    end
  end

  module ProcedureCommon #:nodoc:
    attr_reader :arguments, :argument_list, :out_list, :return
    attr_reader :schema, :schema_name, :package, :procedure

    # return type string from metadata that can be used in DECLARE block or table definition
    def self.type_to_sql(metadata) #:nodoc:
      case metadata[:data_type]
      when 'NUMBER'
        precision, scale = metadata[:data_precision], metadata[:data_scale]
        "NUMBER#{precision ? "(#{precision}#{scale ? ",#{scale}": ""})" : ""}"
      when 'VARCHAR2', 'CHAR'
        length = case metadata[:char_used]
        when 'C' then "#{metadata[:char_length]} CHAR"
        when 'B' then "#{metadata[:data_length]} BYTE"
        else
          metadata[:data_length]
        end
        "#{metadata[:data_type]}#{length && "(#{length})"}"
      when 'NVARCHAR2', 'NCHAR'
        length = metadata[:char_length]
        "#{metadata[:data_type]}#{length && "(#{length})"}"
      when 'PL/SQL TABLE', 'TABLE', 'VARRAY', 'OBJECT'
        metadata[:sql_type_name]
      else
        metadata[:data_type]
      end
    end

    def record_type_content(type_subname)
      @schema.select_all(
        "SELECT ta.attr_name,
                ta.attr_no,
                ta.attr_type_name,
                ta.length,
                ta.precision,
                ta.scale,
                ta.char_used,
                ta.length,
                ta.owner,
                ta.attr_name
         FROM  all_plsql_type_attrs    ta
         WHERE ta.type_name = :type_subname", type_subname
      ).inject({}) do |hash, el|
        hash[el[0].downcase.to_sym] = {position: el[1],
                                       data_type: el[2],
                                       data_length: el[3],
                                       data_precision: el[4],
                                       data_scale: el[5],
                                       char_used: el[6],
                                       char_length: el[7],
                                       type_owner: el[8],
                                       type_name: el[9]}
        hash
      end
    end

    def table_type_content(type_subname)
      @schema.select_all(
        "SELECT ta.attr_name,
                ta.attr_no,
                ta.attr_type_name,
                ta.length,
                ta.precision,
                ta.scale,
                ta.char_used,
                ta.length,
                ta.owner,
                ta.attr_name
         FROM all_plsql_coll_types   act
         INNER JOIN all_plsql_type_attrs   ta
         on   ta.type_name = act.elem_type_name
         where act.type_name = :type_subname", type_subname
      ).inject({}) do |hash, el|
        hash[el[0].downcase.to_sym] = {position: el[1],
                                       data_type: el[2],
                                       data_length: el[3],
                                       data_precision: el[4],
                                       data_scale: el[5],
                                       char_used: el[6],
                                       char_length: el[7],
                                       type_owner: el[8],
                                       type_name: el[9]}
        hash
      end
    end

    def global_table_type_content(type_name)
      @schema.select_all(
        "SELECT act.type_name,
                1,
                act.coll_type,
                act.length,
                act.precision,
                act.scale,
                act.char_used,
                act.length,
                act.owner,
                act.type_name
         FROM  all_coll_types    act
         WHERE act.type_name = :type_name", type_name
      ).inject({}) do |hash, el|
        hash[el[0].downcase.to_sym] = {position: el[1],
                                       data_type: el[2],
                                       data_length: el[3],
                                       data_precision: el[4],
                                       data_scale: el[5],
                                       char_used: el[6],
                                       char_length: el[7],
                                       type_owner: el[8],
                                       type_name: el[9]}
        hash
      end
    end

    # get procedure argument metadata from data dictionary
    def get_argument_metadata #:nodoc:
      @arguments = {}
      @argument_list = {}
      @out_list = {}
      @return = {}
      @overloaded = false

      # store reference to previous level record or collection metadata
      previous_level_argument_metadata = {}

      # store tmp tables for each overload for table parameters with types defined inside packages
      @tmp_table_names = {}
      # store if tmp tables are created for specific overload
      @tmp_tables_created = {}

      # subprogram_id column is available just from version 10g
      subprogram_id_column = (@schema.connection.database_version <=> [10, 2, 0, 2]) >= 0 ? 'subprogram_id' : 'NULL'

      @schema.select_all(
        "SELECT #{subprogram_id_column}, object_name, TO_NUMBER(overload), argument_name, position, data_level,
              data_type, in_out, data_length, data_precision, data_scale, char_used,
              char_length, type_owner, type_name, type_subname
        FROM all_arguments
        WHERE object_id = :object_id
        AND owner = :owner
        AND object_name = :procedure_name
        ORDER BY overload, sequence",
        @object_id, @schema_name, @procedure
      ) do |r|

        subprogram_id, object_name, overload, argument_name, position, data_level,
            data_type, in_out, data_length, data_precision, data_scale, char_used,
            char_length, type_owner, type_name, type_subname = r

        @overloaded ||= !overload.nil?
        # if not overloaded then store arguments at key 0
        overload ||= 0
        @arguments[overload] ||= {}
        @return[overload] ||= nil
        @tmp_table_names[overload] ||= []

        sql_type_name = type_owner && "#{type_owner == 'PUBLIC' ? nil : "#{type_owner}."}#{type_name}#{type_subname ? ".#{type_subname}" : nil}"

        tmp_table_name = nil
        # type defined inside package
        if type_subname
          if collection_type?(data_type)
            raise ArgumentError, "#{data_type} type #{sql_type_name} definition inside package is not supported as part of other type definition," <<
              " use CREATE TYPE outside package" if data_level > 0
            # if subprogram_id was not supported by all_arguments view
            # then generate unique ID from object_name and overload
            subprogram_id ||= "#{object_name.hash % 10000}#{overload}"
            tmp_table_name = "#{Connection::RUBY_TEMP_TABLE_PREFIX}#{@schema.connection.session_id}_#{@object_id}_#{subprogram_id}_#{position}"
          elsif data_type != 'PL/SQL RECORD'
            # raise exception only when there are no overloaded procedure definitions
            # (as probably this overload will not be used at all)
            raise ArgumentError, "Parameter type #{sql_type_name} definition inside package is not supported, use CREATE TYPE outside package" if overload == 0
          end
        end

        argument_metadata = {
          :position => position && position.to_i,
          :data_type => data_type,
          :in_out => in_out,
          :data_length => data_length && data_length.to_i,
          :data_precision => data_precision && data_precision.to_i,
          :data_scale => data_scale && data_scale.to_i,
          :char_used => char_used,
          :char_length => char_length && char_length.to_i,
          :type_owner => type_owner,
          :type_name => type_name,
          :type_subname => type_subname,
          :sql_type_name => sql_type_name
        }
        if tmp_table_name
          @tmp_table_names[overload] << [(argument_metadata[:tmp_table_name] = tmp_table_name), argument_metadata]
        end

        if composite_type?(data_type)
          case data_type
          when 'PL/SQL RECORD'
            argument_metadata[:fields] = {}
          end
          previous_level_argument_metadata[data_level] = argument_metadata
        end

        if @schema.connection.database_version[0] >= 18
          if argument_name.nil? && in_out == 'OUT'
            @return[overload] = argument_metadata

            if composite_type?(data_type)
              if data_type == 'PL/SQL RECORD'
                @return[overload][:fields] = record_type_content(type_subname)
              else
                @return[overload][:element] ||= {}
                @return[overload][:element][:fields] = if type_subname
                                                         table_type_content(type_subname)
                                                       else
                                                         global_table_type_content(type_name)
                                                       end
              end
            end
          # if parameter
          else
            # top level parameter
            if data_level == 0
              # sometime there are empty IN arguments in all_arguments view for procedures without arguments (e.g. for DBMS_OUTPUT.DISABLE)
              @arguments[overload][argument_name.downcase.to_sym] = argument_metadata if argument_name
            end
          end
        else
          # if function has return value
          if argument_name.nil? && data_level == 0 && in_out == 'OUT'
            @return[overload] = argument_metadata
          # if parameter
          else
            # top level parameter
            if data_level == 0
              # sometime there are empty IN arguments in all_arguments view for procedures without arguments (e.g. for DBMS_OUTPUT.DISABLE)
              @arguments[overload][argument_name.downcase.to_sym] = argument_metadata if argument_name
            # or lower level part of composite type
            else
              case previous_level_argument_metadata[data_level - 1][:data_type]
              when 'PL/SQL RECORD'
                previous_level_argument_metadata[data_level - 1][:fields][argument_name.downcase.to_sym] = argument_metadata
              when 'PL/SQL TABLE', 'TABLE', 'VARRAY', 'REF CURSOR'
                previous_level_argument_metadata[data_level - 1][:element] = argument_metadata
              end
            end
          end
        end
      end
      # if procedure is without arguments then create default empty argument list for default overload
      @arguments[0] = {} if @arguments.keys.empty?

      construct_argument_list_for_overloads
    end

    def construct_argument_list_for_overloads #:nodoc:
      @overloads = @arguments.keys.sort
      @overloads.each do |overload|
        @argument_list[overload] = @arguments[overload].keys.sort {|k1, k2| @arguments[overload][k1][:position] <=> @arguments[overload][k2][:position]}
        @out_list[overload] = @argument_list[overload].select {|k| @arguments[overload][k][:in_out] =~ /OUT/}
      end
    end

    def ensure_tmp_tables_created(overload) #:nodoc:
      return if @tmp_tables_created.nil? || @tmp_tables_created[overload]
      @tmp_table_names[overload] && @tmp_table_names[overload].each do |table_name, argument_metadata|
        sql = "CREATE GLOBAL TEMPORARY TABLE #{table_name} (\n"
          element_metadata = argument_metadata[:element]
          case element_metadata[:data_type]
          when 'PL/SQL RECORD'
            fields_metadata = element_metadata[:fields]
            fields_sorted_by_position = fields_metadata.keys.sort_by{|k| fields_metadata[k][:position]}
            sql << fields_sorted_by_position.map do |field|
              metadata = fields_metadata[field]
              "#{field} #{ProcedureCommon.type_to_sql(metadata)}"
            end.join(",\n")
          else
            sql << "element #{ProcedureCommon.type_to_sql(element_metadata)}"
          end
          sql << ",\ni__ NUMBER(38)\n"
        sql << ") ON COMMIT PRESERVE ROWS\n"
        sql_block = "DECLARE\nPRAGMA AUTONOMOUS_TRANSACTION;\nBEGIN\nEXECUTE IMMEDIATE :sql;\nEND;\n"
        @schema.execute sql_block, sql
      end
      @tmp_tables_created[overload] = true
    end

    PLSQL_COMPOSITE_TYPES = ['PL/SQL RECORD', 'PL/SQL TABLE', 'TABLE', 'VARRAY', 'REF CURSOR'].freeze
    def composite_type?(data_type) #:nodoc:
      PLSQL_COMPOSITE_TYPES.include? data_type
    end

    PLSQL_COLLECTION_TYPES = ['PL/SQL TABLE', 'TABLE', 'VARRAY'].freeze
    def collection_type?(data_type) #:nodoc:
      PLSQL_COLLECTION_TYPES.include? data_type
    end

    def overloaded? #:nodoc:
      @overloaded
    end
  end

  class Procedure #:nodoc:
    extend ProcedureClassMethods
    include ProcedureCommon

    attr_reader :arguments, :argument_list, :out_list, :return
    attr_reader :schema, :schema_name, :package, :procedure

    def initialize(schema, procedure, package, override_schema_name, object_id)
      @schema = schema
      @schema_name = override_schema_name || schema.schema_name
      @procedure = procedure.to_s.upcase
      @package = package
      @object_id = object_id

      get_argument_metadata
    end

    def exec(*args, &block)
      if defined? ActiveSupport::Notifications
        ActiveSupport::Notifications.instrument("procedure_call.plsql", :procedure => self, :arguments => args) do |payload|
          call = call_class.new(self, args)
          payload[:sql] = call.sql

          begin
            call.exec(&block)
          rescue Exception => e
            # save original error object (:exception key stores only class_name and message)
            payload[:error] = e
            raise e
          end
        end
      else
        call = call_class.new(self, args)
        call.exec(&block)
      end
    end

    def call_class
      ProcedureCall
    end
  end
end
