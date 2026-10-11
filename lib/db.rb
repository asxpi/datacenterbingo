require 'sequel'

# The schema belongs to asxpio (its db/migrations); this app only reads.

module DB
  module_function

  def connect!
    # Every timestamp is written as Time.now.utc; read them back as UTC too
    # (otherwise a host in UTC+4 sees a fresh 1 h token as already expired).
    Sequel.default_timezone = :utc
    @connection ||= Sequel.connect(
      ENV.fetch('DATABASE_URL'),
      max_connections: 5,
      logger:          ($env == 'development' ? $logger : nil)
    )
  end

  def connection
    @connection or raise 'DB not connected — call DB.connect! first'
  end

end
