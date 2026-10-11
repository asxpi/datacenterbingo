ENV['RACK_ENV'] = 'test'

# DB-backed tests run only against an explicit test database (bin/test
# provisions an ephemeral one). Never fall through to a developer DATABASE_URL.
if ENV['TEST_DATABASE_URL']
  ENV['DATABASE_URL']  = ENV['TEST_DATABASE_URL']
  ENV['S3_ENDPOINT']   ||= 'http://127.0.0.1:1'
  ENV['S3_ACCESS_KEY'] ||= 'test'
  ENV['S3_SECRET_KEY'] ||= 'test'
  ENV['S3_BUCKET']     ||= 'test-bucket'
  require 'aws-sdk-s3'
  Aws.config[:s3] = { stub_responses: true } # no S3 call leaves the process

  # The schema is asxpio's; load the snapshot into the empty test database.
  require 'sequel'
  db = Sequel.connect(ENV['DATABASE_URL'])
  db.run(File.read(File.join(__dir__, 'schema.sql'))) unless db.table_exists?(:bingo_datacenters)
  db.disconnect
else
  ENV.delete('DATABASE_URL')
end

require_relative '../app'
require 'minitest/autorun'
require 'rack/test'

module TestDb
  def self.available? = !ENV['DATABASE_URL'].nil?
end
