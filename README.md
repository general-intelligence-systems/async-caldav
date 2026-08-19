# async-caldav

CalDAV/CardDAV server. Rack-compatible, built on [protocol-caldav](../protocol-caldav) for wire-format concerns.

Supports calendars, addressbooks, PROPFIND/PROPPATCH, REPORT with filters, sync-collection, recurrence expansion, ETag preconditions, and whole-calendar import.

## Install

```ruby
gem "async-caldav", "~> 0.1"
```

## Quick start

```ruby
# server.rb
require "ratalada/falcon"
require "async/caldav"

storage = Async::Caldav::Storage::Filesystem.new("/data")
caldav = Async::Caldav::Server.new(storage: storage)

Server.run do |request|
  request.env['dav.user'] = request.env['HTTP_REMOTE_USER']
  ->(req) { caldav.call(req.env) }
end
```

That is the whole server -- `ruby server.rb` listens on `http://127.0.0.1:9292`
([ratalada](https://github.com/n-at-han-k/ratalada) supplies the `Server` DSL
and the falcon backend). It is still a plain Rack app, so a `config.ru` under
any other server works just as well.

`examples/ratalada/` is that server as a runnable file, with a flake around it:

```
cd examples/ratalada
nix run          # or: bundle install && bundle exec ruby server.rb
```

Data lands in `$CALDAV_DATA_DIR` (default `./data`).

`examples/docker/` is the same server the older way -- a `config.ru` served by
`falcon host`, wrapped in a Dockerfile and a Compose file:

```
cd examples/docker && docker compose up -d
```

## Client

```ruby
require "async/caldav"

client = Async::Caldav::Client.new("http://localhost:9292", user: "admin")

# Discovery
client.principal           # => "/admin/"
client.calendars           # => [Calendar, ...]
client.addressbooks        # => [Addressbook, ...]

# Create a calendar and add an event
cal = client.create_calendar("work", displayname: "Work")
cal.put_event("meeting.ics", <<~ICAL)
  BEGIN:VCALENDAR
  BEGIN:VEVENT
  UID:meeting-1
  SUMMARY:Team Standup
  DTSTART:20260501T090000Z
  DTEND:20260501T093000Z
  END:VEVENT
  END:VCALENDAR
ICAL

# Retrieve and list events
event = cal.get_event("meeting.ics")
event[:body]    # => "BEGIN:VCALENDAR..."
event[:etag]    # => '"a1b2c3..."'

cal.events      # => [{path:, body:, etag:}, ...]

# Conditional update with ETag
cal.put_event("meeting.ics", new_body, if_match: event[:etag])

# Sync (incremental)
items, token = cal.sync
# ... later ...
changes, token = cal.sync(token: token)

# Addressbook
ab = client.create_addressbook("contacts", displayname: "Contacts")
ab.put_contact("alice.vcf", "BEGIN:VCARD\r\nUID:1\r\nFN:Alice\r\nEND:VCARD")
ab.contacts     # => [{path:, body:, etag:}, ...]

client.close
```

## Authentication

The server reads `env['dav.user']`. Wire this up however you like -- the `ForwardAuth` module extracts `Remote-User`, `Remote-Email`, `Remote-Name`, and `Remote-Groups` headers from a reverse proxy (Authelia, Authentik, etc).

## Storage backends

| Backend | Class | Notes |
|---|---|---|
| Filesystem | `Storage::Filesystem` | JSON metadata + raw files on disk |
| In-memory | `Storage::Mock` | For tests; no persistence |
| Custom | Subclass `Protocol::Caldav::Storage` | Implement ~15 methods |

## HTTP methods

| Method | Handler |
|---|---|
| `OPTIONS` | DAV capability headers |
| `PROPFIND` | Collection/item properties, discovery, propname |
| `PROPPATCH` | Update displayname, description, color |
| `MKCALENDAR` | Create calendar collection |
| `MKCOL` | Create addressbook collection |
| `GET` | Retrieve item or collection contents |
| `HEAD` | Headers only |
| `PUT` | Create/update item, whole-calendar import |
| `DELETE` | Remove item or collection |
| `MOVE` | Relocate item (within or across collections) |
| `REPORT` | Filtered queries, multiget, sync-collection, expand |

## Tests

Specs live in each file's `__END__` section, so they never load in production
(Ruby stops parsing at `__END__`) and sit next to the code they cover. `scampi`
finds them with `rg` and runs them:

```
nix develop
scampi                              # every __END__ spec section
scampi lib/async/caldav/server.rb   # just one file
```

Style is enforced by RuboCop, using the house cops under `cops/`:

```
rubocop
```

Git hooks (secret scan + `bin/test` on pre-commit) are managed by lefthook:

```
nix develop --command lefthook install
```

Integration tests -- starts `examples/ratalada/server.rb`, hits it with curl, shuts it down:
```
bin/test
```

Or against a server you started yourself:
```
cd examples/ratalada && bundle exec ruby server.rb
bin/integration
```

## License

Apache-2.0
