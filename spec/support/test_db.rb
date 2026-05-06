# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

module TestDb
  module_function

  def setup
    db = Sequel.sqlite
    Sequel::Migrator.run(db, legion_data_migration_dir)
    migration_dir = File.expand_path('../../lib/legion/extensions/llm/ledger/data/migrations', __dir__)
    Sequel::Migrator.run(db, migration_dir, table: :schema_migrations_lex_llm_ledger)
    db
  end

  def legion_data_migration_dir
    configured = ENV.fetch('LEGION_DATA_PATH', nil)
    return File.join(configured, 'lib/legion/data/migrations') if configured && !configured.empty?

    local = File.expand_path('../../../../legion-data/lib/legion/data/migrations', __dir__)
    return local if File.directory?(local)

    spec = Gem.loaded_specs['legion-data']
    File.join(spec.full_gem_path, 'lib/legion/data/migrations')
  end
end
