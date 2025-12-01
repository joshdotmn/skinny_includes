# frozen_string_literal: true

require_relative "lib/skinny_includes/version"

Gem::Specification.new do |spec|
  spec.name = "skinny_includes"
  spec.version = SkinnyIncludes::VERSION
  spec.authors = ["Josh"]
  spec.email = ["joshdotmn+gems@gmail.com"]

  spec.summary = "Select specific columns when preloading associations"
  spec.description = "Control which columns are loaded when preloading associations; prevents N+1 queries while reducing memory usage."
  spec.homepage = "https://github.com/joshdotmn/skinny_includes"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/joshdotmn/skinny_includes"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore])
    end
  end

  spec.require_paths = ["lib"]
  spec.add_dependency "activerecord", ">= 7.0"
end
