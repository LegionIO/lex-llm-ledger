# frozen_string_literal: true

source 'https://rubygems.org'

group :test do
  legion_data_path = ENV.fetch('LEGION_DATA_PATH', File.expand_path('../../legion-data', __dir__))
  llm_base_path = ENV.fetch('LEX_LLM_PATH', File.expand_path('../lex-llm', __dir__))
  gem 'legion-data', path: legion_data_path if File.directory?(legion_data_path)
  gem 'lex-llm', path: llm_base_path if File.directory?(llm_base_path)
end

gemspec

gem 'rubocop-legion', '~> 0.1', require: false
