# skinny_includes

Select specific columns when preloading associations. Prevents N+1 queries, reduces memory usage.

## Why?

### Big beautiful columns 

I have a lot of columns that have associated JSON directly on the table.

```ruby
class ThingWithJsonDataColumn < ApplicationRecord 
  # has a `data` column name with column type of `json` 
end
```

Sometimes I load 5k of these ThingWithJsonDataColumn objects in an HTTP request. This is expensive.

I could write a custom association that excludes the column I don't care about, but that's silly.

## Use case

The obvious use case is large JSON or text columns that slow queries and inflate memory. Instead of writing custom scoped associations, exclude them:

```ruby
post.without_columns(comments: [:metadata_json, :body])
```

Loads all columns except `metadata_json` and `body`.

## Installation

```bash
bundle add skinny_includes
```

Or manually:

```ruby
gem 'skinny_includes'
```

## Usage

Two methods:

**with_columns** — whitelist columns:

```ruby
Post.with_columns(comments: [:author, :upvotes])
Post.includes(:comments).with_columns(comments: [:author])
```

**without_columns** — blacklist columns:

```ruby
Post.without_columns(comments: [:body, :metadata])
Post.includes(:comments).without_columns(comments: :body)
```

Both work with multiple associations:

```ruby
Post.with_columns(comments: [:author], tags: [:name])
Post.without_columns(comments: [:body], tags: [:description])
```

Primary keys and foreign keys are always included, even if excluded.

## Scoped Associations

Scoped associations are fully supported:

```ruby
class Post < ApplicationRecord
  has_many :published_comments, -> { where(published: true) }, class_name: 'Comment'
end

Post.includes(:published_comments).with_columns(published_comments: [:body, :author])
```

The scope is respected—only published comments are loaded, and only the specified columns are selected.

## Loading Strategies

Works with all ActiveRecord loading strategies:

- `includes` - Recommended, lets Rails choose the strategy
- `preload` - Always uses separate queries
- `eager_load` - Converts to the gem's loading strategy automatically

## Supported Association Types

- `has_many` ✅
- `has_one` ✅
- `belongs_to` ✅

All association types work with both `with_columns` and `without_columns`.

## Nested Includes

Nested/chained includes are fully supported with hash syntax:

```ruby
Post.with_columns(
  comments: {
    columns: [:body],
    include: { author: [:name] }
  }
)
```

This loads posts with their comments (only `body` column) and each comment's author (only `name` column). Foreign keys are automatically included as needed.

### Multi-level Nesting

You can nest as deep as you want:

```ruby
Post.with_columns(
  comments: {
    columns: [:body],
    include: {
      author: {
        columns: [:name],
        include: { profile: [:website] }
      }
    }
  }
)
```

### Automatic Foreign Key Inclusion

Foreign keys are automatically included when you use nested includes, even if you don't explicitly specify them:

```ruby
# author_id is automatically selected to load the nested author association
Post.with_columns(
  comments: {
    columns: [:body],  # author_id NOT listed, but will be included
    include: { author: [:name] }
  }
)
```

### Nested with `without_columns`

Works the same way:

```ruby
Post.without_columns(
  comments: {
    columns: [:metadata],  # Exclude metadata from comments
    include: { author: [:bio] }  # Exclude bio from authors
  }
)
```

## Requirements

- Ruby 3.0+
- ActiveRecord 7.0+
