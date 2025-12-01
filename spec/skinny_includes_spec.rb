# frozen_string_literal: true
#
# tl;dr
# post = Post.first
# post.comments.each do |comment|
#   comment.author
# end
#
# ok just preload them to avoid n+1
# post.includes(:comments)
#
# but you don't need columns other than author
# post.includes(:comments).with_columns(comments: [:author])
#
# now only author, id, and post_id are selected. pk and fk always included.
#
# obvious use case is large json or text columns that slow queries and inflate memory
# instead of writing custom scoped associations, exclude them:
#
# post.without_columns(comments: [:metadata_json, :body])
#
# loads all columns except metadata_json and body
#

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'activerecord'
  gem 'sqlite3'
  gem 'rspec'
end

require 'active_record'
require 'rspec'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
# ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :posts do |t|
    t.string :title
    t.text :body
    t.integer :author_id
    t.timestamps
  end

  create_table :comments do |t|
    t.integer :post_id
    t.integer :author_id
    t.text :body
    t.integer :upvotes
    t.boolean :published, default: false
    t.timestamps
  end

  create_table :tags do |t|
    t.integer :post_id
    t.string :name
    t.string :color
    t.timestamps
  end

  create_table :categories do |t|
    t.integer :post_id
    t.string :name
    t.text :description
    t.timestamps
  end

  create_table :authors do |t|
    t.string :name
    t.text :bio
    t.string :email
    t.timestamps
  end

  create_table :profiles do |t|
    t.integer :author_id
    t.string :website
    t.text :preferences
    t.timestamps
  end
end

# Define models
class Post < ActiveRecord::Base
  has_many :comments
  has_many :tags
  has_many :categories
  belongs_to :author, optional: true
end

class Comment < ActiveRecord::Base
  belongs_to :post
  belongs_to :author, optional: true
end

class Tag < ActiveRecord::Base
  belongs_to :post
end

class Category < ActiveRecord::Base
  belongs_to :post
end

class Author < ActiveRecord::Base
  has_many :posts
  has_many :comments
  has_one :profile
end

class Profile < ActiveRecord::Base
  belongs_to :author
end

require_relative '../lib/skinny_includes'

module QueryCounter
  class << self
    attr_accessor :query_count, :queries

    def reset!
      self.query_count = 0
      self.queries = []
    end

    def count_queries(&block)
      reset!

      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, details|
        # Skip schema queries and SAVEPOINT queries
        unless details[:sql] =~ /PRAGMA|SCHEMA|SAVEPOINT|RELEASE/i
          self.query_count += 1
          self.queries << details[:sql]
        end
      end

      yield

      self.query_count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end

