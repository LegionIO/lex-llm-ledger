# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

module TestDb
  module_function

  def setup
    db = Sequel.sqlite
    migration_dir = File.expand_path('../../lib/legion/extensions/llm/ledger/migrations', __dir__)
    Sequel::Migrator.run(db, migration_dir)
    db
  end
end
