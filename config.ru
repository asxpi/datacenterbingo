require_relative 'app'

# www. redirects to the canonical BINGO_HOST; everything else is the card.
bingo_host = ENV['BINGO_HOST']
bingo      = BingoWeb.new

run lambda { |env|
  req = Rack::Request.new(env)
  if bingo_host && req.host == "www.#{bingo_host}"
    [301, { 'location' => "https://#{bingo_host}#{req.fullpath}" }, []]
  else
    bingo.call(env)
  end
}
