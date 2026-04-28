# frozen_string_literal: true

source 'https://rubygems.org'

group :test do
  llm_base_path = ENV.fetch('LEX_LLM_PATH', File.expand_path('../lex-llm', __dir__))
  gem 'lex-llm', path: llm_base_path if File.directory?(llm_base_path)
end

gemspec

gem 'rubocop-legion', '~> 0.1', require: false
