# frozen_string_literal: true

require_relative "skinny_includes/version"

module SkinnyIncludes
  module Relation
    def with_columns(config)
      config.each_key do |assoc|
        reflection = model.reflect_on_association(assoc)
        raise ArgumentError, "Unknown association: #{assoc}" unless reflection
      end

      spawn.tap { |relation| relation.with_columns_config!(config) }
    end

    def without_columns(config)
      config.each_key do |assoc|
        reflection = model.reflect_on_association(assoc)
        raise ArgumentError, "Unknown association: #{assoc}" unless reflection
      end

      spawn.tap { |relation| relation.without_columns_config!(config) }
    end

    def with_columns_config!(config)
      @values[:with_columns] = config
    end

    def without_columns_config!(config)
      @values[:without_columns] = config
    end

    def with_columns_config
      @values[:with_columns]
    end

    def without_columns_config
      @values[:without_columns]
    end

    def load
      return super unless with_columns_config || without_columns_config
      return self if @loaded

      config = with_columns_config || without_columns_config
      is_without = without_columns_config.present?

      [:preload, :includes].each do |key|
        if @values[key]&.any?
          remaining = Array(@values[key]).reject do |val|
            config.keys.include?(val) || (val.is_a?(Hash) && (val.keys & config.keys).any?)
          end

          @values[key] = remaining if remaining != @values[key]
        end
      end

      super

      config.each do |assoc, column_spec|
        reflection = model.reflect_on_association(assoc)
        raise ArgumentError, "Unknown association: #{assoc}" unless reflection

        next if @records.empty?

        assoc_class = reflection.klass

        # Parse column spec - could be array, hash with :columns and :include, or nil
        columns, nested_includes = parse_column_spec(column_spec, assoc_class, is_without)

        pk = assoc_class.primary_key.to_sym
        columns |= [pk]

        # If there are nested includes, ensure we select their foreign keys
        if nested_includes
          nested_includes.each_key do |nested_assoc|
            nested_reflection = assoc_class.reflect_on_association(nested_assoc)
            if nested_reflection
              nested_fk = nested_reflection.foreign_key.to_sym
              # Only add FK if it's on the current table (has_many/has_one/belongs_to)
              if nested_reflection.macro == :belongs_to ||
                 nested_reflection.macro == :has_many ||
                 nested_reflection.macro == :has_one
                columns |= [nested_fk] if assoc_class.column_names.include?(nested_fk.to_s)
              end
            end
          end
        end

        fk = reflection.foreign_key.to_sym
        parent_ids = @records.map(&:id).uniq

        case reflection.macro
        when :has_many, :has_one
          # For has_many/has_one, the foreign key is on the associated table
          columns |= [fk] if fk

          # Build base query
          base_query = assoc_class.where(fk => parent_ids)

          # Apply association scope if present
          if reflection.scope
            base_query = base_query.instance_exec(&reflection.scope)
          end

          associated_records = base_query
            .select(*columns)
            .to_a

          grouped = associated_records.group_by(&fk)

          @records.each do |record|
            records_for_parent = grouped[record.id] || []

            if reflection.macro == :has_many
              record.association(assoc).target = records_for_parent
            else
              record.association(assoc).target = records_for_parent.first
            end

            record.association(assoc).loaded!
          end

          # Load nested associations recursively
          load_nested_associations(associated_records, nested_includes, is_without) if nested_includes && associated_records.any?

        when :belongs_to
          fk_values = @records.map { |r| r.send(fk) }.compact.uniq

          base_query = assoc_class.where(pk => fk_values)

          if reflection.scope
            base_query = base_query.instance_exec(&reflection.scope)
          end

          associated_records = base_query
            .select(*columns)
            .index_by(&pk)

          @records.each do |record|
            fk_value = record.send(fk)
            if fk_value
              record.association(assoc).target = associated_records[fk_value]
              record.association(assoc).loaded!
            end
          end

          # Load nested associations recursively
          load_nested_associations(associated_records.values, nested_includes, is_without) if nested_includes && associated_records.any?
        end

        # Load nested associations for has_many/has_one (already done above in their case blocks)
      end

      self
    end

    private

    def parse_column_spec(column_spec, assoc_class, is_without)
      if column_spec.is_a?(Hash) && (column_spec.key?(:columns) || column_spec.key?(:include))
        # New hash syntax: { columns: [:foo], include: { bar: [:baz] } }
        columns_list = column_spec[:columns]
        nested = column_spec[:include]
      else
        # Legacy array syntax: [:foo, :bar]
        columns_list = column_spec
        nested = nil
      end

      if is_without
        excluded = Array(columns_list).map(&:to_s)
        all_columns = assoc_class.column_names
        columns = (all_columns - excluded).map(&:to_sym)
      else
        columns = Array(columns_list || [])
      end

      [columns, nested]
    end

    def load_nested_associations(records, nested_config, is_without)
      return if records.empty? || nested_config.nil? || nested_config.empty?

      # Group records by class (in case of STI)
      records_by_class = records.group_by(&:class)

      records_by_class.each do |klass, klass_records|
        nested_config.each do |nested_assoc, nested_column_spec|
          nested_reflection = klass.reflect_on_association(nested_assoc)
          raise ArgumentError, "Unknown association: #{nested_assoc}" unless nested_reflection

          nested_assoc_class = nested_reflection.klass

          # Parse nested column spec
          nested_columns, deeper_nested = parse_column_spec(nested_column_spec, nested_assoc_class, is_without)

          pk = nested_assoc_class.primary_key.to_sym
          nested_columns |= [pk]

          if deeper_nested
            deeper_nested.each_key do |deeper_assoc|
              deeper_reflection = nested_assoc_class.reflect_on_association(deeper_assoc)
              if deeper_reflection
                deeper_fk = deeper_reflection.foreign_key.to_sym
                if nested_assoc_class.column_names.include?(deeper_fk.to_s)
                  nested_columns |= [deeper_fk]
                end
              end
            end
          end

          nested_fk = nested_reflection.foreign_key.to_sym

          case nested_reflection.macro
          when :has_many, :has_one
            nested_columns |= [nested_fk] if nested_fk

            parent_ids = klass_records.map(&:id).uniq
            base_query = nested_assoc_class.where(nested_fk => parent_ids)

            if nested_reflection.scope
              base_query = base_query.instance_exec(&nested_reflection.scope)
            end

            nested_records = base_query.select(*nested_columns).to_a
            grouped = nested_records.group_by(&nested_fk)

            klass_records.each do |record|
              records_for_parent = grouped[record.id] || []

              if nested_reflection.macro == :has_many
                record.association(nested_assoc).target = records_for_parent
              else
                record.association(nested_assoc).target = records_for_parent.first
              end

              record.association(nested_assoc).loaded!
            end

            load_nested_associations(nested_records, deeper_nested, is_without) if deeper_nested && nested_records.any?

          when :belongs_to
            fk_values = klass_records.map { |r| r.send(nested_fk) }.compact.uniq

            base_query = nested_assoc_class.where(pk => fk_values)

            if nested_reflection.scope
              base_query = base_query.instance_exec(&nested_reflection.scope)
            end

            nested_records = base_query.select(*nested_columns).index_by(&pk)

            klass_records.each do |record|
              fk_value = record.send(nested_fk)
              if fk_value
                record.association(nested_assoc).target = nested_records[fk_value]
                record.association(nested_assoc).loaded!
              end
            end

            # Recursively load deeper nested associations
            load_nested_associations(nested_records.values, deeper_nested, is_without) if deeper_nested && nested_records.any?
          end
        end
      end
    end
  end

  module ModelMethods
    extend ActiveSupport::Concern

    class_methods do
      def with_columns(config)
        all.with_columns(config)
      end

      def without_columns(config)
        all.without_columns(config)
      end
    end
  end
end

if defined?(ActiveRecord)
  ActiveRecord::Relation.prepend(SkinnyIncludes::Relation)

  ActiveSupport.on_load(:active_record) do
    include SkinnyIncludes::ModelMethods
  end
end
