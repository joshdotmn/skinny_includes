# Changelog

## 0.1

### Added
- **Scoped associations support**: Association scopes are now properly respected when using `with_columns` and `without_columns`
  - Works with `has_many`, `has_one`, and `belongs_to` associations
  - Scopes are applied via `instance_exec` on the base query
  - Example: `Post.includes(:published_comments).with_columns(published_comments: [:body])`

- **Nested/chained includes support**: You can now load nested associations with column selection
  - Use hash syntax with `:columns` and `:include` keys
  - Supports unlimited nesting depth
  - Automatically includes necessary foreign keys
  - Example:
    ```ruby
    Post.with_columns(
      comments: {
        columns: [:body],
        include: { author: [:name] }
      }
    )
    ```
  - Works with `belongs_to`, `has_many`, and `has_one` at any nesting level
  - Works with both `with_columns` and `without_columns`
  - Respects scoped associations at all nesting levels

### Fixed
- **belongs_to foreign key bug**: Fixed issue where the gem tried to select the foreign key column from the associated table in `belongs_to` associations
  - Foreign keys are now only included for `has_many` and `has_one` associations (where they exist on the associated table)
  - For `belongs_to`, the foreign key exists on the source table, not the target

### Testing
- Added comprehensive test coverage for `belongs_to` associations (15 tests)
- Added comprehensive test coverage for `has_one` associations (9 tests)
- Added tests for scoped associations (5 tests)
- Added tests for nested includes (6 tests)
- Added tests for all loading strategies (`includes`, `preload`, `eager_load`)
- Total: 68 tests, all passing

## Implementation Details

### Scoped Associations
The implementation applies association scopes by calling `instance_exec` on the base query with the scope proc:

```ruby
base_query = assoc_class.where(fk => parent_ids)

if reflection.scope
  base_query = base_query.instance_exec(&reflection.scope)
end

associated_records = base_query.select(*columns).to_a
```

This ensures that scopes defined like `-> { where(published: true) }` are properly evaluated in the context of the relation.

### Implementation Details

#### Nested Includes
The implementation recursively loads nested associations:

1. Parses column specs to extract `:columns` and `:include` keys
2. Automatically includes foreign keys needed for nested associations
3. Recursively calls `load_nested_associations` after loading each level
4. Supports STI (Single Table Inheritance) by grouping records by class
5. Works with all association types (`belongs_to`, `has_many`, `has_one`)

The hash syntax makes the structure explicit:
```ruby
{
  columns: [:foo, :bar],     # What to select
  include: { nested: [...] } # What to nest
}
```