RSpec.describe 'MinifyPreload' do
  before(:each) do
    Post.delete_all
    Comment.delete_all
    Tag.delete_all
    Category.delete_all
    Author.delete_all
    Profile.delete_all
  end

  let(:author) do
    Author.create!(name: 'Jane Author', bio: 'A great author bio', email: 'jane@example.com')
  end

  let(:post) do
    Post.create!(title: 'Test Post', body: 'Post body', author_id: author.id)
  end

  let!(:comments) do
    5.times.map do |i|
      post.comments.create!(
        author_id: author.id,
        body: "Comment body #{i}",
        upvotes: i * 10,
        published: i < 3  # First 3 comments are published
      )
    end
  end

  let!(:tags) do
    3.times.map do |i|
      post.tags.create!(
        name: "Tag #{i}",
        color: "Color #{i}"
      )
    end
  end

  describe '#with_columns' do
    context 'basic functionality' do
      it 'returns only specified columns for association' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end

      it 'always includes primary key even when not specified' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.id).to be_present
        expect(comment.attributes.keys).to include('id')
      end

      it 'always includes foreign key even when not specified' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.post_id).to eq(post.id)
        expect(comment.attributes.keys).to include('post_id')
      end

      it 'loads specified columns with correct values' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.body).to eq('Comment body 0')
      end

      it 'returns nil for non-selected columns' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.attributes['author_id']).to be_nil
        expect(comment.attributes['upvotes']).to be_nil
      end

      it 'handles multiple columns' do
        result = Post.includes(:comments).with_columns(comments: [:body, :upvotes]).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id', 'body', 'upvotes')
        expect(comment.body).to eq('Comment body 0')
        expect(comment.upvotes).to eq(0)
      end

      it 'handles empty column list (only FK and PK)' do
        result = Post.includes(:comments).with_columns(comments: []).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id')
      end

      it 'handles nil column list (only FK and PK)' do
        result = Post.includes(:comments).with_columns(comments: nil).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id')
      end
    end

    context 'multiple associations' do
      it 'handles multiple associations simultaneously' do
        result = Post.includes(:comments, :tags).with_columns(
          comments: [:body],
          tags: [:name]
        ).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
        expect(result.tags.first.attributes.keys).to contain_exactly('id', 'post_id', 'name')
      end

      it 'handles three associations' do
        post.categories.create!(name: 'Ruby', description: 'Ruby programming')

        result = Post.includes(:comments, :tags, :categories).with_columns(
          comments: [:body],
          tags: [:name],
          categories: [:name]
        ).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
        expect(result.tags.first.attributes.keys).to contain_exactly('id', 'post_id', 'name')
        expect(result.categories.first.attributes.keys).to contain_exactly('id', 'post_id', 'name')
      end

      it 'allows different columns for each association' do
        result = Post.includes(:comments, :tags).with_columns(
          comments: [:body, :upvotes],
          tags: [:name, :color]
        ).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body', 'upvotes')
        expect(result.tags.first.attributes.keys).to contain_exactly('id', 'post_id', 'name', 'color')
      end
    end

    context 'without includes' do
      it 'works when called directly on model' do
        result = Post.with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end

      it 'works with where clauses' do
        result = Post.where(id: post.id).with_columns(comments: [:body]).first
        comment = result.comments.first

        expect(comment.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end
    end

    context 'loading all records' do
      it 'loads all associated records' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments.count).to eq(5)
      end

      it 'loads multiple associations completely' do
        result = Post.includes(:comments, :tags).with_columns(
          comments: [:body],
          tags: [:name]
        ).first

        expect(result.comments.count).to eq(5)
        expect(result.tags.count).to eq(3)
      end

      it 'preserves association data integrity' do
        result = Post.includes(:comments).with_columns(comments: [:body, :upvotes]).first

        result.comments.each_with_index do |comment, i|
          expect(comment.body).to eq("Comment body #{i}")
          expect(comment.upvotes).to eq(i * 10)
        end
      end
    end

    context 'error handling' do
      it 'raises error for unknown association' do
        expect {
          Post.includes(:comments).with_columns(unknown_assoc: [:id])
        }.to raise_error(ArgumentError, /Unknown association: unknown_assoc/)
      end

      it 'raises error for invalid association name' do
        expect {
          Post.with_columns(not_real: [:id])
        }.to raise_error(ArgumentError, /Unknown association/)
      end
    end

    context 'N+1 query prevention' do
      it 'prevents N+1 queries for single association' do
        query_count = QueryCounter.count_queries do
          result = Post.includes(:comments).with_columns(comments: [:body]).first
          result.comments.each { |c| c.body }
        end

        expect(query_count).to eq(2)
      end

      it 'prevents N+1 queries with multiple associations' do
        query_count = QueryCounter.count_queries do
          result = Post.includes(:comments, :tags).with_columns(
            comments: [:body],
            tags: [:name]
          ).first

          result.comments.each { |c| c.body }
          result.tags.each { |t| t.name }
        end

        expect(query_count).to eq(3)
      end

      it 'prevents N+1 when iterating over multiple posts' do
        3.times do |i|
          p = Post.create!(title: "Post #{i}", body: "Body #{i}")
          2.times { |j| p.comments.create!(body: "Comment body #{j}") }
        end

        query_count = QueryCounter.count_queries do
          posts = Post.includes(:comments).with_columns(comments: [:body])

          posts.each do |post|
            post.comments.each { |c| c.body }
          end
        end

        expect(query_count).to eq(2)
      end

      it 'prevents N+1 with complex iteration' do
        2.times do |i|
          p = Post.create!(title: "Extra Post #{i}", body: "Body #{i}")
          3.times { |j| p.comments.create!(body: "Body #{j}", upvotes: j) }
          2.times { |j| p.tags.create!(name: "Tag #{j}", color: "Color") }
        end

        query_count = QueryCounter.count_queries do
          posts = Post.includes(:comments, :tags).with_columns(
            comments: [:upvotes],
            tags: [:name]
          )

          posts.each do |post|
            post.comments.sum(&:upvotes)
            post.tags.map(&:name).join(', ')
          end
        end

        expect(query_count).to eq(3)
      end

      it 'uses same query count as regular includes for comparison' do
        Post.delete_all
        Comment.delete_all

        5.times do |i|
          p = Post.create!(title: "Post #{i}")
          3.times { |j| p.comments.create!(body: "Body #{j}") }
        end

        with_columns_count = QueryCounter.count_queries do
          posts = Post.includes(:comments).with_columns(comments: [:body])
          posts.each { |post| post.comments.each { |c| c.body } }
        end

        regular_count = QueryCounter.count_queries do
          posts = Post.includes(:comments)
          posts.each { |post| post.comments.each { |c| c.body } }
        end

        expect(with_columns_count).to eq(regular_count)
        expect(with_columns_count).to eq(2)
      end
    end

    context 'chaining and composition' do
      it 'works with where clauses before with_columns' do
        result = Post.where(title: 'Test Post').includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end

      it 'works with order clauses' do
        result = Post.order(:id).includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end

      it 'works with limit' do
        result = Post.limit(1).includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end
    end

    context 'edge cases' do
      it 'handles posts with no comments' do
        empty_post = Post.create!(title: 'Empty', body: 'No comments')
        result = Post.where(id: empty_post.id).includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments).to be_empty
      end

      it 'handles selecting timestamp columns' do
        result = Post.includes(:comments).with_columns(comments: [:body, :created_at]).first
        comment = result.comments.first

        expect(comment.attributes.keys).to include('created_at')
        expect(comment.created_at).to be_present
      end

      it 'handles selecting all columns explicitly' do
        result = Post.includes(:comments).with_columns(
          comments: [:author_id, :body, :upvotes, :created_at, :updated_at]
        ).first
        comment = result.comments.first

        expect(comment.attributes.keys).to include('author_id', 'body', 'upvotes', 'created_at', 'updated_at')
      end
    end

    context 'without_columns option' do
      it 'loads all columns except specified ones' do
        result = Post.without_columns(comments: [:body, :upvotes]).first
        comment = result.comments.first

        # Should have all columns except body and upvotes
        expect(comment.attributes.keys).to include('id', 'post_id', 'author_id', 'created_at', 'updated_at')
        expect(comment.attributes.keys).not_to include('body', 'upvotes')
      end

      it 'handles single excluded column' do
        result = Post.without_columns(comments: :body).first
        comment = result.comments.first

        expect(comment.attributes.keys).to include('id', 'post_id', 'author_id', 'upvotes')
        expect(comment.attributes.keys).not_to include('body')
      end

      it 'always includes PK and FK even when excluded' do
        result = Post.without_columns(comments: [:id, :post_id, :body]).first
        comment = result.comments.first

        expect(comment.id).to be_present
        expect(comment.post_id).to eq(post.id)
        expect(comment.attributes.keys).not_to include('body')
      end

      it 'works with multiple associations' do
        result = Post.without_columns(
          comments: :body,
          tags: :color
        ).first

        expect(result.comments.first.attributes.keys).not_to include('body')
        expect(result.comments.first.attributes.keys).to include('upvotes')
        expect(result.tags.first.attributes.keys).not_to include('color')
        expect(result.tags.first.attributes.keys).to include('name')
      end

      it 'works with includes' do
        result = Post.includes(:comments).without_columns(comments: :body).first

        expect(result.comments.first.attributes.keys).not_to include('body')
        expect(result.comments.first.attributes.keys).to include('upvotes')
      end

      it 'prevents N+1 queries' do
        query_count = QueryCounter.count_queries do
          result = Post.without_columns(comments: [:body, :upvotes]).first
          result.comments.each { |c| c.author_id }
        end

        expect(query_count).to eq(2)
      end
    end
  end

  describe 'belongs_to associations' do
    let!(:profile) do
      author.create_profile!(website: 'https://example.com', preferences: 'Dark mode enabled')
    end

    context 'with_columns' do
      it 'loads only specified columns from belongs_to association' do
        result = Post.includes(:author).with_columns(author: [:name]).first
        loaded_author = result.author

        expect(loaded_author.attributes.keys).to contain_exactly('id', 'name')
        expect(loaded_author.name).to eq('Jane Author')
      end

      it 'does not include foreign key in associated table query' do
        # This is the bug we fixed - author_id exists on posts, not authors
        result = Post.includes(:author).with_columns(author: [:name]).first
        loaded_author = result.author

        # Should only have id and name, NOT author_id
        expect(loaded_author.attributes.keys).to contain_exactly('id', 'name')
      end

      it 'handles multiple columns for belongs_to' do
        result = Post.includes(:author).with_columns(author: [:name, :email]).first
        loaded_author = result.author

        expect(loaded_author.attributes.keys).to contain_exactly('id', 'name', 'email')
        expect(loaded_author.name).to eq('Jane Author')
        expect(loaded_author.email).to eq('jane@example.com')
      end

      it 'returns nil for non-selected columns in belongs_to' do
        result = Post.includes(:author).with_columns(author: [:name]).first
        loaded_author = result.author

        expect(loaded_author.attributes['bio']).to be_nil
        expect(loaded_author.attributes['email']).to be_nil
      end

      it 'prevents N+1 queries with belongs_to' do
        3.times { |i| Post.create!(title: "Post #{i}", author_id: author.id) }

        query_count = QueryCounter.count_queries do
          posts = Post.includes(:author).with_columns(author: [:name])
          posts.each { |p| p.author&.name }
        end

        expect(query_count).to eq(2)
      end

      it 'handles belongs_to with nil foreign key' do
        post_without_author = Post.create!(title: 'Orphan Post', author_id: nil)
        result = Post.where(id: post_without_author.id).includes(:author).with_columns(author: [:name]).first

        expect(result.author).to be_nil
      end
    end

    context 'without_columns' do
      it 'excludes specified columns from belongs_to association' do
        result = Post.includes(:author).without_columns(author: [:bio]).first
        loaded_author = result.author

        expect(loaded_author.attributes.keys).to include('id', 'name', 'email')
        expect(loaded_author.attributes.keys).not_to include('bio')
      end

      it 'excludes multiple columns from belongs_to' do
        result = Post.includes(:author).without_columns(author: [:bio, :email]).first
        loaded_author = result.author

        expect(loaded_author.attributes.keys).to include('id', 'name')
        expect(loaded_author.attributes.keys).not_to include('bio', 'email')
      end

      it 'always includes primary key even when excluded' do
        result = Post.includes(:author).without_columns(author: [:id, :bio]).first
        loaded_author = result.author

        expect(loaded_author.id).to be_present
        expect(loaded_author.attributes.keys).not_to include('bio')
      end
    end

    context 'mixed associations' do
      it 'handles both has_many and belongs_to together' do
        result = Post.includes(:comments, :author).with_columns(
          comments: [:body],
          author: [:name]
        ).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
        expect(result.author.attributes.keys).to contain_exactly('id', 'name')
      end

      it 'prevents N+1 with mixed associations' do
        query_count = QueryCounter.count_queries do
          result = Post.includes(:comments, :author).with_columns(
            comments: [:body],
            author: [:name]
          ).first

          result.comments.each { |c| c.body }
          result.author.name
        end

        expect(query_count).to eq(3)
      end
    end
  end

  describe 'has_one associations' do
    let!(:profile) do
      author.create_profile!(website: 'https://example.com', preferences: 'Dark mode enabled')
    end

    context 'with_columns' do
      it 'loads only specified columns from has_one association' do
        result = Author.includes(:profile).with_columns(profile: [:website]).first
        loaded_profile = result.profile

        expect(loaded_profile.attributes.keys).to contain_exactly('id', 'author_id', 'website')
        expect(loaded_profile.website).to eq('https://example.com')
      end

      it 'includes foreign key in has_one query' do
        result = Author.includes(:profile).with_columns(profile: [:website]).first
        loaded_profile = result.profile

        expect(loaded_profile.attributes.keys).to include('author_id')
        expect(loaded_profile.author_id).to eq(author.id)
      end

      it 'returns nil for non-selected columns in has_one' do
        result = Author.includes(:profile).with_columns(profile: [:website]).first
        loaded_profile = result.profile

        expect(loaded_profile.attributes['preferences']).to be_nil
      end

      it 'handles has_one with nil association' do
        author_without_profile = Author.create!(name: 'No Profile Author', email: 'noprofile@example.com')
        result = Author.where(id: author_without_profile.id).includes(:profile).with_columns(profile: [:website]).first

        expect(result.profile).to be_nil
      end

      it 'prevents N+1 queries with has_one' do
        2.times do |i|
          a = Author.create!(name: "Author #{i}", email: "author#{i}@example.com")
          a.create_profile!(website: "https://example#{i}.com")
        end

        query_count = QueryCounter.count_queries do
          authors = Author.includes(:profile).with_columns(profile: [:website])
          authors.each { |a| a.profile&.website }
        end

        expect(query_count).to eq(2)
      end
    end

    context 'without_columns' do
      it 'excludes specified columns from has_one association' do
        result = Author.includes(:profile).without_columns(profile: [:preferences]).first
        loaded_profile = result.profile

        expect(loaded_profile.attributes.keys).to include('id', 'author_id', 'website')
        expect(loaded_profile.attributes.keys).not_to include('preferences')
      end

      it 'always includes foreign key even when excluded' do
        result = Author.includes(:profile).without_columns(profile: [:author_id, :preferences]).first
        loaded_profile = result.profile

        expect(loaded_profile.author_id).to eq(author.id)
        expect(loaded_profile.attributes.keys).not_to include('preferences')
      end
    end

    context 'complex scenarios' do
      it 'handles has_many, has_one, and belongs_to together' do
        result = Post.includes(:comments, :author).with_columns(
          comments: [:body],
          author: [:name]
        ).first

        # Load the author's profile separately to test has_one
        author_result = Author.includes(:profile, :posts).with_columns(
          profile: [:website],
          posts: [:title]
        ).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
        expect(result.author.attributes.keys).to contain_exactly('id', 'name')
        expect(author_result.profile.attributes.keys).to contain_exactly('id', 'author_id', 'website')
        expect(author_result.posts.first.attributes.keys).to contain_exactly('id', 'author_id', 'title')
      end
    end
  end

  describe 'advanced features' do
    context 'scoped associations with has_many' do
      before do
        Post.class_eval do
          has_many :published_comments, -> { where(published: true) }, class_name: 'Comment', foreign_key: :post_id
          has_many :low_upvote_comments, -> { where('upvotes < 20') }, class_name: 'Comment', foreign_key: :post_id
        end
      end

      it 'respects association scopes with boolean conditions' do
        result = Post.includes(:published_comments).with_columns(published_comments: [:body, :published]).first

        # Only loads published comments (first 3: upvotes 0, 10, 20)
        expect(result.published_comments.count).to eq(3)
        expect(result.published_comments.map(&:published).uniq).to eq([true])

        # Column selection works
        expect(result.published_comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body', 'published')
      end

      it 'respects association scopes with numeric conditions' do
        result = Post.includes(:low_upvote_comments).with_columns(low_upvote_comments: [:body, :upvotes]).first

        # Only loads comments with upvotes < 20 (comments 0 and 1)
        expect(result.low_upvote_comments.count).to eq(2)
        expect(result.low_upvote_comments.map(&:upvotes)).to contain_exactly(0, 10)

        # Column selection works
        expect(result.low_upvote_comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body', 'upvotes')
      end

      it 'works with without_columns on scoped associations' do
        result = Post.includes(:published_comments).without_columns(published_comments: [:body]).first

        # Scope still respected
        expect(result.published_comments.count).to eq(3)

        # Body column excluded
        expect(result.published_comments.first.attributes.keys).not_to include('body')
        expect(result.published_comments.first.attributes.keys).to include('published', 'upvotes')
      end
    end

    context 'scoped associations with belongs_to' do
      before do
        Author.class_eval do
          has_many :verified_posts, -> { where('id > 0') }, class_name: 'Post', foreign_key: :author_id
        end

        Post.class_eval do
          belongs_to :verified_author, -> { where('id > 0') }, class_name: 'Author', foreign_key: :author_id
        end
      end

      it 'respects scopes on belongs_to associations' do
        result = Post.includes(:verified_author).with_columns(verified_author: [:name]).first

        # Scope respected (all authors have id > 0)
        expect(result.verified_author).to be_present
        expect(result.verified_author.name).to eq('Jane Author')
        expect(result.verified_author.attributes.keys).to contain_exactly('id', 'name')
      end
    end

    context 'scoped associations with has_one' do
      before do
        Author.class_eval do
          has_one :active_profile, -> { where('id > 0') }, class_name: 'Profile', foreign_key: :author_id
        end
      end

      it 'respects scopes on has_one associations' do
        author.create_profile!(website: 'https://example.com', preferences: 'Dark mode')

        result = Author.includes(:active_profile).with_columns(active_profile: [:website]).first

        # Scope respected
        expect(result.active_profile).to be_present
        expect(result.active_profile.website).to eq('https://example.com')
        expect(result.active_profile.attributes.keys).to contain_exactly('id', 'author_id', 'website')
      end
    end

    context 'nested/chained includes' do
      it 'supports nested includes with hash syntax' do
        result = Post.with_columns(
          comments: {
            columns: [:body],
            include: { author: [:name] }
          }
        ).first

        # Comments loaded with only body column
        expect(result.comments.count).to eq(5)
        expect(result.comments.first.attributes.keys).to include('id', 'post_id', 'body', 'author_id')
        expect(result.comments.first.attributes.keys).not_to include('upvotes', 'published')

        # Nested author loaded with only name column
        expect(result.comments.first.author).to be_present
        expect(result.comments.first.author.name).to eq('Jane Author')
        expect(result.comments.first.author.attributes.keys).to contain_exactly('id', 'name')
      end

      it 'supports multi-level nesting (3 levels deep)' do
        # Create a profile for the author
        author.create_profile!(website: 'https://example.com', preferences: 'Dark mode')

        result = Post.with_columns(
          comments: {
            columns: [:body],
            include: {
              author: {
                columns: [:name],
                include: { profile: [:website] }
              }
            }
          }
        ).first

        # Level 1: Post -> Comments
        expect(result.comments.count).to eq(5)
        expect(result.comments.first.attributes.keys).to include('body', 'author_id')

        # Level 2: Comments -> Author
        comment_author = result.comments.first.author
        expect(comment_author).to be_present
        expect(comment_author.attributes.keys).to contain_exactly('id', 'name')

        # Level 3: Author -> Profile
        expect(comment_author.profile).to be_present
        expect(comment_author.profile.website).to eq('https://example.com')
        expect(comment_author.profile.attributes.keys).to contain_exactly('id', 'author_id', 'website')
      end

      it 'supports nested includes with belongs_to' do
        result = Post.with_columns(
          author: {
            columns: [:name],
            include: { profile: [:website] }
          }
        ).first

        # Top-level belongs_to
        expect(result.author).to be_present
        expect(result.author.attributes.keys).to contain_exactly('id', 'name')

        # Nested has_one (note: profile needs to exist first)
        author.create_profile!(website: 'https://example.com')

        result = Post.with_columns(
          author: {
            columns: [:name],
            include: { profile: [:website] }
          }
        ).first

        expect(result.author.profile).to be_present
        expect(result.author.profile.website).to eq('https://example.com')
        expect(result.author.profile.attributes.keys).to contain_exactly('id', 'author_id', 'website')
      end

      it 'automatically includes foreign keys needed for nesting' do
        result = Post.with_columns(
          comments: {
            columns: [:body],  # author_id NOT explicitly listed
            include: { author: [:name] }
          }
        ).first

        # author_id should be automatically included to load the nested author
        expect(result.comments.first.attributes.keys).to include('author_id')
        expect(result.comments.first.author).to be_present
      end

      it 'works with without_columns and nested includes' do
        result = Post.without_columns(
          comments: {
            columns: [:upvotes, :published],  # Exclude these
            include: { author: [:bio, :email] }  # Exclude these from author
          }
        ).first

        # Comments should have all columns except upvotes and published
        expect(result.comments.first.attributes.keys).to include('body', 'author_id')
        expect(result.comments.first.attributes.keys).not_to include('upvotes', 'published')

        # Author should have all columns except bio and email
        expect(result.comments.first.author.attributes.keys).to include('name')
        expect(result.comments.first.author.attributes.keys).not_to include('bio', 'email')
      end

      it 'supports scoped associations in nested includes' do
        Post.class_eval do
          has_many :published_comments, -> { where(published: true) }, class_name: 'Comment', foreign_key: :post_id
        end

        result = Post.with_columns(
          published_comments: {
            columns: [:body, :published],
            include: { author: [:name] }
          }
        ).first

        # Only published comments loaded (scoped at top level)
        expect(result.published_comments.count).to eq(3)
        expect(result.published_comments.map(&:published).uniq).to eq([true])

        # Nested author works
        expect(result.published_comments.first.author).to be_present
        expect(result.published_comments.first.author.name).to eq('Jane Author')
      end

      it 'prevents N+1 queries with nested includes' do
        query_count = QueryCounter.count_queries do
          result = Post.with_columns(
            comments: {
              columns: [:body],
              include: { author: [:name] }
            }
          ).first

          # Access nested data
          result.comments.each do |comment|
            comment.body
            comment.author.name
          end
        end

        # Should be 3 queries: posts, comments, authors (no N+1)
        expect(query_count).to eq(3)
      end

      it 'prevents N+1 with multi-level nesting' do
        author.create_profile!(website: 'https://example.com', preferences: 'Dark mode')

        query_count = QueryCounter.count_queries do
          result = Post.with_columns(
            comments: {
              columns: [:body],
              include: {
                author: {
                  columns: [:name],
                  include: { profile: [:website] }
                }
              }
            }
          ).first

          # Access all nested data
          result.comments.each do |comment|
            comment.body
            comment.author.name
            comment.author.profile.website
          end
        end

        # Should be 4 queries: posts, comments, authors, profiles (no N+1)
        expect(query_count).to eq(4)
      end

      it 'raises error for unknown nested association' do
        expect {
          Post.with_columns(
            comments: {
              columns: [:body],
              include: { fake_assoc: [:name] }
            }
          ).first
        }.to raise_error(ArgumentError, /Unknown association: fake_assoc/)
      end

      it 'handles empty nested includes hash' do
        # include: {} should be treated as no nesting
        result = Post.with_columns(
          comments: {
            columns: [:body],
            include: {}
          }
        ).first

        expect(result.comments.count).to eq(5)
        expect(result.comments.first.attributes.keys).to include('body')
      end

      it 'supports mixing legacy array syntax with new hash syntax' do
        # Top level uses legacy, nested uses new hash syntax
        result = Post.with_columns(
          comments: {
            columns: [:body],
            include: { author: [:name] }
          },
          tags: [:name]  # Legacy array syntax
        ).first

        # Both work
        expect(result.comments.first.author.name).to eq('Jane Author')
        expect(result.tags.first.name).to be_present
      end

      it 'legacy array syntax still works for top-level associations' do
        # Ensure backwards compatibility
        result = Post.with_columns(
          comments: [:body],
          tags: [:name]
        ).first

        expect(result.comments.first.attributes.keys).to include('body')
        expect(result.tags.first.attributes.keys).to include('name')
      end
    end

  end

  describe 'supported loading strategies' do
    context 'eager_load' do
      it 'works with eager_load by intercepting it' do
        # The gem intercepts eager_load and converts it to its own loading strategy
        result = Post.eager_load(:comments).with_columns(comments: [:body]).first

        # This works! The gem strips it from eager_load and handles it manually
        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end
    end

    context 'preload' do
      it 'works with explicit preload' do
        result = Post.preload(:comments).with_columns(comments: [:body]).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end
    end

    context 'includes' do
      it 'works with includes' do
        result = Post.includes(:comments).with_columns(comments: [:body]).first

        expect(result.comments.first.attributes.keys).to contain_exactly('id', 'post_id', 'body')
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  RSpec::Core::Runner.run([])
end
