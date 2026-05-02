# async-caldav

CalDAV/CardDAV server. Rack-compatible, built on [protocol-caldav](../protocol-caldav) for wire-format concerns.

Supports calendars, addressbooks, PROPFIND/PROPPATCH, REPORT with filters, sync-collection, recurrence expansion, ETag preconditions, and whole-calendar import.

## Install

```ruby
gem "async-caldav", "~> 0.1"
```

## Quick start

```ruby
# config.ru
require "async/caldav"

class ForwardAuthMiddleware
  def initialize(app) = @app = app
  def call(env)
    env['dav.user'] = env['HTTP_REMOTE_USER']
    @app.call(env)
  end
end

storage = Async::Caldav::Storage::Filesystem.new("/data")
use ForwardAuthMiddleware
run Async::Caldav::Server.new(storage: storage)
```

See `example/` for a complete Docker Compose setup with Falcon.

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

Unit tests:
```
bundle install
bundle exec scampi
```

Integration tests (requires Docker):
```
bin/test
```

Or manually:
```
cd example && docker compose up -d
bin/integration
```

## License

Apache-2.0
