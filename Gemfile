# frozen_string_literal: true

source 'https://rubygems.org'

group :test do
  llm_base_path = ENV.fetch('LEX_LLM_PATH', File.expand_path('../lex-llm', __dir__))
  transport_path = ENV.fetch('LEGION_TRANSPORT_PATH', File.expand_path('../../legion-transport', __dir__))
  gem 'legion-transport', path: transport_path if File.directory?(transport_path)
  # lex-llm 0.5.0 (feat/canonical-types) carries canonical types + conformance kit
  # Git branch reference used until 0.5.0 is published on rubygems.
  # When using a local checkout, ensure it is on feat/canonical-types:
  #   cd ../lex-llm && git checkout feat/canonical-types
  if File.directory?(llm_base_path)
    gem 'lex-llm', path: llm_base_path
  end
end

gemspec

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end
