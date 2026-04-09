# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'legion/extensions/llm/ledger/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-llm-ledger'
  spec.version       = Legion::Extensions::Llm::Ledger::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'LEX LLM Ledger'
  spec.description   = 'LLM observability persistence for LegionIO — metering, audit, usage reporting'
  spec.homepage      = 'https://github.com/LegionIO/lex-llm-ledger'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri']          = spec.homepage
  spec.metadata['source_code_uri']       = 'https://github.com/LegionIO/lex-llm-ledger'
  spec.metadata['changelog_uri']         = 'https://github.com/LegionIO/lex-llm-ledger/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri']     = 'https://github.com/LegionIO/lex-llm-ledger'
  spec.metadata['bug_tracker_uri']       = 'https://github.com/LegionIO/lex-llm-ledger/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir.glob('{lib,sig}/**/*') + %w[lex-llm-ledger.gemspec Gemfile Rakefile CHANGELOG.md README.md LICENSE]
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'legion-data',      '>= 1.6'
  spec.add_dependency 'legion-json',      '>= 1.2'
  spec.add_dependency 'legion-llm',       '>= 0.6'
  spec.add_dependency 'legion-logging',   '>= 1.3'
  spec.add_dependency 'legion-settings',  '>= 1.3'
  spec.add_dependency 'legion-transport', '>= 1.4'

  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-rspec'
  spec.add_development_dependency 'sequel'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'sqlite3'
end
