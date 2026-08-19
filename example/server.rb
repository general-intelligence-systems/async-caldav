# frozen_string_literal: true

# A complete CalDAV/CardDAV server: storage on disk, falcon underneath.
#
#   bundle exec ruby server.rb
#
# Listens on 127.0.0.1:9292 (HOST/PORT to change). Auth is forwarded from a
# reverse proxy -- the Remote-User header becomes env['dav.user'].

require "ratalada/falcon"
require "async/caldav"

storage = Async::Caldav::Storage::Filesystem.new(ENV.fetch("CALDAV_DATA_DIR", "/data"))

# Pre-create parent collections
%w[/calendars/ /calendars/admin/ /addressbooks/ /addressbooks/admin/].each do |path|
  storage.create_collection(path) unless storage.get_collection(path)
end

caldav = Async::Caldav::Server.new(storage: storage)

# Every path belongs to the CalDAV app, so the router matches everything and
# only does the forward-auth step itself.
Server.run do |request|
  request.env["dav.user"] = Async::Caldav::ForwardAuth.extract(request.env)[:user]
  ->(req) { caldav.call(req.env) }
end
