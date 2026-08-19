# frozen_string_literal: true

module Async
  module Caldav
    module Handlers
      module Put
        module_function

        def call(path:, body:, storage:, headers: {}, resource_type: nil, **)
          rejected = rejection(body, resource_type)
          if rejected
            rejected
          else
            content_type = headers['content-type'] || default_content_type(resource_type)
            store(
              path,
              body,
              content_type,
              storage,
              headers,
            )
          end
        end

        # Everything judged from the body alone, before anything is looked up or
        # written. nil when the body is acceptable, otherwise the response.
        def rejection(body, resource_type)
          if body.nil? || body.strip.empty?
            [400, { 'content-type' => 'text/plain' }, ['Empty body']]
          elsif resource_type == :calendar && !body.start_with?('BEGIN:VCALENDAR')
            [400, { 'content-type' => 'text/plain' }, ['Invalid calendar data']]
          elsif resource_type == :addressbook && !body.start_with?('BEGIN:VCARD')
            [400, { 'content-type' => 'text/plain' }, ['Invalid vCard data']]
          end
        end

        def default_content_type(resource_type)
          if resource_type == :calendar
            'text/calendar'
          elsif resource_type == :addressbook
            'text/vcard'
          else
            'application/octet-stream'
          end
        end

        def store(path, body, content_type, storage, headers)
          existing = storage.get_item(path.to_s)
          if_match = headers['if-match']
          if_none_match = headers['if-none-match']
          if if_match && (!existing || existing[:etag] != if_match)
            [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
          elsif if_none_match == '*' && existing
            [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
          elsif !existing && uid_conflict?(path, body, storage)
            [409, { 'content-type' => 'text/plain' }, ['UID conflict']]
          else
            item, is_new = storage.put_item(path.to_s, body, content_type)
            if is_new
              [201, { 'etag' => item[:etag], 'content-type' => 'text/plain' }, ['']]
            else
              [204, { 'etag' => item[:etag] }, ['']]
            end
          end
        end

        # A UID may appear once per collection. The item at `path` itself is
        # skipped: replacing it with a body carrying its own UID is not a clash.
        def uid_conflict?(path, body, storage)
          uid = extract_uid(body)
          if uid
            storage.list_items(path.parent.to_s).any? do |item_path, item_data|
              item_path != path.to_s && extract_uid(item_data[:body]) == uid
            end
          else
            false
          end
        end

        def extract_uid(body)
          if body
            match = body.match(/^UID:(.+)/i)
            match ? match[1].strip : nil
          else
            nil
          end
        end

        private_class_method :extract_uid, :rejection, :default_content_type, :store, :uid_conflict?
      end
    end
  end
end

__END__

require_relative "../../caldav"

describe "Async::Caldav::Handlers::Put" do
  def call(**opts)
    Async::Caldav::Handlers::Put.call(**opts)
  end

  def path(p, s)
    Protocol::Caldav::Path.new(p, storage_class: s)
  end

  it "creates a new calendar item and returns 201" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/calendars/admin/cal/')
    status, headers, = call(
      path: path('/calendars/admin/cal/ev.ics', s), storage: s,
      body: "BEGIN:VCALENDAR\r\nUID:123\r\nEND:VCALENDAR",
      resource_type: :calendar
    )
    status.should.equal 201
    headers['etag'].should.not.be.nil
  end

  it "updates an existing item and returns 204" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/calendars/admin/cal/')
    s.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\r\nUID:123\r\nEND:VCALENDAR", 'text/calendar')
    status, = call(
      path: path('/calendars/admin/cal/ev.ics', s), storage: s,
      body: "BEGIN:VCALENDAR\r\nUID:123\r\nSUMMARY:Updated\r\nEND:VCALENDAR",
      resource_type: :calendar
    )
    status.should.equal 204
  end

  it "returns 400 for empty body" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(path: path('/cal/ev.ics', s), storage: s, body: "")
    status.should.equal 400
  end

  it "returns 400 for invalid calendar data" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(path: path('/cal/ev.ics', s), storage: s, body: "NOT ICAL", resource_type: :calendar)
    status.should.equal 400
  end

  it "returns 400 for invalid vCard data" do
    s = Async::Caldav::Storage::Mock.new
    status, = call(path: path('/addr/c.vcf', s), storage: s, body: "NOT VCARD", resource_type: :addressbook)
    status.should.equal 400
  end

  it "returns 412 on If-Match mismatch" do
    s = Async::Caldav::Storage::Mock.new
    s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, = call(
      path: path('/cal/ev.ics', s), storage: s,
      body: "BEGIN:VCALENDAR\r\nNEW", resource_type: :calendar,
      headers: { 'if-match' => '"wrong"' }
    )
    status.should.equal 412
  end

  it "returns 412 on If-None-Match=* when item exists" do
    s = Async::Caldav::Storage::Mock.new
    s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, = call(
      path: path('/cal/ev.ics', s), storage: s,
      body: "BEGIN:VCALENDAR\r\nNEW", resource_type: :calendar,
      headers: { 'if-none-match' => '*' }
    )
    status.should.equal 412
  end

  it "returns 409 on UID conflict" do
    s = Async::Caldav::Storage::Mock.new
    s.create_collection('/cal/')
    s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR", 'text/calendar')
    status, = call(
      path: path('/cal/b.ics', s), storage: s,
      body: "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR",
      resource_type: :calendar
    )
    status.should.equal 409
  end
end